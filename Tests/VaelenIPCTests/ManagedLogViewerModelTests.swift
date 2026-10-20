import XCTest
@testable import VaelenCore
@testable import VaelenIPC

private actor TestReply<Value: Sendable> {
    private var result: Result<Value, CoreClientError>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func value() async throws -> Value {
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func started() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed(_ value: Value) {
        result = .success(value)
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(_ error: CoreClientError) {
        result = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private actor ScriptedManagedLogsClient: ManagedLogsClient {
    private let catalogReplies: [TestReply<[CoreLogEntry]>]
    private var catalogIndex = 0
    private let tailReplies: [String: [TestReply<CoreLogTail>]]
    private var tailIndexes: [String: Int] = [:]

    init(catalogs: [TestReply<[CoreLogEntry]>], tails: [String: [TestReply<CoreLogTail>]]) {
        catalogReplies = catalogs
        tailReplies = tails
    }

    func catalog() async throws -> [CoreLogEntry] {
        guard catalogIndex < catalogReplies.count else { throw CoreClientError.invalidResponse }
        let reply = catalogReplies[catalogIndex]
        catalogIndex += 1
        return try await reply.value()
    }

    func tail(id: String, lines: Int) async throws -> CoreLogTail {
        guard let replies = tailReplies[id] else { throw CoreClientError.invalidResponse }
        let index = tailIndexes[id, default: 0]
        guard index < replies.count else { throw CoreClientError.invalidResponse }
        tailIndexes[id] = index + 1
        return try await replies[index].value()
    }
}

@MainActor
final class ManagedLogViewerModelTests: XCTestCase {
    private let caddy = CoreLogEntry(id: "caddy", title: "Caddy", service: "Routing", status: .available, sizeBytes: 100)
    private let php = CoreLogEntry(id: "php-8.4.24", title: "PHP-FPM 8.4.24", service: "PHP", status: .available, sizeBytes: 20)

    func testCatalogSelectionAndCopyExposeExactDisplayedText() async {
        let catalog = TestReply<[CoreLogEntry]>()
        let tail = TestReply<CoreLogTail>()
        let model = ManagedLogViewerModel(client: ScriptedManagedLogsClient(catalogs: [catalog], tails: ["caddy": [tail]]))
        let loading = Task { await model.refresh() }
        await catalog.started()
        await catalog.succeed([caddy, php])
        await loading.value
        XCTAssertEqual(model.catalog.map(\.id), ["caddy", "php-8.4.24"])
        XCTAssertEqual(model.catalog.last?.title, "PHP-FPM 8.4.24")

        let reading = Task { await model.select(id: "caddy") }
        await tail.started()
        let exact = "line 1\nline 2\n"
        await tail.succeed(CoreLogTail(id: "caddy", text: exact, truncated: true, linesReturned: 2))
        await reading.value
        XCTAssertEqual(model.selectedLog?.title, "Caddy")
        XCTAssertEqual(model.copyText, exact)
        XCTAssertEqual(model.content, .text(exact, truncated: true, linesReturned: 2))
    }

    func testEmptyMissingUnreadableUnsafeAndDisconnectedReadsAreDistinct() async {
        let catalog = TestReply<[CoreLogEntry]>()
        let ids = ["caddy", "missing", "unreadable", "unsafe", "offline", "other"]
        let replies = Dictionary(uniqueKeysWithValues: ids.map { ($0, TestReply<CoreLogTail>()) })
        let entries = ids.map { CoreLogEntry(id: $0, title: $0, service: "Test", status: .available, sizeBytes: nil) }
        let model = ManagedLogViewerModel(client: ScriptedManagedLogsClient(catalogs: [catalog], tails: replies.mapValues { [$0] }))
        let loading = Task { await model.refresh() }
        await catalog.started(); await catalog.succeed(entries); await loading.value

        let emptyRead = Task { await model.select(id: "caddy") }
        await replies["caddy"]!.started(); await replies["caddy"]!.succeed(CoreLogTail(id: "caddy", text: "", truncated: false, linesReturned: 0)); await emptyRead.value
        XCTAssertEqual(model.content, .empty)
        let cases: [(String, IPCErrorCode, ManagedLogContentState)] = [
            ("missing", .logMissing, .missing), ("unreadable", .logUnreadable, .unreadable), ("unsafe", .logUnsafePath, .unsafePath), ("other", .internalError, .failed("failure")), ("offline", .internalError, .disconnected)
        ]
        for (id, code, expected) in cases {
            let read = Task { await model.select(id: id) }
            await replies[id]!.started()
            await replies[id]!.fail(id == "offline" ? .coreUnavailable : .remote(IPCErrorPayload(code: code, message: id == "offline" ? "offline" : "failure")))
            await read.value
            XCTAssertEqual(model.content, expected)
        }
    }

    func testLateReadCannotReplaceNewSelectionAndRemovedPHPIsReported() async {
        let catalog1 = TestReply<[CoreLogEntry]>(); let catalog2 = TestReply<[CoreLogEntry]>()
        let old = TestReply<CoreLogTail>(); let current = TestReply<CoreLogTail>()
        let model = ManagedLogViewerModel(client: ScriptedManagedLogsClient(catalogs: [catalog1, catalog2], tails: ["caddy": [old], "php-8.4.24": [current]]))
        let firstRefresh = Task { await model.refresh() }
        await catalog1.started(); await catalog1.succeed([caddy, php]); await firstRefresh.value

        let oldRead = Task { await model.select(id: "caddy") }
        await old.started()
        let newRead = Task { await model.select(id: "php-8.4.24") }
        await current.started(); await current.succeed(CoreLogTail(id: "php-8.4.24", text: "new", truncated: false, linesReturned: 1)); await newRead.value
        await old.succeed(CoreLogTail(id: "caddy", text: "stale", truncated: false, linesReturned: 1)); await oldRead.value
        XCTAssertEqual(model.copyText, "new")

        let refresh = Task { await model.refresh() }
        await catalog2.started(); await catalog2.succeed([caddy]); await refresh.value
        XCTAssertEqual(model.selectedID, nil)
        XCTAssertEqual(model.content, .removedFromCatalog("php-8.4.24"))
        XCTAssertNil(model.copyText)
    }

    func testOverlappingCatalogRefreshUsesNewestResponse() async {
        let older = TestReply<[CoreLogEntry]>(); let newer = TestReply<[CoreLogEntry]>()
        let model = ManagedLogViewerModel(client: ScriptedManagedLogsClient(catalogs: [older, newer], tails: [:]))
        let oldTask = Task { await model.refresh() }
        await older.started()
        let newTask = Task { await model.refresh() }
        await newer.started(); await newer.succeed([php]); await newTask.value
        await older.succeed([caddy]); await oldTask.value
        XCTAssertEqual(model.catalog.map(\.id), ["php-8.4.24"])
    }
}
