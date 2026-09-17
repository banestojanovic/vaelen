import Foundation
import OSLog
import VaelenCore
import VaelenIPC

public actor CoreRequestDispatcher {
    private let runtime: CoreRuntime
    private let registry: ProjectRegistry
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "registry")

    public init(runtime: CoreRuntime, registry: ProjectRegistry) {
        self.runtime = runtime
        self.registry = registry
    }

    public func dispatch(_ request: IPCRequest, handshaken: Bool) async -> (response: IPCResponse, handshaken: Bool) {
        guard request.protocolVersion == ProtocolVersion.v1.rawValue else {
            return (.init(id: request.id, error: .init(code: .protocolIncompatible, message: "Client and Core protocol versions are incompatible.", details: ["clientProtocolVersion": "\(request.protocolVersion)", "coreProtocolVersion": "1"])), handshaken)
        }
        guard let method = request.knownMethod else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Unknown Core method: \(request.method).")), handshaken)
        }
        if method == .handshake {
            guard let params = request.params, (try? params.decode(HandshakeParams.self)) != nil else {
                return (.init(id: request.id, error: .init(code: .invalidRequest, message: "A valid handshake payload is required.")), false)
            }
            return (.init(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: runtime.status.version))), true)
        }
        guard handshaken else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Handshake is required before other requests.")), false)
        }
        do {
            switch method {
            case .status:
                return (.init(id: request.id, result: .status(.init(core: runtime.status, protocolVersion: 1))), true)
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
            case .handshake:
                fatalError("handled above")
            }
        } catch let error as ProjectRegistryError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as IPCErrorPayload {
            return (.init(id: request.id, error: error), true)
        } catch {
            logger.error("Registry operation failed: \(String(describing: error), privacy: .public)")
            return (.init(id: request.id, error: .init(code: .internalError, message: "Core operation failed.")), true)
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
