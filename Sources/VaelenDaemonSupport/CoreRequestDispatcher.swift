import Foundation
import OSLog
import VaelenCore
import VaelenIPC

public actor CoreRequestDispatcher {
    private let runtime: CoreRuntime
    private let registry: ProjectRegistry
    private let php: PHPModule?
    private let mysql: MySQLModule?
    private let mailpit: MailpitModule?
    private let router: any Router
    private let routeRepository: RouteIntentRepository?
    private let dns: DNSCapability
    private let tls: TLSCapability
    private let ports: StandardPortsCapability
    private let lifecycle: LifecycleStateRepository?
    private let lifecycleExecutor: any CoreIssuedLifecycleExecutor
    private let lifecycleObservationProvider: any LifecycleObservationProvider
    private let lifecycleSessionBinding: UUID
    private let lifecycleTimeoutNanoseconds: UInt64
    private var routeIntents: [RouteID: RouteIntent]
    /// Envelopes which have crossed the Core authorization boundary but have
    /// not yet returned.  A newer durable intent must revoke these before it
    /// can dispatch its own operation; the durable generation fence alone is
    /// not sufficient because the platform adapter is an asynchronous actor.
    private var authorizedLifecycleRequests: [UUID: LifecycleExecutorRequest] = [:]
    /// A timed-out On may still be suspended inside a non-cancellable
    /// platform call after its authorization envelope is removed.  Retain
    /// that ambiguity as an operation-level fence; a later Off must not use a
    /// stale absent pre-observation as an idempotent success.
    private var ambiguousLifecycleOnOperations: Set<UUID> = []
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "registry")

    public init(runtime: CoreRuntime, registry: ProjectRegistry, php: PHPModule? = nil, mysql: MySQLModule? = nil, mailpit: MailpitModule? = nil, router: any Router = InMemoryRouter(), routeRepository: RouteIntentRepository? = nil, dns: DNSCapability = DNSCapability(), tls: TLSCapability = TLSCapability(), ports: StandardPortsCapability = StandardPortsCapability(), lifecycleStore: SQLiteStateStore? = nil, lifecycleReceiptAuthenticator: (any BootstrapReceiptAuthenticator)? = nil, lifecycleExecutor: any LifecyclePlatformExecutor = UnavailableLifecycleExecutor(), lifecycleObservationProvider: any LifecycleObservationProvider = UnavailableLifecycleObservationProvider(), lifecycleSessionBinding: UUID? = nil, lifecycleTimeoutNanoseconds: UInt64 = 5_000_000_000) throws {
         self.runtime = runtime; self.registry = registry; self.php = php; self.mysql = mysql; self.mailpit = mailpit; self.router = router; self.routeRepository = routeRepository; self.dns = dns; self.tls = tls; self.ports = ports; self.lifecycle = lifecycleStore.map { LifecycleStateRepository(store: $0, receiptAuthenticator: lifecycleReceiptAuthenticator) }; self.lifecycleExecutor = (lifecycleExecutor as? any CoreIssuedLifecycleExecutor) ?? RefusingLifecycleExecutor(); self.lifecycleObservationProvider = lifecycleObservationProvider; self.lifecycleSessionBinding = lifecycleSessionBinding ?? UUID(); self.lifecycleTimeoutNanoseconds = lifecycleTimeoutNanoseconds
        let persistedRoutes = try routeRepository?.all() ?? []
        _ = try routeRepository?.pendingTransitions()
        self.routeIntents = Dictionary(uniqueKeysWithValues: persistedRoutes.map { ($0.route.id, $0) })
    }

    public func dispatch(_ request: IPCRequest, handshaken: Bool) async -> (response: IPCResponse, handshaken: Bool) {
        guard request.protocolVersion == ProtocolVersion.v1.rawValue else {
            return (.init(id: request.id, error: .init(code: .protocolIncompatible, message: "Client and Core protocol versions are incompatible.", details: ["clientProtocolVersion": "\(request.protocolVersion)", "coreProtocolVersion": "1"])), handshaken)
        }
        guard let method = request.knownMethod else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Unknown Core method: \(request.method).")), handshaken)
        }
        if method == .handshake {
            guard let params = request.params, let handshake = try? params.decode(HandshakeParams.self), let schema = handshake.client.schemaCompatibilityVersion else {
                return (.init(id: request.id, error: .init(code: .coreIncompatible, message: "The client does not provide the required Core compatibility identity.")), false)
            }
            guard schema == VaelenBuildInfo.schemaCompatibilityVersion else {
                return (.init(id: request.id, error: .init(code: .coreIncompatible, message: "The client uses an incompatible command schema.", details: ["clientSchemaCompatibilityVersion": "\(schema)", "coreSchemaCompatibilityVersion": "\(VaelenBuildInfo.schemaCompatibilityVersion)"])), false)
            }
            return (.init(id: request.id, result: .handshake(.init(protocolVersion: VaelenBuildInfo.protocolVersion.rawValue, coreVersion: runtime.status.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))), true)
        }
        guard handshaken else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Handshake is required before other requests.")), false)
        }
        do {
            switch method {
            case .status:
                return (.init(id: request.id, result: .status(.init(core: runtime.status, protocolVersion: 1))), true)
            case .readiness:
                // This is a direct Core-owned answer. It must not call the
                // lifecycle observation provider (which itself probes this
                // contract), or readiness would recursively observe itself.
                return (.init(id: request.id, result: .coreReadiness(.init(readiness: runtime.isReady ? .ready : .starting, protocolVersion: 1))), true)
            case .lifecycleOn, .lifecycleOff:
                guard let lifecycle else { throw IPCErrorPayload(code: .lifecycleUnavailable, message: "Lifecycle persistence is unavailable.") }
                // Read before attempting the lease as well as after acquiring
                // it.  This ensures a bootstrap that already owns the shared
                // lease is reported as recovery-required, rather than being
                // flattened into an unrelated lock/refusal error.
                try lifecycle.requireBootstrapPromotion()
                // Bootstrap holds a shared handoff lease from reservation
                // through promotion. Ordinary lifecycle mutations require
                // the exclusive lease and must refuse rather than supersede
                // that receipt or wait behind it.
                 let lifecycleHandoffLock: BootstrapLock
                  do { lifecycleHandoffLock = try BootstrapLock.acquireExclusive(endpoint: lifecycle.canonicalTarget.endpoint) }
                 catch {
                     // A bootstrap may have reserved between the first read
                     // and the exclusive acquisition. Re-read the receipt so
                     // that race is still the structured recovery boundary.
                     try lifecycle.requireBootstrapPromotion()
                      throw error
                  }
                  var lifecycleHandoffLockReleased = false
                  defer { if !lifecycleHandoffLockReleased { lifecycleHandoffLock.release() } }
                 // This barrier must be read after taking the exclusive lease
                 // and before request(), which can supersede durable journal
                 // state.  A reserved, succeeded, failed, unknown, or
                 // malformed receipt therefore becomes structured recovery
                 // required rather than a normal lifecycle mutation.
                 try lifecycle.requireBootstrapPromotion()
                 let params = try request.params?.decode(LifecycleRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Lifecycle target is required.") }()
                guard params.target == lifecycle.canonicalTarget else {
                    throw IPCErrorPayload(code: .invalidRequest, message: "Lifecycle target identity is Core-owned and must be canonical.")
                }
                let intent: LifecycleIntent = method == .lifecycleOn ? .on : .off
                 let operationID = UUID()
                   // Revoke every older authorized envelope before installing
                   // the newer generation.  This is the last Core-side fence
                   // before an On envelope could cross into SMAppService.
                   let superseded = Array(authorizedLifecycleRequests.values)
                   // An authorized On may already be suspended inside the
                   // non-cancellable platform call.  Its pre-observation can
                   // therefore be stale by the time this Off observes the
                   // platform.  Do not turn that ambiguity into an idempotent
                   // Off success merely because the fresh observation happens
                   // to be absent; the durable Off must remain recovery-required.
                   let supersededPlatformOn = superseded.contains { $0.intent == .on } || !ambiguousLifecycleOnOperations.isEmpty
                   for prior in superseded {
                      await lifecycleExecutor.invalidate(operationID: prior.operationID, nonce: prior.nonce)
                      authorizedLifecycleRequests.removeValue(forKey: prior.operationID)
                  }
                  let pre = await lifecycleObservationProvider.observe(operationID: operationID, generation: 0, intent: intent, target: lifecycle.canonicalTarget)
                  let offOwned: Bool
                  let onOwned: Bool
                   if method == .lifecycleOff && pre.registrationMatch == .true && pre.signatureValid == .true {
                        offOwned = try lifecycle.hasValidOwnership(for: lifecycle.canonicalTarget, observation: pre)
                   } else { offOwned = false }
                   if method == .lifecycleOn && pre.registrationMatch == .true {
                       onOwned = try lifecycle.hasValidOwnership(for: lifecycle.canonicalTarget, observation: pre)
                   } else { onOwned = false }
                  if method == .lifecycleOff {
                      // Off is always durable. An absent registration is an
                      // idempotent no-op; an unowned/foreign registration is
                      // fenced but never handed to SMAppService.
                  } else if pre.registrationMatch == .true {
                      guard onOwned else {
                          throw IPCErrorPayload(code: .invalidRequest, message: "Lifecycle on refused: an existing registration cannot be adopted without durable ownership and provenance.")
                      }
                 }
                  // Mint the executor credentials before the durable operation
                  // row is written. The row is therefore a complete fence
                  // before mark-in-flight or any platform call.
                  let executorNonce = UUID()
                  let executorSessionBinding = lifecycleSessionBinding
                  let operation = try lifecycle.request(intent: intent, actor: params.actor, target: params.target, preObservation: pre, operationID: operationID, nonce: executorNonce, sessionBinding: executorSessionBinding, processIdentity: pre.processIdentity)
                 guard try lifecycle.markInFlight(operationID: operation.operationID, generation: operation.generation) else {
                     throw IPCErrorPayload(code: .invalidRequest, message: "Lifecycle operation was fenced before dispatch.")
                 }
                  // The durable pending row and the Core-issued envelope are
                  // now fenced. Release the coordination lease before the
                  // bounded external call so a newer Off can acquire it and
                  // revoke this envelope while the executor is suspended.
                  lifecycleHandoffLock.release()
                  lifecycleHandoffLockReleased = true
                  let deadline = Date().addingTimeInterval(Double(lifecycleTimeoutNanoseconds) / 1_000_000_000)
                   let executorResult: LifecycleExecutorResult
                    // The current Off supersedes in-flight work before this
                    // point, so also consult historical unknown register rows
                    // after request() has installed the durable Off barrier.
                    let durableAmbiguousOn: Bool
                    if method == .lifecycleOff {
                        durableAmbiguousOn = try lifecycle.hasAmbiguousOnOperation()
                    } else {
                        durableAmbiguousOn = false
                    }
                    if method == .lifecycleOff && (supersededPlatformOn || durableAmbiguousOn) {
                        executorResult = .init(state: .unknown, detail: "An On platform attempt is ambiguous; recovery observation is required before Off can complete.")
                    } else if method == .lifecycleOff && !offOwned {
                       executorResult = supersededPlatformOn
                           ? .init(state: .unknown, detail: "An in-flight On may have crossed the platform boundary; recovery observation is required.")
                           : .init(state: .success, detail: pre.registrationMatch == .false ? "No registration to unregister." : "Registration is not durably owned; platform mutation withheld.")
                  } else {
                         let executorRequest = LifecycleExecutorRequest(operationID: operation.operationID, generation: operation.generation, intent: intent, target: lifecycle.canonicalTarget, actor: params.actor, nonce: executorNonce, deadline: deadline, sessionBinding: executorSessionBinding, processIdentity: pre.processIdentity, allowExistingRegistration: onOwned)
                        // Publish the pending envelope before the actor hop.
                        // Core is re-entrant while authorize awaits; a newer
                        // Off must therefore be able to discover and revoke
                        // this request during that hop.
                        authorizedLifecycleRequests[executorRequest.operationID] = executorRequest
                        await lifecycleExecutor.authorize(executorRequest)
                         executorResult = await boundedLifecycleExecution(executorRequest)
                         authorizedLifecycleRequests.removeValue(forKey: executorRequest.operationID)
                          // Unknown, timeout, and unavailable are conservative
                          // platform-attempt outcomes for On. Record the
                          // in-memory fence before returning/observing so a
                          // re-entrant Off cannot treat absence as proof.
                          if intent == .on && executorResult.state != .success && executorResult.state != .rejected {
                              ambiguousLifecycleOnOperations.insert(executorRequest.operationID)
                          }
                         if executorResult.state == .timeout || executorResult.state == .unknown {
                            await lifecycleExecutor.invalidate(operationID: executorRequest.operationID, nonce: executorRequest.nonce)
                        }
                  }
                 let post = await lifecycleObservationProvider.observe(operationID: operation.operationID, generation: operation.generation, intent: intent, target: lifecycle.canonicalTarget)
                guard try lifecycle.accepts(operationID: operation.operationID, generation: operation.generation) else {
                    // A newer generation (most importantly Off) became the
                    // barrier while the platform call was outstanding. The
                    // result is intentionally not projected into the response
                    // as success and cannot alter the newer journal row.
                    let fenced = LifecycleObservationVector(reason: "Lifecycle executor result was fenced by a newer generation.")
                    return (.init(id: request.id, result: .lifecycle(.init(intent: try lifecycle.intent(), operation: try lifecycle.operation(), observation: fenced, readiness: .unknown))), true)
                }
                 let successObservation = executorResult.state == .success && lifecycleSuccessGate(intent: intent, observation: post)
                 let journalState: LifecycleJournalState = successObservation ? .succeeded : executorResult.state == .rejected ? .failed : .unknownRecoveryRequired
                // The completion UPDATE repeats the operation/generation fence,
                // so an Off (or any newer generation) cannot be reversed by a
                // delayed executor result.
                  try lifecycle.complete(operationID: operation.operationID, generation: operation.generation, state: journalState, postObservation: post, error: executorResult.detail)
                   if intent == .on && successObservation {
                       try lifecycle.saveOwnership(.init(target: lifecycle.canonicalTarget, signingTeam: post.signingTeam, designatedRequirement: post.designatedRequirement, artifactHash: post.artifactHash, operationID: operation.operationID, generation: operation.generation))
                  }
                let record = try lifecycle.intent()
                return (.init(id: request.id, result: .lifecycle(.init(intent: record, operation: try lifecycle.operation(), observation: post, readiness: post.isReady ? .ready : .unknown))), true)
            case .lifecycleStatus:
                guard let lifecycle else { throw IPCErrorPayload(code: .lifecycleUnavailable, message: "Lifecycle persistence is unavailable.") }
                 let observation = await lifecycleObservationProvider.observe(operationID: UUID(), generation: 0, intent: (try lifecycle.intent()?.intent ?? .on), target: lifecycle.canonicalTarget)
                return (.init(id: request.id, result: .lifecycle(.init(intent: try lifecycle.intent(), operation: try lifecycle.operation(), observation: observation, readiness: observation.isReady ? .ready : .unknown))), true)
            case .lifecycleReadiness:
                 let observation = await lifecycleObservationProvider.observe(operationID: UUID(), generation: 0, intent: (try lifecycle?.intent()?.intent ?? .on), target: lifecycle?.canonicalTarget ?? LifecycleCanonicalIdentity.target)
                 return (.init(id: request.id, result: .lifecycleReadiness(.init(readiness: observation.isReady ? .ready : .unknown, observation: observation))), true)
            case .lifecycleBootstrapPromote:
                guard let lifecycle else { throw IPCErrorPayload(code: .lifecycleUnavailable, message: "Lifecycle persistence is unavailable.") }
                guard let params = try request.params?.decode(BootstrapPromotionRequest.self) else { throw IPCErrorPayload(code: .invalidRequest, message: "Bootstrap receipt promotion parameters are required.") }
                 // The Core process has its own authenticator instance. Bind
                 // it to the fresh signed observation before it reads the
                 // receipt, while still allowing the CLI's authenticated
                 // receipt to cross the process boundary.
                 let observation = await lifecycleObservationProvider.observe(operationID: UUID(), generation: 0, intent: .on, target: lifecycle.canonicalTarget)
                 guard let team = observation.signingTeam,
                       let requirement = observation.designatedRequirement,
                       let artifact = observation.artifactHash,
                       observation.signatureValid == .true else { throw BootstrapError.invalidReceipt }
                  try lifecycle.authorizeBootstrapReceiptAccess(provenance: .init(signingTeam: team, designatedRequirement: requirement, artifactHash: artifact))
                  let context = try lifecycle.bootstrapPromotionContext(invocationToken: params.invocationToken, epoch: params.epoch, operationID: params.operationID, nonce: params.nonce)
                  let promotedObservation = await lifecycleObservationProvider.observe(operationID: context.operationID, generation: context.generation, intent: .on, target: lifecycle.canonicalTarget)
                  let promoted = try lifecycle.promoteBootstrap(invocationToken: params.invocationToken, observation: promotedObservation, epoch: params.epoch, operationID: params.operationID, nonce: params.nonce)
                  return (.init(id: request.id, result: .lifecycle(promoted)), true)
            case .projectLink:
                let params = try request.params?.decode(LinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Link parameters are required.") }()
                let mutation = try await registry.linkWithCreation(path: params.path, workingDirectory: params.workingDirectory, name: params.name)
                let project = mutation.project
                logger.info("Project linked: \(project.rootPath.string, privacy: .public)")
                return (.init(id: request.id, result: .projectMutation(.init(project: .init(project), created: mutation.created))), true)
            case .projectUnlink:
                let params = try request.params?.decode(UnlinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unlink parameters are required.") }()
                if let name = params.name { try await registry.unlink(name: name) }
                else { try await registry.unlink(path: params.path ?? params.workingDirectory, workingDirectory: params.workingDirectory) }
                logger.info("Project unlinked")
                return (.init(id: request.id, result: .projectMutation(.init(project: nil, created: false))), true)
            case .projectLinks:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.linkedProjects().map(ProjectWire.init)))), true)
            case .projectList:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.projectsList().map(ProjectWire.init)))), true)
            case .projectStatus, .projectInspect, .projectDoctor:
                let params = try request.params?.decode(ProjectEnvironmentRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project environment parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                let report = try await projectEnvironmentReport(for: project)
                return (.init(id: request.id, result: .projectEnvironment(.init(report: report))), true)
            case .projectPlan, .projectActivate:
                let params = try request.params?.decode(ProjectEnvironmentRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project reconciliation parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                guard project.registrationKind == .linked, project.id != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "Project reconciliation requires a registered linked project.") }
                if method == .projectPlan {
                    let report = try await projectEnvironmentReport(for: project)
                    return (.init(id: request.id, result: .projectPlan(.init(plan: ProjectReconciliationPlanner().plan(report: report)))), true)
                }
                return (.init(id: request.id, result: .projectActivation(.init(execution: try await activate(project: project)))), true)
            case .pathPark:
                let params = try request.params?.decode(ParkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Park parameters are required.") }()
                let path = try await registry.parkWithCreation(path: params.path, workingDirectory: params.workingDirectory)
                logger.info("Path parked: \(path.path.rootPath.string, privacy: .public)")
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: .init(path.path), created: path.created))), true)
            case .pathUnpark:
                let params = try request.params?.decode(UnparkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unpark parameters are required.") }()
                try await registry.unpark(path: params.path, workingDirectory: params.workingDirectory)
                logger.info("Path unparked")
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: nil, created: false))), true)
            case .pathList:
                return (.init(id: request.id, result: .parkedPathList(.init(paths: try await registry.parkedPaths().map(ParkedPathWire.init)))), true)
            case .phpVersions:
                let module = try phpModule(); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpInstall:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpUse:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); _ = try module.setDefault(requestedVersion: params.version); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpExec:
                let module = try phpModule(); let params = try request.params?.decode(PHPExecRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP execution parameters are required.") }(); let result = try module.exec(requestedVersion: params.version, workingDirectory: params.workingDirectory, arguments: params.arguments); return (.init(id: request.id, result: .phpExec(.init(exitStatus: result.status, output: result.output))), true)
            case .phpStart:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.start(requestedVersion: params.version)))), true)
            case .phpStop:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.stop(requestedVersion: params.version)))), true)
            case .phpStatus:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.status(requestedVersion: params.version)))), true)
            case .mysqlVersions:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlInstall:
                let module = try mysqlModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "MySQL version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlUse:
                let module = try mysqlModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "MySQL version is required.") }(); _ = try module.use(params.version); return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlInitialize:
                let module = try mysqlModule(); try module.initialize(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: module.status()))), true)
            case .mysqlStart:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: try module.start()))), true)
            case .mysqlStop:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: try module.stop()))), true)
            case .mysqlStatus:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: module.status()))), true)
            case .mailpitVersions:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitVersions(.init(mailpit: .init(available: module.availableVersions(), installed: module.installedVersions().map(MailpitPackageWire.init))))), true)
            case .mailpitInstall:
                let module = try mailpitModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Mailpit version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .mailpitVersions(.init(mailpit: .init(available: module.availableVersions(), installed: module.installedVersions().map(MailpitPackageWire.init))))), true)
            case .mailpitStart:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: try module.start()))), true)
            case .mailpitStop:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: try module.stop()))), true)
            case .mailpitStatus:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: module.status()))), true)
            case .routingStatus:
                return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStart:
                try await router.start(); try await router.reconcile(routes: routeIntents.values.map(\.route)); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStop:
                try await router.stop(); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routeList:
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
            case .routeAdd:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let intent = try request.params?.decode(RouteIntent.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route parameters are required.") }()
                let validated = try intent.route.validated()
                var projectPath = intent.projectPath
                if let projectID = intent.projectID {
                    guard let project = try await registry.linkedProject(id: ProjectID(rawValue: projectID)) else { throw IPCErrorPayload(code: .invalidRequest, message: "Route project identity is not a registered M1 project.") }
                    projectPath = projectPath ?? project.rootPath.string
                }
                let normalized = RouteIntent(route: validated, projectID: intent.projectID, projectPath: projectPath)
                try repository.upsert(normalized); routeIntents[validated.id] = normalized
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeMutation(normalized)), true)
            case .routeRemove:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let params = try request.params?.decode(RouteRemoveRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route ID is required.") }()
                guard routeIntents[params.id] != nil else { throw RouterError.routeNotFound(params.id) }
                try repository.remove(id: params.id); routeIntents.removeValue(forKey: params.id)
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
            case .routeProjectAssociationAttach:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let params = try request.params?.decode(RouteProjectAssociationRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route association parameters are required.") }()
                guard let intent = routeIntents[params.routeID] else { throw IPCErrorPayload(code: .invalidRequest, message: "The requested route does not exist.") }
                guard let project = try await registry.linkedProject(id: params.projectID) else { throw IPCErrorPayload(code: .invalidRequest, message: "Route association requires a registered linked project.") }
                if intent.projectID == params.projectID.rawValue {
                    return (.init(id: request.id, result: .routeAssociation(.init(route: intent, state: .satisfied))), true)
                }
                guard intent.projectID == nil else { throw IPCErrorPayload(code: .invalidRequest, message: "The route is already associated with another project.") }
                let report = try await projectEnvironmentReport(for: project)
                guard report.observed.route.associationState == .safelyAssociable else {
                    throw IPCErrorPayload(code: .invalidRequest, message: report.observed.route.mutationAuthorityReason)
                }
                guard report.observed.route.hostname == intent.route.hostname || report.observed.route.hostname == nil else {
                    throw IPCErrorPayload(code: .invalidRequest, message: "The requested route is not the route identified by the current project evidence.")
                }
                let path = project.rootPath.string
                try repository.associateMetadata(id: params.routeID, projectID: params.projectID.rawValue, projectPath: path)
                let associated = RouteIntent(route: intent.route, projectID: params.projectID.rawValue, projectPath: path)
                routeIntents[params.routeID] = associated
                return (.init(id: request.id, result: .routeAssociation(.init(route: associated, state: .associated))), true)
            case .routePHPTargetUpdate:
                let params = try request.params?.decode(RoutePHPTargetUpdateRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route target update parameters are required.") }()
                let result = try await updatePHPTarget(projectID: params.projectID, routeID: params.routeID, expectedCurrentSocket: params.expectedCurrentSocket)
                return (.init(id: request.id, result: .routePHPTargetUpdate(result)), true)
            case .dnsStatus:
                return (.init(id: request.id, result: .dnsStatus(.init(dns: await dns.status()))), true)
            case .dnsInstall:
                let params = try request.params?.decode(DNSInstallRequest.self) ?? .init()
                return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.install(takeover: params.takeover)))), true)
            case .dnsRemove:
                return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.remove()))), true)
            case .tlsStatus:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: await tls.status()))), true)
            case .tlsInstall:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.install()))), true)
            case .tlsRemove:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.remove()))), true)
            case .tlsTrustLocalCA:
                return (.init(id: request.id, result: .tlsTrust(.init(result: try await tls.trustLocalCA()))), true)
            case .tlsRemoveLocalCATrust:
                return (.init(id: request.id, result: .tlsTrust(.init(result: try await tls.removeLocalCATrust()))), true)
            case .portsStatus:
                return (.init(id: request.id, result: .portsStatus(.init(ports: await ports.status()))), true)
            case .portsInstall:
                return (.init(id: request.id, result: .portsStatus(.init(ports: try await ports.install()))), true)
            case .portsRemove:
                return (.init(id: request.id, result: .portsStatus(.init(ports: try await ports.remove()))), true)
            case .handshake:
                fatalError("handled above")
            }
        } catch let error as PHPModuleError {
            switch error {
            case .invalidWorkingDirectory(let path): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "PHP working directory is unavailable: \(path)")), true)
            default: return (.init(id: request.id, error: .init(code: .internalError, message: "PHP operation failed: \(error)")), true)
            }
        } catch let error as MySQLModuleError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as MailpitModuleError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as ProjectRegistryError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as IPCErrorPayload {
            return (.init(id: request.id, error: error), true)
        } catch let error as StandardPortsError {
            switch error {
            case .helperUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Local Ports require approval in Vaelen.app.")), true)
            case .authorizationRequired(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports authorization failed: \(detail)")), true)
            case .externalConflict(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports conflict: \(detail)")), true)
            case .ownershipMismatch: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports ownership mismatch: external state changed.")), true)
            case .backendUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports require the backend router to be running.")), true)
            case .unavailable(let detail): return (.init(id: request.id, error: .init(code: .internalError, message: "Standard Ports are unavailable: \(detail)")), true)
            }
        } catch let error as TLSError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as BootstrapError {
            switch error {
            case .refused, .coreReachable:
                return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Bootstrap promotion refused: \(error)")), true)
            case .recoveryRequired:
                return (.init(id: request.id, error: .init(code: .lifecycleUnknown, message: "Bootstrap recovery is required; no platform operation was attempted.")), true)
            case .invalidReceipt:
                return (.init(id: request.id, error: .init(code: .lifecycleUnknown, message: "Bootstrap receipt is orphaned or invalid; recovery is required.")), true)
            case .platformAmbiguous:
                return (.init(id: request.id, error: .init(code: .internalError, message: "Bootstrap state is ambiguous; recovery is required.")), true)
            }
        } catch {
            logger.error("Registry operation failed: \(String(describing: error), privacy: .public)")
            return (.init(id: request.id, error: .init(code: .internalError, message: "Core operation failed: \(error)")), true)
        }
    }

    private func boundedLifecycleExecution(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        let latch = LifecycleExecutionLatch()
        return await withCheckedContinuation { continuation in
            latch.install(continuation)
            Task { latch.resolve(await self.lifecycleExecutor.execute(request)) }
            Task {
                try? await Task.sleep(nanoseconds: self.lifecycleTimeoutNanoseconds)
                latch.resolve(.init(state: .timeout, detail: "Lifecycle executor exceeded its bounded deadline."))
            }
        }
    }

    private func lifecycleSuccessGate(intent: LifecycleIntent, observation: LifecycleObservationVector) -> Bool {
        guard observation.source != "core", observation.source != "synthetic" else { return false }
        switch intent {
        case .on:
            // Registration success is confirmed by registration plus the
            // immutable bundle/layout evidence. Readiness is a separate
            // contract and may legitimately remain unknown after register.
            return observation.bundlePresent == .true && observation.layoutValid == .true &&
                observation.signatureValid == .true && observation.registrationMatch == .true
        case .off:
            return observation.registrationMatch == .false && observation.processMatch == .false &&
                observation.endpointReachable == .false
        }
    }

    public func reconcilePersistedRoutesOnStartup() async throws {
        // Pre-existing M0-M13 startup route reconciliation is intentionally
        // unchanged. It is outside M14 lifecycle authority and must not be
        // repurposed as lifecycle recovery or registration work.
        guard (await router.status()).state == .running else { return }
        try await router.reconcile(routes: routeIntents.values.map(\.route))
    }

    private func phpModule() throws -> PHPModule { guard let php else { throw IPCErrorPayload(code: .internalError, message: "PHP distribution manifest is not configured.") }; return php }
    private func mysqlModule() throws -> MySQLModule { guard let mysql else { throw IPCErrorPayload(code: .internalError, message: "MySQL module is not configured.") }; return mysql }
    private func mailpitModule() throws -> MailpitModule { guard let mailpit else { throw IPCErrorPayload(code: .internalError, message: "Mailpit module is not configured.") }; return mailpit }

    private func resolveProject(selector: String?, workingDirectory: String) async throws -> Project {
        let projects = try await registry.projectsList()
        let pathService = CanonicalPathService()
        guard let selector, !selector.isEmpty else {
            let current = pathService.canonicalize(workingDirectory).string
            guard let project = projects.first(where: { $0.rootPath.string == current }) else { throw ProjectRegistryError.projectNotFound }
            return project
        }
        if let uuid = UUID(uuidString: selector), let project = projects.first(where: { $0.id?.rawValue == uuid }) { return project }
        if selector.hasPrefix("/") || selector.hasPrefix("~") || selector.contains("/") {
            let path = pathService.canonicalize(selector, relativeTo: workingDirectory).string
            guard let project = projects.first(where: { $0.rootPath.string == path }) else { throw ProjectRegistryError.projectNotFound }
            return project
        }
        let matches = projects.filter { $0.name == selector || $0.id?.description == selector }
        guard matches.count == 1, let project = matches.first else {
            if matches.count > 1 { throw ProjectRegistryError.projectNameAmbiguous }
            throw ProjectRegistryError.projectNotFound
        }
        return project
    }

    private func projectEnvironmentReport(for project: Project) async throws -> ProjectEnvironmentReport {
        let phpObservations = php?.packageObservations() ?? []
        let phpPackages = phpObservations.filter { $0.eligibility == .eligible }.compactMap(\.package)
        let invalidPHPVersions = phpObservations.filter { $0.eligibility != .eligible }.compactMap(\.version)
        let phpStatuses = phpPackages.compactMap { try? php?.status(requestedVersion: $0.version) }.compactMap { $0 }
        let routerStatus = await router.status()
        let runtimeRoutes = try? await router.observedRoutes()
        let linkedProjects = try await registry.linkedProjects()
        let pendingTransitions = try routeRepository?.pendingTransitions() ?? []
        let report = ProjectEnvironmentInspector().inspect(
            project: project,
            routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname },
            phpPackages: phpPackages,
            phpStatuses: phpStatuses,
            phpDefault: php?.defaultVersion(),
            mysql: mysql?.status(),
            mailpit: mailpit?.status(),
            router: routerStatus,
            dns: await dns.status(),
            tls: await tls.status(),
            standardPorts: await ports.status(),
            invalidPHPVersions: invalidPHPVersions,
            registeredProjects: linkedProjects, runtimeRoutes: runtimeRoutes, pendingTransitions: pendingTransitions
        )
        if let routeRepository, let projectID = project.id?.rawValue, runtimeRoutes != nil, routerStatus.state == .running, routerStatus.health == .healthy, report.observed.php.fpmHealth == "healthy", let resolvedVersion = report.observed.php.resolvedVersion, let desiredSocket = report.observed.php.fpmSocket {
            for transition in pendingTransitions where transition.projectID == projectID && transition.desiredSocket == desiredSocket && transition.desiredRoute.target.fastCGISocket == desiredSocket {
                guard linkedProjects.contains(where: { $0.id?.rawValue == projectID }), let target = report.routeTargets.first(where: { $0.routeID == transition.routeID }), target.disposition == .satisfied, target.resolvedPHPVersion == resolvedVersion, let runtime = runtimeRoutes?.first(where: { $0.hostname == transition.desiredRoute.hostname }), (try? routeProviderFingerprint(runtime)) == transition.desiredProviderFingerprint else { continue }
                try routeRepository.completeFastCGITargetTransition(id: transition.routeID, projectID: projectID, desiredRoute: transition.desiredRoute)
            }
        }
        return report
    }

    private func activate(project: Project) async throws -> ProjectReconciliationExecutionResult {
        let planner = ProjectReconciliationPlanner()
        let initialReport = try await projectEnvironmentReport(for: project)
        let initialPlan = planner.plan(report: initialReport)
        let freshReport = try await projectEnvironmentReport(for: project)
        let freshPlan = planner.plan(report: freshReport)
        var results = [ProjectReconciliationOperationResult]()
        var startedMailpit = false
        var startedPHP = false

        for operation in initialPlan.operations {
            guard operation.disposition != .satisfied else {
                results.append(.init(operationID: operation.id, state: .satisfied, message: "Already satisfied; no mutation performed.", verified: true))
                continue
            }
            guard operation.disposition == .actionable || operation.disposition == .pending else {
                results.append(.init(operationID: operation.id, state: .blocked, message: operation.reason ?? "Operation is not executable in M8 Slice 1.", verified: false))
                continue
            }
            guard let current = freshPlan.operations.first(where: { $0.id == operation.id }), current.disposition == .actionable || current.disposition == .pending else {
                results.append(.init(operationID: operation.id, state: .skipped, message: "The plan became stale before execution; no mutation performed.", verified: false))
                continue
            }
            switch operation.id {
            case "mailpit.start":
                guard let mailpit else {
                    results.append(.init(operationID: operation.id, state: .failed, message: "Mailpit module is unavailable.", verified: false)); continue
                }
                do {
                    _ = try mailpit.start()
                    startedMailpit = true
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "Mailpit start requested; final health verification follows.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "Mailpit start failed; actual state was re-observed.", verified: false))
                }
            case "php.fpm.start":
                guard let php, let version = freshReport.observed.php.resolvedVersion else {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The desired PHP runtime is unavailable at execution time.", verified: false)); continue
                }
                do {
                    _ = try php.start(requestedVersion: version)
                    startedPHP = true
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "PHP-FPM start requested; final socket and readiness verification follows.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "PHP-FPM start failed; actual state was re-observed.", verified: false))
                }
            case let id where id.hasPrefix("route.php-target.update."):
                continue
            default:
                results.append(.init(operationID: operation.id, state: .skipped, message: "This operation is not executable in M9.", verified: false))
            }
        }

        var finalPlan = planner.plan(report: try await projectEnvironmentReport(for: project))
        if startedMailpit, let resultIndex = results.firstIndex(where: { $0.operationID == "mailpit.start" }) {
            let healthy = finalPlan.operations.first(where: { $0.id == "mailpit.start" })?.disposition == .satisfied
            results[resultIndex] = .init(operationID: "mailpit.start", state: healthy ? .succeeded : .failed, message: healthy ? "Mailpit is healthy after activation." : "Mailpit did not verify healthy after activation.", verified: healthy)
        }
        if startedPHP, let resultIndex = results.firstIndex(where: { $0.operationID == "php.fpm.start" }) {
            let healthy = finalPlan.operations.first(where: { $0.id == "php.fpm.start" })?.disposition == .satisfied
            results[resultIndex] = .init(operationID: "php.fpm.start", state: healthy ? .succeeded : .failed, message: healthy ? "PHP-FPM is healthy after activation." : "PHP-FPM did not verify healthy after activation.", verified: healthy)
        }
        for operation in finalPlan.operations where operation.id.hasPrefix("route.php-target.update.") && (operation.disposition == .actionable || operation.disposition == .pending) {
            guard let routeID = UUID(uuidString: String(operation.id.dropFirst("route.php-target.update.".count))), let projectID = project.id else { continue }
            guard let observation = (try await projectEnvironmentReport(for: project)).routeTargets.first(where: { $0.routeID == RouteID(rawValue: routeID) }) else { continue }
            do {
                let result = try await updatePHPTarget(projectID: projectID, routeID: RouteID(rawValue: routeID), expectedCurrentSocket: observation.persistedSocket)
                let state: ProjectReconciliationOperationResultState = result.state == .pending ? .pending : result.state == .satisfied ? .satisfied : .succeeded
                results.append(.init(operationID: operation.id, state: state, message: result.state == .pending ? "Desired route target is persisted; Caddy provider application is pending." : result.state == .satisfied ? "Route target already satisfied; no mutation performed." : "FastCGI route target converged.", verified: result.state != .pending))
            } catch {
                results.append(.init(operationID: operation.id, state: .failed, message: "Route target convergence failed: \(error)", verified: false))
            }
        }
        finalPlan = planner.plan(report: try await projectEnvironmentReport(for: project))
        let state: ProjectReconciliationExecutionState
        if finalPlan.state == .satisfied && results.allSatisfy({ $0.state == .satisfied || $0.state == .succeeded }) {
            state = .succeeded
        } else if results.contains(where: { $0.state == .succeeded }) {
            state = .partial
        } else if results.contains(where: { $0.state == .failed }) {
            state = .failed
        } else {
            state = .blocked
        }
        return .init(initialPlan: initialPlan, operations: results, finalPlan: finalPlan, state: state)
    }

    private func updatePHPTarget(projectID: ProjectID, routeID: RouteID, expectedCurrentSocket: String) async throws -> RoutePHPTargetUpdateResult {
        guard let repository = routeRepository, let project = try await registry.linkedProject(id: projectID), project.registrationKind == .linked else { throw IPCErrorPayload(code: .invalidRequest, message: "Route target convergence requires a linked project.") }
        let report = try await projectEnvironmentReport(for: project)
        guard let observation = report.routeTargets.first(where: { $0.routeID == routeID }) else { throw IPCErrorPayload(code: .invalidRequest, message: "The route is not an eligible durable FastCGI route for this project.") }
        guard observation.persistedSocket == expectedCurrentSocket else { throw IPCErrorPayload(code: .invalidRequest, message: "The route target plan is stale; the persisted socket changed.") }
        if observation.disposition == .satisfied {
            return .init(observation: observation, state: .satisfied)
        }
        guard observation.disposition == .actionable || observation.disposition == .pending, let desiredSocket = observation.desiredSocket else { throw IPCErrorPayload(code: .invalidRequest, message: observation.reason ?? "Route target convergence is blocked.") }
        let currentIntent = routeIntents[routeID]
        guard currentIntent != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "The route disappeared before target convergence.") }
        if currentIntent?.route.target.fastCGISocket != desiredSocket {
            guard observation.disposition == .actionable else { throw IPCErrorPayload(code: .invalidRequest, message: "The pending transition is not valid for the current route state.") }
            let updated = try repository.persistFastCGITargetTransition(id: routeID, projectID: projectID.rawValue, expectedSocket: observation.persistedSocket, desiredSocket: desiredSocket).intent
            routeIntents[routeID] = updated
        }
        do {
            guard (await router.status()).state == .running, (await router.status()).health == .healthy else { throw RouterError.notRunning }
            try await router.reconcile(routes: routeIntents.values.map(\.route))
            let verifiedReport = try await projectEnvironmentReport(for: project)
            guard let verified = verifiedReport.routeTargets.first(where: { $0.routeID == routeID }), verified.disposition == .satisfied else {
                return .init(observation: verifiedReport.routeTargets.first(where: { $0.routeID == routeID }) ?? observation, state: .pending)
            }
            return .init(observation: verified, state: .updated)
        } catch {
            let pendingReport = try await projectEnvironmentReport(for: project)
            let pendingObservation = pendingReport.routeTargets.first(where: { $0.routeID == routeID }) ?? observation
            return .init(observation: pendingObservation, state: .pending)
        }
    }

    private func map(_ error: MySQLModuleError) -> IPCErrorPayload {
        switch error {
        case .unsupportedVersion, .unsupportedArchitecture, .packageMissing, .notInitialized, .alreadyInitialized, .partialInitialization, .instanceVersionMismatch, .credentialsUnavailable:
            return .init(code: .invalidRequest, message: "MySQL operation rejected: \(error)")
        case .portConflict(let port): return .init(code: .invalidRequest, message: "MySQL port conflict on 127.0.0.1:\(port); external processes were not modified.")
        case .processIdentityMismatch: return .init(code: .invalidRequest, message: "MySQL process identity could not be verified; no process was signaled.")
        default: return .init(code: .internalError, message: "MySQL operation failed: \(error)")
        }
    }

    private func map(_ error: MailpitModuleError) -> IPCErrorPayload {
        switch error {
        case .unsupportedVersion, .packageMissing: return .init(code: .invalidRequest, message: "Mailpit operation rejected: \(error)")
        case .portConflict(let port): return .init(code: .invalidRequest, message: "Mailpit port conflict on 127.0.0.1:\(port); external processes were not modified.")
        case .processIdentityMismatch: return .init(code: .invalidRequest, message: "Mailpit process identity could not be verified; no process was signaled.")
        case .unhealthy(let detail): return .init(code: .invalidRequest, message: "Mailpit is unhealthy: \(detail)")
        default: return .init(code: .internalError, message: "Mailpit operation failed: \(error)")
        }
    }

    private func map(_ error: TLSError) -> IPCErrorPayload {
        switch error {
        case .ownershipMismatch: return .init(code: .tlsIdentityMismatch, message: error.localizedDescription)
        case .keyCertificateMismatch: return .init(code: .tlsKeyCertificateMismatch, message: error.localizedDescription)
        case .trustProvenanceUnavailable: return .init(code: .tlsOwnershipUnavailable, message: error.localizedDescription)
        case .trustSettingsMismatch: return .init(code: .tlsRemovalBlocked, message: error.localizedDescription)
        case .trustSettingsUnsupported: return .init(code: .tlsTrustSettingsUnsupported, message: error.localizedDescription)
        case .trustObservationFailed: return .init(code: .tlsObservationFailed, message: error.localizedDescription)
        case .trustRemovalUnverified, .keychain, .certificate, .unavailable, .unsupportedHostname:
            return .init(code: .tlsTrustOperationFailed, message: error.localizedDescription)
        }
    }

    private func map(_ error: ProjectRegistryError) -> IPCErrorPayload {
        switch error {
        case .pathUnavailable(.notDirectory): return .init(code: .pathNotDirectory, message: "The path is not a directory.")
        case .pathUnavailable(.missing): return .init(code: .pathNotFound, message: "The path does not exist.")
        case .pathUnavailable(.unreadable): return .init(code: .pathUnreadable, message: "The path is not readable.")
        case .pathUnavailable: return .init(code: .pathNotFound, message: "The path is unavailable.")
        case .projectNotFound: return .init(code: .projectNotFound, message: "Project registration was not found.")
        case .projectNameAmbiguous: return .init(code: .projectNameAmbiguous, message: "Project name is ambiguous.")
        case .projectNameConflict: return .init(code: .projectNameConflict, message: "Project name is already in use.")
        case .invalidName: return .init(code: .invalidRequest, message: "Project name is invalid.")
        case .parkedPathNotFound: return .init(code: .parkedPathNotFound, message: "Parked path was not found.")
        }
    }
}

private final class LifecycleExecutionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LifecycleExecutorResult, Never>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<LifecycleExecutorResult, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resolve(_ result: LifecycleExecutorResult) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
