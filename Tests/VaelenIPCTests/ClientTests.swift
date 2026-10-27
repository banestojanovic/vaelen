import XCTest
@testable import VaelenCore
@testable import VaelenIPC

final class ClientTests: XCTestCase {
    func testInvalidTestRuntimeRejectsBeforeTransportConnect() async throws {
        let invalidEnvironment = ["VAELEN_TEST_ALLOW_CORE_START": "1"]
        let isolatedEnvironment = [
            "VAELEN_TEST_ALLOW_CORE_START": "1",
            "VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1",
            "VAELEN_TEST_SUPPORT_ROOT": "/tmp/vaelen-fixture"
        ]

        let invalidTransport = ConnectRecordingTransport()
        let invalidClient = VaelenCoreClient(
            transport: invalidTransport,
            identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version),
            allowsConnection: { !VaelenTestRuntimePaths.hasInvalidCoreRuntime(environment: invalidEnvironment) }
        )
        do {
            try await invalidClient.connect()
            XCTFail("Invalid test runtime must reject Core connections")
        } catch CoreClientError.coreUnavailable {
        }
        let invalidConnectCount = await invalidTransport.connectCount()
        XCTAssertEqual(invalidConnectCount, 0)

        for environment in [isolatedEnvironment, [:]] {
            let transport = ConnectRecordingTransport()
            let client = VaelenCoreClient(
                transport: transport,
                identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version),
                allowsConnection: { !VaelenTestRuntimePaths.hasInvalidCoreRuntime(environment: environment) }
            )
            do {
                try await client.connect()
                XCTFail("Recording transport should fail after recording connect")
            } catch CoreClientError.coreUnavailable {
            }
            let connectCount = await transport.connectCount()
            XCTAssertEqual(connectCount, 1)
        }
    }

    func testConcurrentCallsOnOneClientNeverCompeteForResponseReader() async throws {
        let transport = ConcurrentReadProbeTransport()
        let client = VaelenCoreClient(transport: transport, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        try await client.connect()

        async let status = client.status()
        async let projects = client.projectList()
        let (resolvedStatus, resolvedProjects) = try await (status, projects)

        XCTAssertEqual(resolvedStatus.core.pid, 99)
        XCTAssertTrue(resolvedProjects.isEmpty)
        let maximumConcurrentReads = await transport.maximumConcurrentReads()
        XCTAssertEqual(maximumConcurrentReads, 1, "A single CoreClient must serialize request/response exchanges")
        await client.disconnect()
    }

    func testSnapshotExpiredAndCoreRestartRetryProjectReportWithoutSnapshot() async throws {
        for failureMode in [SnapshotFallbackTransport.FailureMode.expired, .coreRestart] {
            let transport = SnapshotFallbackTransport(failureMode: failureMode)
            let client = VaelenCoreClient(transport: transport, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
            try await client.connect()
            let token = UUID()
            do {
                _ = try await client.projectStatus(selector: "project", workingDirectory: "/tmp/project", snapshotID: token)
                XCTFail("Fixture's project-not-found response should remain visible after fallback")
            } catch let error as CoreClientError {
                guard case .remote(let payload) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(payload.code, .projectNotFound)
            }
            let requests = await transport.projectRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(try requests[0].params?.decode(ProjectEnvironmentRequest.self).snapshotID, token)
            XCTAssertNil(try requests[1].params?.decode(ProjectEnvironmentRequest.self).snapshotID)
            if failureMode == .coreRestart {
                let connectCount = await transport.connectCount()
                XCTAssertEqual(connectCount, 2, "A restarted Core requires a new socket connection and handshake")
            }
            await client.disconnect()
        }
    }

    func testSeparateCoreClientConnectionsCanProgressConcurrently() async throws {
        let barrier = TwinConnectionReadBarrier()
        let first = VaelenCoreClient(transport: IndependentConnectionTransport(barrier: barrier), identity: ClientIdentity(name: "first", version: VaelenBuildInfo.version))
        let second = VaelenCoreClient(transport: IndependentConnectionTransport(barrier: barrier), identity: ClientIdentity(name: "second", version: VaelenBuildInfo.version))
        try await first.connect()
        try await second.connect()

        async let firstStatus = first.status()
        async let secondStatus = second.status()
        let statuses = try await (firstStatus, secondStatus)
        XCTAssertEqual(statuses.0.core.pid, 101)
        XCTAssertEqual(statuses.1.core.pid, 101)
        await first.disconnect()
        await second.disconnect()
    }

    func testSharedClientUsesInMemoryTransport() async throws {
        let pair = InMemoryTransport.pair()
        let client = VaelenCoreClient(
            transport: pair.client,
            identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version)
        )
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let response: IPCResponse
                    switch request.knownMethod! {
                    case .handshake:
                        response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                    case .status:
                        response = IPCResponse(id: request.id, result: .status(.init(core: .init(state: .running, version: "0.0.1-dev", pid: 99), protocolVersion: 1)))
                    default:
                        XCTFail("Unexpected test method")
                        return
                    }
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(response)))
                }
            }
        }

        try await client.connect()
        let status = try await client.status()
        await client.disconnect()
        server.cancel()

        XCTAssertEqual(status.core.pid, 99)
        XCTAssertEqual(status.core.version, "0.0.1-dev")
    }

    func testClientUsesTypedCoreShutdownOperation() async throws {
        let pair = InMemoryTransport.pair()
        let recorder = RequestRecorder()
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    recorder.append(request.method)
                    let result: ResponseResult = request.knownMethod == .handshake
                        ? .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
                        : .shutdown(.init(components: [.init(component: "all", succeeded: true, detail: "done")]))
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(IPCResponse(id: request.id, result: result))))
                }
            }
        }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        try await client.connect()
        let result = try await client.shutdown()
        await client.disconnect(); server.cancel()
        XCTAssertTrue(result.completed)
        XCTAssertEqual(recorder.methods, [CoreMethod.handshake.rawValue, CoreMethod.shutdown.rawValue])
    }

    func testClientSendsParameterlessTrustOperationsAndDecodesTypedResults() async throws {
        let pair = InMemoryTransport.pair()
        let recorder = RequestRecorder()
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    recorder.append(request.method)
                    let response: IPCResponse
                    if request.knownMethod == .handshake {
                        response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                    } else {
                        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .confirmedByVaelen)
                        let result = TLSTrustResult(status: status, operation: .confirmed, message: "ok")
                        response = IPCResponse(id: request.id, result: .tlsTrust(.init(result: result)))
                    }
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(response)))
                }
            }
        }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        try await client.connect()
        _ = try await client.tlsTrustLocalCA()
        _ = try await client.tlsRemoveLocalCATrust()
        await client.disconnect()
        server.cancel()
        XCTAssertEqual(recorder.methods, [CoreMethod.handshake.rawValue, CoreMethod.tlsTrustLocalCA.rawValue, CoreMethod.tlsRemoveLocalCATrust.rawValue])
    }

    func testOlderCoreMissingSchemaIdentityFailsBeforeNormalDispatch() async throws {
        let pair = InMemoryTransport.pair()
        let recorder = RequestRecorder()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 1, coreVersion: "0.0.10-dev"))), recorder: recorder)
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("stale Core should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(recorder.methods, [CoreMethod.handshake.rawValue])
        server.cancel()
    }

    func testNewerSchemaIdentityFailsStrictly() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 1, coreVersion: "0.0.12-dev", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion + 1, buildIdentity: "future"))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("newer Core should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testSchemaSixClientRejectsPreviousSchemaFiveCoreBeforeCommands() async throws {
        let pair = InMemoryTransport.pair()
        let recorder = RequestRecorder()
        let previousCore = IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 1, coreVersion: "schema-5", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion - 1, buildIdentity: "previous")))
        let server = handshakeServer(pair.server, response: previousCore, recorder: recorder)
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "current", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("Schema-6 client must reject a schema-5 Core")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(recorder.methods, [CoreMethod.handshake.rawValue], "No normal request may follow an incompatible handshake")
        server.cancel()
    }

    func testProtocolMismatchRemainsDistinctFromSchemaMismatch() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 2, coreVersion: "future", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("protocol mismatch should be rejected")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .protocolIncompatible(client: 1, core: 2))
        }
        server.cancel()
    }

    func testUnknownHandshakeResponseIsClassifiedAsIncompatible() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), error: .init(code: .invalidRequest, message: "unknown method")))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("old handshake should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testMalformedHandshakeResultIsClassifiedAsIncompatible() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .status(.init(core: .init(state: .running, version: "old", pid: 1), protocolVersion: 1))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("malformed handshake should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testMalformedNormalResponseRemainsInvalidResponseAfterValidHandshake() async throws {
        let pair = InMemoryTransport.pair()
        let server = Task {
            try? await pair.server.connect()
            var decoder = FrameDecoder()
            var count = 0
            while count < 2, let data = try? await pair.server.read() {
                for frame in try! decoder.append(data) {
                    let request = try! IPCCodec.decode(IPCRequest.self, from: frame)
                    count += 1
                    if request.knownMethod == .handshake {
                        let response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                        try? await pair.server.write(FrameEncoder().encode(IPCCodec.encode(response)))
                    } else {
                        let invalid = Data("{\"id\":\"\(request.id.uuidString)\",\"protocolVersion\":1}".utf8)
                        try? await pair.server.write(FrameEncoder().encode(invalid))
                    }
                }
            }
        }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        try await client.connect()
        do {
            _ = try await client.status()
            XCTFail("malformed normal response should fail")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        server.cancel()
    }

    func testUnavailableCoreRemainsDistinct() async throws {
        let client = VaelenCoreClient(transport: UnavailableTransport(), identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        do {
            try await client.connect()
            XCTFail("unavailable Core should fail")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .coreUnavailable)
        }
    }

    private func handshakeServer(_ server: InMemoryTransport, response: IPCResponse, recorder: RequestRecorder? = nil) -> Task<Void, Never> {
        Task {
            try? await server.connect()
            var decoder = FrameDecoder()
            guard let data = try? await server.read(), let frames = try? decoder.append(data) else { return }
            for frame in frames {
                guard let request = try? IPCCodec.decode(IPCRequest.self, from: frame) else { return }
                recorder?.append(request.method)
                let reply: IPCResponse
                if let result = response.result {
                    reply = IPCResponse(id: request.id, result: result)
                } else if let error = response.error {
                    reply = IPCResponse(id: request.id, error: error)
                } else {
                    return
                }
                try? await server.write(FrameEncoder().encode(IPCCodec.encode(reply)))
            }
        }
    }
}

private actor ConnectRecordingTransport: CoreTransport {
    private var connections = 0
    func connect() async throws {
        connections += 1
        throw CoreTransportError.unavailable
    }
    func write(_ data: Data) async throws { throw CoreTransportError.notConnected }
    func read() async throws -> Data { throw CoreTransportError.notConnected }
    func disconnect() async {}
    func connectCount() -> Int { connections }
}

private actor ConcurrentReadProbeTransport: CoreTransport {
    private var decoder = FrameDecoder()
    private var responses: [Data] = []
    private var activeReads = 0
    private var maxActiveReads = 0

    func connect() async throws {}
    func disconnect() async {}

    func write(_ data: Data) async throws {
        for frame in try decoder.append(data) {
            let request = try IPCCodec.decode(IPCRequest.self, from: frame)
            let result: ResponseResult
            switch request.knownMethod {
            case .handshake:
                result = .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            case .status:
                result = .status(.init(core: .init(state: .running, version: "test", pid: 99), protocolVersion: 1))
            case .projectList:
                result = .projectList(.init(projects: []))
            default:
                throw CoreClientError.invalidResponse
            }
            responses.append(try FrameEncoder().encode(IPCCodec.encode(IPCResponse(id: request.id, result: result))))
        }
    }

    func read() async throws -> Data {
        guard !responses.isEmpty else { throw CoreTransportError.unavailable }
        activeReads += 1
        maxActiveReads = max(maxActiveReads, activeReads)
        let response = responses.removeFirst()
        try await Task.sleep(for: .milliseconds(20))
        activeReads -= 1
        return response
    }

    func maximumConcurrentReads() -> Int { maxActiveReads }
}

private actor SnapshotFallbackTransport: CoreTransport {
    enum FailureMode: Equatable { case expired, coreRestart }
    private let failureMode: FailureMode
    private var decoder = FrameDecoder()
    private var responses: [Data] = []
    private var requests = [IPCRequest]()
    private var connects = 0
    private var emittedRestart = false

    init(failureMode: FailureMode) { self.failureMode = failureMode }
    func connect() async throws { connects += 1 }
    func disconnect() async {}

    func write(_ data: Data) async throws {
        for frame in try decoder.append(data) {
            let request = try IPCCodec.decode(IPCRequest.self, from: frame)
            if request.knownMethod == .projectStatus { requests.append(request) }
            if request.knownMethod == .handshake {
                try enqueue(.init(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: "test", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))))
                continue
            }
            guard request.knownMethod == .projectStatus else { throw CoreClientError.invalidResponse }
            let projectRequest = try request.params?.decode(ProjectEnvironmentRequest.self)
            if failureMode == .coreRestart, projectRequest?.snapshotID != nil, !emittedRestart {
                emittedRestart = true
                throw CoreTransportError.unavailable
            }
            if projectRequest?.snapshotID != nil {
                try enqueue(.init(id: request.id, error: .init(code: .projectObservationSnapshotExpired, message: "snapshot expired")))
            } else {
                try enqueue(.init(id: request.id, error: .init(code: .projectNotFound, message: "fixture project not found")))
            }
        }
    }

    func read() async throws -> Data {
        guard !responses.isEmpty else { throw CoreTransportError.unavailable }
        return responses.removeFirst()
    }

    func projectRequests() -> [IPCRequest] { requests }
    func connectCount() -> Int { connects }
    private func enqueue(_ response: IPCResponse) throws {
        responses.append(try FrameEncoder().encode(IPCCodec.encode(response)))
    }
}

private actor TwinConnectionReadBarrier {
    private var arrivals = 0
    private var waiters = [CheckedContinuation<Void, Never>]()
    func arriveAndWait() async {
        arrivals += 1
        if arrivals == 2 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

private actor IndependentConnectionTransport: CoreTransport {
    private let barrier: TwinConnectionReadBarrier
    private var decoder = FrameDecoder()
    private var responses: [(data: Data, waitForPeer: Bool)] = []
    init(barrier: TwinConnectionReadBarrier) { self.barrier = barrier }
    func connect() async throws {}
    func disconnect() async {}
    func write(_ data: Data) async throws {
        for frame in try decoder.append(data) {
            let request = try IPCCodec.decode(IPCRequest.self, from: frame)
            let response: IPCResponse
            let waitForPeer: Bool
            switch request.knownMethod {
            case .handshake:
                response = .init(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: "test", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                waitForPeer = false
            case .status:
                response = .init(id: request.id, result: .status(.init(core: .init(state: .running, version: "test", pid: 101), protocolVersion: 1)))
                waitForPeer = true
            default: throw CoreClientError.invalidResponse
            }
            responses.append((try FrameEncoder().encode(IPCCodec.encode(response)), waitForPeer))
        }
    }
    func read() async throws -> Data {
        guard !responses.isEmpty else { throw CoreTransportError.unavailable }
        let response = responses.removeFirst()
        if response.waitForPeer { await barrier.arriveAndWait() }
        return response.data
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String]()
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct UnavailableTransport: CoreTransport {
    func connect() async throws { throw CoreTransportError.unavailable }
    func write(_ data: Data) async throws { throw CoreTransportError.notConnected }
    func read() async throws -> Data { throw CoreTransportError.unavailable }
    func disconnect() async {}
}
