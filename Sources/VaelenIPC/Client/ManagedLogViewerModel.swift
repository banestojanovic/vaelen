import Foundation
import Observation
import VaelenCore

public protocol ManagedLogsClient: Sendable {
    func catalog() async throws -> [CoreLogEntry]
    func tail(id: String, lines: Int) async throws -> CoreLogTail
}

public struct CoreManagedLogsClient: ManagedLogsClient {
    private let makeClient: @Sendable () -> VaelenCoreClient

    public init() {
        makeClient = {
            VaelenCoreClient(
                transport: UnixSocketTransport(path: CoreEndpointPaths().socketPath),
                identity: ClientIdentity(name: "Vaelen.app.logs", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
            )
        }
    }

    public func catalog() async throws -> [CoreLogEntry] {
        try await withClient { try await $0.logsCatalog() }
    }

    public func tail(id: String, lines: Int) async throws -> CoreLogTail {
        try await withClient { try await $0.logsTail(id: id, lines: lines) }
    }

    private func withClient<T: Sendable>(_ operation: (VaelenCoreClient) async throws -> T) async throws -> T {
        let client = makeClient()
        do {
            try await client.connect()
            let result = try await operation(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

public enum ManagedLogCatalogState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case disconnected
    case failed(String)
}

public enum ManagedLogContentState: Equatable, Sendable {
    case idle
    case loading
    case empty
    case text(String, truncated: Bool, linesReturned: Int)
    case missing
    case unreadable
    case unsafePath
    case disconnected
    case failed(String)
    case removedFromCatalog(String)
}

@MainActor @Observable
public final class ManagedLogViewerModel {
    public static let lineChoices = [50, 100, 500]

    public private(set) var catalog: [CoreLogEntry] = []
    public private(set) var catalogState: ManagedLogCatalogState = .idle
    public private(set) var selectedID: String?
    public private(set) var lineCount = 100
    public private(set) var content: ManagedLogContentState = .idle

    private let client: any ManagedLogsClient
    private var catalogRevision = 0
    private var tailRevision = 0

    public init(client: any ManagedLogsClient) {
        self.client = client
    }

    public var selectedLog: CoreLogEntry? {
        guard let selectedID else { return nil }
        return catalog.first { $0.id == selectedID }
    }

    public var copyText: String? {
        guard case .text(let text, _, _) = content else { return nil }
        return text
    }

    public func refresh() async {
        catalogRevision += 1
        tailRevision += 1
        let requestedCatalogRevision = catalogRevision
        let requestedTailRevision = tailRevision
        catalogState = .loading
        if selectedID != nil { content = .loading }

        do {
            let result = try await client.catalog()
            guard requestedCatalogRevision == catalogRevision else { return }
            catalog = result
            catalogState = .loaded
            guard let selectedID else { return }
            guard result.contains(where: { $0.id == selectedID }) else {
                self.selectedID = nil
                tailRevision += 1
                content = .removedFromCatalog(selectedID)
                return
            }
            guard requestedTailRevision == tailRevision else { return }
            await loadTail(id: selectedID, revision: requestedTailRevision)
        } catch {
            guard requestedCatalogRevision == catalogRevision else { return }
            catalogState = catalogFailureState(error)
            guard selectedID != nil, requestedTailRevision == tailRevision else { return }
            content = contentFailureState(error)
        }
    }

    public func select(id: String?) async {
        if let id, !catalog.contains(where: { $0.id == id }) { return }
        tailRevision += 1
        let revision = tailRevision
        selectedID = id
        guard let id else { content = .idle; return }
        content = .loading
        await loadTail(id: id, revision: revision)
    }

    public func selectLineCount(_ value: Int) async {
        guard Self.lineChoices.contains(value), lineCount != value else { return }
        lineCount = value
        guard let selectedID else { return }
        tailRevision += 1
        let revision = tailRevision
        content = .loading
        await loadTail(id: selectedID, revision: revision)
    }

    public func invalidatePendingReads() {
        catalogRevision += 1
        tailRevision += 1
        if catalogState == .loading { catalogState = .idle }
        if content == .loading { content = .idle }
    }

    private func loadTail(id: String, revision: Int) async {
        do {
            let result = try await client.tail(id: id, lines: lineCount)
            guard revision == tailRevision, selectedID == id else { return }
            content = result.text.isEmpty
                ? .empty
                : .text(result.text, truncated: result.truncated, linesReturned: result.linesReturned)
        } catch {
            guard revision == tailRevision, selectedID == id else { return }
            content = contentFailureState(error)
        }
    }

    private func catalogFailureState(_ error: Error) -> ManagedLogCatalogState {
        if isDisconnected(error) { return .disconnected }
        return .failed(error.localizedDescription)
    }

    private func contentFailureState(_ error: Error) -> ManagedLogContentState {
        if isDisconnected(error) { return .disconnected }
        guard let clientError = error as? CoreClientError else { return .failed(error.localizedDescription) }
        switch clientError {
        case .remote(let payload):
            switch payload.code {
            case .logMissing: return .missing
            case .logUnreadable: return .unreadable
            case .logUnsafePath: return .unsafePath
            default: return .failed(payload.message)
            }
        default:
            return .failed(error.localizedDescription)
        }
    }

    private func isDisconnected(_ error: Error) -> Bool {
        if let clientError = error as? CoreClientError, case .coreUnavailable = clientError { return true }
        if let transportError = error as? CoreTransportError {
            switch transportError {
            case .unavailable, .notConnected: return true
            default: return false
            }
        }
        return false
    }
}
