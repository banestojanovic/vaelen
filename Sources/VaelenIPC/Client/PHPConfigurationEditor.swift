import Foundation
import Observation

/// Client-side snapshots and drafts only. Core remains the settings authority.
public enum PHPSettingsContext: Hashable, Sendable {
    case shared
    case version(String)
    public init(version: String?) { self = version.map(Self.version) ?? .shared }
    public var version: String? { if case .version(let version) = self { return version }; return nil }
}

public struct PHPSettingsDraft: Equatable, Sendable {
    public let baseline: PHPSettingsValues
    public var upload: String
    public var memory: String
    public var execution: String
    public var variables: String
    public init(settings: PHPSettingsValues) {
        baseline = settings
        upload = String(settings.uploadLimitMB); memory = String(settings.memoryLimitMB)
        execution = String(settings.maxExecutionTimeSeconds); variables = String(settings.maxInputVariables)
    }
    public var isDirty: Bool { self != Self(settings: baseline) }
    public var values: PHPSettingsValues? {
        guard let u = Int(upload), (1...2048).contains(u),
              let m = Int(memory), (16...4096).contains(m),
              let e = Int(execution), (0...86_400).contains(e),
              let v = Int(variables), (100...1_000_000).contains(v) else { return nil }
        let post = max(baseline.postLimitMB, u + 1)
        guard post <= 2049 else { return nil }
        return PHPSettingsValues(uploadLimitMB: u, memoryLimitMB: m, maxExecutionTimeSeconds: e, maxInputVariables: v, postLimitMB: post)
    }
}

@MainActor @Observable
public final class PHPConfigurationEditor {
    public var snapshot: PHPConfigurationResult?
    public var readError: String?
    public var readPending = false
    public private(set) var savingContext: PHPSettingsContext?
    public private(set) var saveErrors: [PHPSettingsContext: String] = [:]
    public private(set) var saveMessages: [PHPSettingsContext: String] = [:]
    public private(set) var drafts: [PHPSettingsContext: PHPSettingsDraft] = [:]
    private var readRevision = 0
    public init() {}

    public func draft(for context: PHPSettingsContext, settings: PHPSettingsValues) -> PHPSettingsDraft {
        drafts[context] ?? PHPSettingsDraft(settings: settings)
    }
    public func edit(_ context: PHPSettingsContext, settings: PHPSettingsValues, change: (inout PHPSettingsDraft) -> Void) {
        var draft = draft(for: context, settings: settings)
        change(&draft)
        drafts[context] = draft
        saveMessages[context] = nil
    }
    public func discardDraft(_ context: PHPSettingsContext, settings: PHPSettingsValues) {
        drafts[context] = PHPSettingsDraft(settings: settings)
    }
    public func invalidateReads() { readRevision += 1; readPending = false }

    private func adopt(_ result: PHPConfigurationResult, savedContext: PHPSettingsContext? = nil) {
        snapshot = result
        for context in Array(drafts.keys) {
            let settings = context.version.flatMap { version in result.versions.first { $0.version == version }?.settings }
                ?? (context == .shared ? result.defaultSettings : nil)
            guard let settings else { drafts[context] = nil; continue }
            // Keep dirty drafts on refresh; the form offers explicit reload if
            // Core's saved values changed underneath an edit.
            if context == savedContext || drafts[context]?.isDirty == false {
                drafts[context] = PHPSettingsDraft(settings: settings)
            }
        }
    }
    public func refresh(read: () async throws -> PHPConfigurationResult) async {
        guard savingContext == nil else { return }
        readRevision += 1
        let revision = readRevision
        readPending = true
        defer { if revision == readRevision { readPending = false } }
        do {
            let result = try await read()
            guard revision == readRevision else { return }
            adopt(result); readError = nil
        } catch {
            guard revision == readRevision else { return }
            readError = error.localizedDescription
        }
        // A successful read must not erase a save/reset failure.
    }
    public func save(context: PHPSettingsContext, settings: PHPSettingsValues?, write: () async throws -> PHPConfigurationResult) async {
        guard savingContext == nil else { return }
        invalidateReads()
        savingContext = context
        saveErrors[context] = nil; saveMessages[context] = nil
        defer { savingContext = nil }
        do {
            let result = try await write()
            invalidateReads()
            adopt(result, savedContext: context)
            if let version = context.version, let value = result.versions.first(where: { $0.version == version }) {
                drafts[context] = PHPSettingsDraft(settings: value.settings)
            } else if context == .shared { drafts[context] = PHPSettingsDraft(settings: result.defaultSettings) }
            let action = settings == nil ? "Reset to shared values." : "Settings saved."
            saveMessages[context] = result.affectedVersions.isEmpty
                ? action + " No running PHP-FPM instance needed a restart. Stopped runtimes use these values on their next start."
                : action + " Restarted PHP-FPM: " + result.affectedVersions.joined(separator: ", ") + "."
        } catch {
            saveErrors[context] = (settings == nil ? "Reset failed: " : "Save failed: ") + error.localizedDescription
        }
    }
}
