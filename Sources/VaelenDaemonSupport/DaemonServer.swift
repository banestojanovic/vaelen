import Darwin
import Foundation
import OSLog
import VaelenCore
import VaelenIPC

public final class DaemonServer: @unchecked Sendable {
    private let paths: CoreEndpointPaths
    private let dispatcher: CoreRequestDispatcher
    private let lifecycleStore: SQLiteStateStore?
    private let lifecycleObservationProvider: (any LifecycleObservationProvider)?
    private let startupReconciliation: (() async throws -> Void)?
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "server")
    private var listener: Int32 = -1

    public init(paths: CoreEndpointPaths, dispatcher: CoreRequestDispatcher, lifecycleStore: SQLiteStateStore? = nil, lifecycleObservationProvider: (any LifecycleObservationProvider)? = nil, startupReconciliation: (() async throws -> Void)? = nil) {
        self.paths = paths
        self.dispatcher = dispatcher
        self.lifecycleStore = lifecycleStore
        self.lifecycleObservationProvider = lifecycleObservationProvider
        self.startupReconciliation = startupReconciliation
    }

    public func run() async throws {
        try paths.prepareDirectories()
        try paths.validateSocketPathLength()
        let lock = try DaemonLock(path: paths.lock.path)
        try lock.acquire()
        defer { lock.release() }
        // Admission is a short exclusive operation-bound handoff.  It is not
        // serving ownership and is released once endpoint/readiness setup is
        // complete; no descriptor crosses the launchd process boundary.
        let lifecycleBootstrapLock = try BootstrapLock.acquireServerExclusive(endpoint: paths.socketPath)
        var lifecycleBootstrapLockReleased = false
        defer { if !lifecycleBootstrapLockReleased { lifecycleBootstrapLock.release() } }
        if let lifecycleStore {
            let repository = LifecycleStateRepository(store: lifecycleStore, receiptAuthenticator: nil)
            let admissionCorrelation = UUID()
            try? lifecycleStore.recordDiagnostic(.init(correlationID: admissionCorrelation, phase: .admission, outcome: "started", detail: "daemon admission preflight", databasePath: lifecycleStore.databaseURL.path, operationID: nil))
            // Receipt MAC access is process-local. The daemon must establish
            // its own signed canonical provenance before reading a receipt;
            // controller preflight authorization cannot cross launchd.
            if let provider = lifecycleObservationProvider {
                let observation = await provider.observe(operationID: UUID(), generation: 0,
                                                         intent: .on, target: repository.canonicalTarget)
                 if observation.signatureValid == .true,
                   let team = observation.signingTeam,
                   let requirement = observation.designatedRequirement,
                   let artifact = observation.artifactHash {
                     try repository.authorizeBootstrapReceiptAccess(provenance: .init(signingTeam: team, designatedRequirement: requirement, artifactHash: artifact))
                 }
                 try repository.validateDaemonAdmission(observation: observation)
                 try? lifecycleStore.recordDiagnostic(.init(correlationID: admissionCorrelation, phase: .admission, outcome: "success", detail: "fresh runtime identity admitted", databasePath: lifecycleStore.databaseURL.path))
            } else {
                throw BootstrapError.refused("Daemon admission requires a lifecycle observation provider.")
            }
        }
        // Route/project reconciliation is pre-existing M0-M13 behavior, not
        // lifecycle authority.  It nevertheless runs only after daemon
        // admission has acquired the exclusive handoff lease, so startup
        // cannot touch lifecycle-sensitive runtime state before admission.
        try await startupReconciliation?()
        try removeStaleSocketIfNeeded()
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }
        defer { close(listener); listener = -1; unlink(paths.socketPath) }
        var address = try makeUnixAddress(path: paths.socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { throw CoreTransportError.systemCallFailed("bind", errno) }
        guard listen(listener, 16) == 0 else { throw CoreTransportError.systemCallFailed("listen", errno) }
         try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.socketPath)
         if let lifecycleStore { try? lifecycleStore.recordDiagnostic(.init(correlationID: UUID(), phase: .endpoint, outcome: "bound", detail: "canonical endpoint bound; readiness not yet proven", databasePath: lifecycleStore.databaseURL.path)) }
        setNoSigPipe(listener)
        logger.info("Core daemon started")

        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.stop() }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        // Keep the lifecycle handoff lease until a protocol-compatible client
        // has completed both handshake and an explicit ready response.  The
        // endpoint being bound/listening is not readiness evidence. Failed or
        // not-yet-ready admissions are closed and retried while serialization
        // remains held; no lock descriptor crosses the process boundary.
        var admitted = false
        while !admitted {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; if listener < 0 { return }; throw CoreTransportError.systemCallFailed("accept", errno) }
            setNoSigPipe(client)
            if !admitted { Self.setAdmissionReadTimeout(client) }
            admitted = await Self.handle(client, dispatcher: dispatcher, logger: logger, requireReady: true)
        }
        lifecycleBootstrapLock.release()
        lifecycleBootstrapLockReleased = true
        if let lifecycleStore { try? lifecycleStore.recordDiagnostic(.init(correlationID: UUID(), phase: .readiness, outcome: "success", detail: "handshake and ready response completed", databasePath: lifecycleStore.databaseURL.path)) }

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; if listener < 0 { return }; throw CoreTransportError.systemCallFailed("accept", errno) }
            setNoSigPipe(client)
            Task.detached { [dispatcher, logger] in
                _ = await Self.handle(client, dispatcher: dispatcher, logger: logger, requireReady: false)
            }
        }
    }

    private func stop() { let fd = listener; listener = -1; if fd >= 0 { close(fd) } }

    @discardableResult
    private static func handle(_ client: Int32, dispatcher: CoreRequestDispatcher, logger: Logger, requireReady: Bool) async -> Bool {
        defer { close(client) }
        var ready = !requireReady
        do {
            try validatePeer(client)
            var decoder = FrameDecoder(); var handshaken = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(client, &bytes, bytes.count)
                if count == 0 { return ready }
                if count < 0 { if errno == EINTR { continue }; throw CoreTransportError.systemCallFailed("read", errno) }
                for frame in try decoder.append(Data(bytes[0..<count])) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    if requireReady, !handshaken, request.knownMethod != .handshake { return false }
                    if requireReady, handshaken, request.knownMethod != .readiness { return false }
                    let result = await dispatcher.dispatch(request, handshaken: handshaken)
                    handshaken = result.handshaken
                    try writeAll(client, data: FrameEncoder().encode(IPCCodec.encode(result.response)))
                    if requireReady, request.knownMethod == .handshake, !handshaken { return false }
                    if requireReady, Self.readinessEstablished(request: request, response: result.response) {
                        ready = true
                        return true
                    }
                }
            }
        } catch { logger.error("Client connection ended: \(String(describing: error), privacy: .public)") }
        return ready
    }

    /// Admission evidence is deliberately stricter than endpoint reachability:
    /// only a successful canonical readiness response permits lock release.
    internal static func readinessEstablished(request: IPCRequest, response: IPCResponse) -> Bool {
        guard request.knownMethod == .readiness else { return false }
        guard case .coreReadiness(let readiness)? = response.result else { return false }
        return readiness.readiness == .ready
    }

    private static func validatePeer(_ client: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0 else { throw CoreTransportError.peerIdentityUnavailable }
        guard uid == getuid() else { throw CoreTransportError.unauthorizedPeer }
    }

    private static func setAdmissionReadTimeout(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw CoreTransportError.systemCallFailed("write", errno) }
                offset += count
            }
        }
    }

    private func removeStaleSocketIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: paths.socketPath) else { return }
        var info = stat(); guard lstat(paths.socketPath, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw CoreTransportError.systemCallFailed("socket endpoint is not a socket", EEXIST) }
        guard info.st_uid == getuid() else { throw CoreTransportError.unauthorizedPeer }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0); guard probe >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }; defer { close(probe) }
        var address = try makeUnixAddress(path: paths.socketPath)
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result == 0 { throw CoreTransportError.systemCallFailed("another daemon already owns the endpoint", EADDRINUSE) }
        guard errno == ECONNREFUSED || errno == ENOENT else { throw CoreTransportError.systemCallFailed("probe", errno) }
        guard unlink(paths.socketPath) == 0 else { throw CoreTransportError.systemCallFailed("unlink", errno) }
    }

    private func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

public final class DaemonLock {
    private let fd: Int32
    public init(path: String) throws { let value = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600); guard value >= 0 else { throw CoreTransportError.systemCallFailed("open lock", errno) }; fd = value }
    public func acquire() throws { guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CoreTransportError.systemCallFailed("acquire daemon lock", errno) } }
    public func release() { _ = flock(fd, LOCK_UN); close(fd) }
}
