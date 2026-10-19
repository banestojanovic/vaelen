import Foundation
import Darwin

public struct CoreLogEntry: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let service: String
    public let status: Status
    public let sizeBytes: Int64?

    public enum Status: String, Codable, Sendable { case available, empty, missing, unreadable }
    public init(id: String, title: String, service: String, status: Status, sizeBytes: Int64?) {
        self.id = id; self.title = title; self.service = service; self.status = status; self.sizeBytes = sizeBytes
    }
}

public struct CoreLogTail: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let truncated: Bool
    public let linesReturned: Int
    public init(id: String, text: String, truncated: Bool, linesReturned: Int) {
        self.id = id; self.text = text; self.truncated = truncated; self.linesReturned = linesReturned
    }
}

public enum CoreLogError: Error, Equatable, Sendable {
    case unknownLog(String)
    case invalidLineCount
    case missing(String)
    case unreadable(String)
    case unsafePath(String)
}

public struct CoreLogCatalog: Sendable {
    private enum LogID: Hashable {
        case caddy, mysql, mailpit, php(String)

        var rawValue: String {
            switch self {
            case .caddy: "caddy"
            case .mysql: "mysql"
            case .mailpit: "mailpit"
            case .php(let version): "php-\(version)"
            }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "caddy": self = .caddy
            case "mysql": self = .mysql
            case "mailpit": self = .mailpit
            default:
                guard rawValue.hasPrefix("php-") else { return nil }
                let version = String(rawValue.dropFirst(4))
                guard !version.isEmpty, version.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) else { return nil }
                self = .php(version)
            }
        }
    }

    private struct Definition: Sendable {
        let id: LogID
        let title: String
        let service: String
        let url: URL
        let allowedRoot: URL
    }

    public static let maxLines = 10_000
    public static let maxTailBytes = 128 * 1024
    private let layout: VaelenFilesystemLayout
    private let phpVersions: @Sendable () -> [String]
    public init(layout: VaelenFilesystemLayout, phpVersions: [String] = []) {
        self.layout = layout; self.phpVersions = { phpVersions }
    }

    public init(layout: VaelenFilesystemLayout, phpModule: PHPModule?) {
        self.layout = layout
        self.phpVersions = { phpModule?.installedVersions().map(\.version) ?? [] }
    }

    public func list() -> [CoreLogEntry] {
        definitions().values.map { definition in
            guard let data = try? read(definition, lines: 1, listing: true) else {
                var info = stat()
                let status: CoreLogEntry.Status = lstat(definition.url.path, &info) == 0 || (errno != ENOENT && errno != ENOTDIR) ? .unreadable : .missing
                return .init(id: definition.id.rawValue, title: definition.title, service: definition.service, status: status, sizeBytes: nil)
            }
            return .init(id: definition.id.rawValue, title: definition.title, service: definition.service, status: data.size == 0 ? .empty : .available, sizeBytes: data.size)
        }.sorted { $0.id < $1.id }
    }

    public func tail(id: String, lines: Int) throws -> CoreLogTail {
        guard (1...Self.maxLines).contains(lines) else { throw CoreLogError.invalidLineCount }
        guard let logID = LogID(rawValue: id), let definition = definitions()[logID] else { throw CoreLogError.unknownLog(id) }
        let result = try read(definition, lines: lines, listing: false)
        return CoreLogTail(id: id, text: result.text, truncated: result.truncated, linesReturned: result.lineCount)
    }

    private func definitions() -> [LogID: Definition] {
        var registry: [LogID: Definition] = [
            .caddy: Definition(id: .caddy, title: "Caddy", service: "Routing", url: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"), allowedRoot: layout.caddyLogsDirectoryURL),
            .mysql: Definition(id: .mysql, title: "MySQL", service: "MySQL", url: layout.mysqlLogsDirectoryURL.appendingPathComponent("default.log"), allowedRoot: layout.mysqlLogsDirectoryURL),
            .mailpit: Definition(id: .mailpit, title: "Mailpit", service: "Mailpit", url: layout.mailpitLogsDirectoryURL.appendingPathComponent("default.log"), allowedRoot: layout.mailpitLogsDirectoryURL)
        ]
        for version in phpVersions().filter(isSafeVersion) {
            let id = LogID.php(version)
            registry[id] = Definition(id: id, title: "PHP-FPM \(version)", service: "PHP", url: layout.phpLogsDirectoryURL.appendingPathComponent("\(version).log"), allowedRoot: layout.phpLogsDirectoryURL)
        }
        return registry
    }

    private func isSafeVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
    }

    private func read(_ definition: Definition, lines: Int, listing: Bool) throws -> (text: String, truncated: Bool, lineCount: Int, size: Int64) {
        let rootPath = definition.allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let ownedLogsPath = layout.logsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = definition.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard isDescendant(rootPath, of: ownedLogsPath), isDescendant(filePath, of: rootPath) else { throw CoreLogError.unsafePath(definition.id.rawValue) }
        let fd = open(filePath, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw CoreLogError.missing(definition.id.rawValue) }
            throw CoreLogError.unreadable(definition.id.rawValue)
        }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CoreLogError.unreadable(definition.id.rawValue) }
        let size = Int64(info.st_size)
        guard !listing else { return ("", false, 0, size) }
        guard size > 0 else { return ("", false, 0, size) }
        let byteCount = min(size, Int64(Self.maxTailBytes))
        guard lseek(fd, off_t(size - byteCount), SEEK_SET) >= 0 else { throw CoreLogError.unreadable(definition.id.rawValue) }
        var buffer = [UInt8](repeating: 0, count: Int(byteCount))
        let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard readCount >= 0 else { throw CoreLogError.unreadable(definition.id.rawValue) }
        buffer = Array(buffer.prefix(readCount))
        let byteTruncated = size > byteCount || readCount < Int(byteCount)
        if byteTruncated, let firstNewline = buffer.firstIndex(of: 10) { buffer = Array(buffer.dropFirst(firstNewline + 1)) }
        var pieces = buffer.split(separator: 10, omittingEmptySubsequences: false).map { Array($0) }
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        let lineTruncated = pieces.count > lines
        if lineTruncated { pieces = Array(pieces.suffix(lines)) }
        let text = pieces.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        return (text, byteTruncated || lineTruncated, pieces.count, size)
    }

    private func isDescendant(_ path: String, of root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
