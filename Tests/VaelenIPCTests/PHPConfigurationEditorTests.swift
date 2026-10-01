import XCTest
@testable import VaelenIPC

@MainActor
final class PHPConfigurationEditorTests: XCTestCase {
    private let values = PHPSettingsValues(uploadLimitMB: 64, memoryLimitMB: 256, maxExecutionTimeSeconds: 30, maxInputVariables: 2000, postLimitMB: 65)
    private func snapshot(_ versions: [String] = ["8.4.23"], settings: PHPSettingsValues? = nil, restarted: [String] = []) -> PHPConfigurationResult {
        let settings = settings ?? values
        return PHPConfigurationResult(defaultSettings: settings, versions: versions.map {
            PHPVersionConfiguration(version: $0, settings: settings, inheritsDefault: true, cliIniPath: "/isolated/\($0)/cli.ini", fpmIniPath: "/isolated/\($0)/fpm.ini", fpmConfigurationPath: "/isolated/\($0)/fpm.conf", fpmRunning: false)
        }, directory: "/isolated", affectedVersions: restarted)
    }

    func testExistingSnapshotReconcilesLowerInstalledVersionAndRemoval() async {
        let editor = PHPConfigurationEditor()
        await editor.refresh { snapshot() }
        XCTAssertNil(editor.snapshot?.versions.first { $0.version == "8.3.29" })
        await editor.refresh { snapshot(["8.4.23", "8.3.29"]) }
        XCTAssertEqual(editor.snapshot?.versions.first { $0.version == "8.3.29" }?.settings, values)
        editor.edit(.version("8.3.29"), settings: values) { $0.memory = "512" }
        await editor.refresh { snapshot() }
        XCTAssertNil(editor.drafts[.version("8.3.29")])
        XCTAssertEqual(editor.snapshot?.versions.map(\.version), ["8.4.23"])
    }

    func testIdenticalSavedValuesNeverTransferDraftsAcrossContexts() async {
        let editor = PHPConfigurationEditor()
        await editor.refresh { snapshot(["8.4.23", "8.3.29"]) }
        editor.edit(.version("8.4.23"), settings: values) { $0.upload = "128" }
        XCTAssertEqual(editor.draft(for: .version("8.3.29"), settings: values).upload, "64")
        editor.edit(.version("8.3.29"), settings: values) { $0.memory = "512" }
        XCTAssertEqual(editor.draft(for: .version("8.4.23"), settings: values).upload, "128")
        XCTAssertEqual(editor.draft(for: .version("8.4.23"), settings: values).memory, "256")
        XCTAssertEqual(editor.draft(for: .shared, settings: values).memory, "256")
        await editor.refresh { snapshot(["8.4.23", "8.3.29"]) }
        XCTAssertEqual(editor.draft(for: .version("8.3.29"), settings: values).memory, "512")
    }

    func testDirtyDraftSurvivesChangedSavedValuesUntilExplicitDiscard() async {
        let editor = PHPConfigurationEditor()
        let context = PHPSettingsContext.version("8.3.29")
        editor.edit(context, settings: values) { $0.memory = "512" }
        let updated = PHPSettingsValues(uploadLimitMB: 80, memoryLimitMB: 256, maxExecutionTimeSeconds: 30, maxInputVariables: 2000, postLimitMB: 81)
        await editor.refresh { snapshot(["8.3.29"], settings: updated) }
        let draft = editor.draft(for: context, settings: updated)
        XCTAssertEqual(draft.memory, "512")
        XCTAssertNotEqual(draft.baseline, updated)
        editor.discardDraft(context, settings: updated)
        XCTAssertFalse(editor.draft(for: context, settings: updated).isDirty)
        XCTAssertEqual(editor.draft(for: context, settings: updated).upload, "80")
    }

    func testSuccessfulRefreshDoesNotEraseSaveOrResetFailure() async {
        let editor = PHPConfigurationEditor()
        let context = PHPSettingsContext.version("8.3.29")
        editor.edit(context, settings: values) { $0.memory = "512" }
        await editor.save(context: context, settings: values) { throw TestFailure.failed }
        await editor.refresh { snapshot(["8.3.29"]) }
        XCTAssertTrue(editor.saveErrors[context]?.hasPrefix("Save failed:") == true)
        XCTAssertEqual(editor.draft(for: context, settings: values).memory, "512")
        XCTAssertNil(editor.saveErrors[.shared])
        await editor.save(context: context, settings: nil) { throw TestFailure.failed }
        await editor.refresh { snapshot(["8.3.29"]) }
        XCTAssertTrue(editor.saveErrors[context]?.hasPrefix("Reset failed:") == true)
        await editor.save(context: context, settings: nil) { snapshot(["8.3.29"]) }
        XCTAssertNil(editor.saveErrors[context])
        XCTAssertFalse(editor.draft(for: context, settings: values).isDirty)
    }

    func testOlderReadCannotReplaceNewerSnapshotOrPendingState() async {
        let editor = PHPConfigurationEditor()
        let gate = ReadGate()
        let old = Task { await editor.refresh { try await gate.read() } }
        while gate.continuation == nil { await Task.yield() }
        XCTAssertTrue(editor.readPending)
        await editor.refresh { snapshot(["8.4.23", "8.3.29"]) }
        gate.continuation?.resume(returning: snapshot())
        await old.value
        XCTAssertEqual(editor.snapshot?.versions.count, 2)
        XCTAssertFalse(editor.readPending)
    }

    func testPreSaveReadAndStaleFailureCannotReplaceSavedValues() async {
        let editor = PHPConfigurationEditor()
        let gate = ReadGate()
        let old = Task { await editor.refresh { try await gate.read() } }
        while gate.continuation == nil { await Task.yield() }
        let updated = PHPSettingsValues(uploadLimitMB: 128, memoryLimitMB: 256, maxExecutionTimeSeconds: 30, maxInputVariables: 2000, postLimitMB: 129)
        await editor.save(context: .version("8.3.29"), settings: updated) { snapshot(["8.3.29"], settings: updated, restarted: ["8.3.29"]) }
        gate.continuation?.resume(throwing: TestFailure.failed)
        await old.value
        XCTAssertEqual(editor.snapshot?.versions.first?.settings, updated)
        XCTAssertNil(editor.readError)
        XCTAssertTrue(editor.saveMessages[.version("8.3.29")]?.contains("Restarted PHP-FPM: 8.3.29") == true)
    }

    func testReadFailureKeepsSnapshotAndRetryRecovers() async {
        let editor = PHPConfigurationEditor()
        await editor.refresh { snapshot() }
        await editor.refresh { throw TestFailure.failed }
        XCTAssertNotNil(editor.readError)
        XCTAssertNotNil(editor.snapshot)
        await editor.refresh { snapshot(["8.4.23", "8.3.29"]) }
        XCTAssertNil(editor.readError)
        XCTAssertEqual(editor.snapshot?.versions.count, 2)
    }

    func testSuccessfulSaveRemainsConfirmedWhenSubsequentReadFails() async {
        let editor = PHPConfigurationEditor()
        let context = PHPSettingsContext.version("8.3.29")
        await editor.save(context: context, settings: values) { snapshot(["8.3.29"]) }
        await editor.refresh { throw TestFailure.failed }
        XCTAssertNotNil(editor.readError)
        XCTAssertNil(editor.saveErrors[context])
        XCTAssertTrue(editor.saveMessages[context]?.hasPrefix("Settings saved.") == true)
        XCTAssertEqual(editor.snapshot?.versions.first?.settings, values)
    }

    func testDraftValidationHandlesEmptyNonNumericAndOverflowWithoutCrashing() {
        var draft = PHPSettingsDraft(settings: values)
        for text in ["", "abc", "3000", String(Int.max), "99999999999999999999999"] {
            draft.upload = text
            XCTAssertNil(draft.values)
        }
        draft.upload = "128"
        XCTAssertEqual(draft.values?.postLimitMB, 129)
    }
}

private enum TestFailure: Error { case failed }
@MainActor private final class ReadGate {
    var continuation: CheckedContinuation<PHPConfigurationResult, Error>?
    func read() async throws -> PHPConfigurationResult {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
