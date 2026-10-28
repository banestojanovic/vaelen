import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ConnectionKey: String, CaseIterable, Sendable {
    case driver = "DB_CONNECTION"
    case host = "DB_HOST"
    case port = "DB_PORT"
    case database = "DB_DATABASE"
    case username = "DB_USERNAME"
    case password = "DB_PASSWORD"
}

public enum ConnectionFileError: Error, Equatable {
    case invalidEncoding
    case unsupportedSyntax
    case duplicateKey(ConnectionKey)
    case unsafeFile
    case staleFile
    case unsupportedFilesystem
    case transactionConflict
    case unsupportedOverride(String)
}

public struct ConnectionEdit: Equatable, Sendable {
    public let key: ConnectionKey
    public let added: Bool
    public let displayedValue: String
}

public struct ConnectionPatch: Equatable, Sendable {
    let bytes: Data
    public let edits: [ConnectionEdit]
}

public struct ConnectionConfirmationLedger<Value> {
    private struct Entry { let createdAt: Date; let value: Value }
    private var entries: [UUID: Entry] = [:]
    public init() {}

    public mutating func issue(_ value: Value, now: Date = Date()) -> UUID {
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) < 30 && now >= $0.value.createdAt }
        if entries.count >= 8, let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key { entries.removeValue(forKey: oldest) }
        let id = UUID()
        entries[id] = Entry(createdAt: now, value: value)
        return id
    }

    public mutating func consume(_ id: UUID, now: Date = Date()) throws -> Value {
        guard let entry = entries.removeValue(forKey: id), now.timeIntervalSince(entry.createdAt) >= 0, now.timeIntervalSince(entry.createdAt) < 30 else { throw ConnectionFileError.staleFile }
        return entry.value
    }

    public mutating func consume(_ id: UUID, expected: Value, now: Date = Date()) throws -> Value where Value: Equatable {
        let value = try consume(id, now: now)
        guard value == expected else { throw ConnectionFileError.staleFile }
        return value
    }
}

public struct ConnectionValues {
    let values: [ConnectionKey: String]

    public static func laravelDriver(managedDriver: String) throws -> String {
        switch managedDriver {
        case "mysql": return "mysql"
        case "postgresql": return "pgsql"
        default: throw ConnectionFileError.unsupportedSyntax
        }
    }

    public init(driver: String, host: String, port: String, database: String, username: String, password: String) {
        values = [.driver: driver, .host: host, .port: port, .database: database, .username: username, .password: password]
    }
}

public struct LosslessDotenvDocument {
    private struct Assignment {
        let key: ConnectionKey
        let value: Range<Int>
    }

    private let source: Data
    private let assignments: [ConnectionKey: Assignment]
    private let lineEnding: [UInt8]
    private let hasBOM: Bool

    public static func parse(_ bytes: Data) throws -> Self {
        guard bytes.count <= 1_048_576, !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw ConnectionFileError.invalidEncoding }
        let source = [UInt8](bytes)
        let bom = source.starts(with: [0xef, 0xbb, 0xbf])
        var found: [ConnectionKey: Assignment] = [:]
        var cursor = bom ? 3 : 0
        var endings: [([UInt8], Int)] = []
        while cursor < source.count {
            let start = cursor
            while cursor < source.count && source[cursor] != 10 && source[cursor] != 13 { cursor += 1 }
            let end = cursor
            if cursor < source.count {
                if source[cursor] == 13 && cursor + 1 < source.count && source[cursor + 1] == 10 { endings.append(([13, 10], start)); cursor += 2 }
                else { endings.append(([source[cursor]], start)); cursor += 1 }
            }
            var i = start
            while i < end && (source[i] == 32 || source[i] == 9) { i += 1 }
            if i == end || source[i] == 35 { continue }
            let keyStart = i
            while i < end && ((65...90).contains(source[i]) || (97...122).contains(source[i]) || source[i] == 95 || (48...57).contains(source[i])) { i += 1 }
            let name = String(decoding: source[keyStart..<i], as: UTF8.self)
            guard let first = source[keyStart..<i].first, (65...90).contains(first) || (97...122).contains(first) || first == 95 else { throw ConnectionFileError.unsupportedSyntax }
            let target = ConnectionKey(rawValue: name)
            var equals = i
            while equals < end && (source[equals] == 32 || source[equals] == 9) { equals += 1 }
            if target == nil {
                if name == "export" { throw ConnectionFileError.unsupportedSyntax }
                if name == "DATABASE_URL" { throw ConnectionFileError.unsupportedOverride(name) }
                if name.hasPrefix("DB_") && (equals == end || source[equals] != 61) { throw ConnectionFileError.unsupportedSyntax }
                if name.hasPrefix("DB_") && equals < end && source[equals] == 61 { throw ConnectionFileError.unsupportedOverride(name) }
                guard equals < end, source[equals] == 61 else { throw ConnectionFileError.unsupportedSyntax }
                var valueStart = equals + 1
                while valueStart < end && (source[valueStart] == 32 || source[valueStart] == 9) { valueStart += 1 }
                _ = try Self.valueEnd(source, start: valueStart, end: end)
                continue
            }
            guard equals < end, source[equals] == 61 else { throw ConnectionFileError.unsupportedSyntax }
            var valueStart = equals + 1
            while valueStart < end && (source[valueStart] == 32 || source[valueStart] == 9) { valueStart += 1 }
            let valueEnd = try Self.valueEnd(source, start: valueStart, end: end)
            let assignment = Assignment(key: target!, value: valueStart..<valueEnd)
            guard found[target!] == nil else { throw ConnectionFileError.duplicateKey(target!) }
            found[target!] = assignment
        }
        let ending = endings.first?.0 ?? [10]
        return Self(source: bytes, assignments: found, lineEnding: ending, hasBOM: bom)
    }

    public func patch(_ values: ConnectionValues) throws -> ConnectionPatch {
        guard ConnectionKey.allCases.allSatisfy({ values.values[$0] != nil }) else { throw ConnectionFileError.unsupportedSyntax }
        var bytes = [UInt8](source)
        var edits: [ConnectionEdit] = []
        for key in ConnectionKey.allCases {
            guard let value = values.values[key], !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else { throw ConnectionFileError.unsupportedSyntax }
            if assignments[key] != nil {
                edits.append(ConnectionEdit(key: key, added: false, displayedValue: key == .password ? "managed password (hidden)" : value))
            } else {
                edits.append(ConnectionEdit(key: key, added: true, displayedValue: key == .password ? "managed password (hidden)" : value))
            }
        }
        for assignment in assignments.values.sorted(by: { $0.value.lowerBound > $1.value.lowerBound }) {
            let value = values.values[assignment.key]!
            bytes.replaceSubrange(assignment.value, with: Self.encode(value))
        }
        for key in ConnectionKey.allCases where assignments[key] == nil {
            let value = values.values[key]!
            if !bytes.isEmpty, bytes.last != 10 && bytes.last != 13 { bytes.append(contentsOf: lineEnding) }
            bytes.append(contentsOf: Array("\(key.rawValue)=\(String(decoding: Self.encode(value), as: UTF8.self))".utf8))
            bytes.append(contentsOf: lineEnding)
        }
        return ConnectionPatch(bytes: Data(bytes), edits: edits)
    }

    private static func valueEnd(_ bytes: [UInt8], start: Int, end: Int) throws -> Int {
        guard start < end else { return start }
        let quote = bytes[start] == 34 || bytes[start] == 39 ? bytes[start] : nil
        if let quote {
            var i = start + 1
            var escaped = false
            while i < end {
                if escaped { escaped = false }
                else if bytes[i] == 92 { escaped = true }
                else if bytes[i] == quote {
                    var tail = i + 1
                    while tail < end && (bytes[tail] == 32 || bytes[tail] == 9) { tail += 1 }
                    guard tail == end || bytes[tail] == 35 else { throw ConnectionFileError.unsupportedSyntax }
                    return i + 1
                }
                i += 1
            }
            throw ConnectionFileError.unsupportedSyntax
        }
        var i = start
        while i < end && bytes[i] != 35 { i += 1 }
        while i > start && (bytes[i - 1] == 32 || bytes[i - 1] == 9) { i -= 1 }
        return i
    }

    private static func encode(_ value: String) -> [UInt8] {
        let requiresQuotes = value.isEmpty || value.utf8.contains(where: { byte in
            !((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte))
        })
        guard requiresQuotes else { return Array(value.utf8) }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return Array("'\(escaped)'".utf8)
    }
}

public struct ConnectionFileEvidence: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let owner: UInt32
    public let group: UInt32
    public let mode: UInt16
    public let links: UInt64
    public let flags: UInt32
    public let digest: Data
    public let provenance: Data?
}

public final class ConnectionFileBoundary {
    private var directories: [String: Int32] = [:]
    public init() {}
    deinit { for descriptor in directories.values { close(descriptor) } }

    private func metadataIsSupported(_ descriptor: Int32, directory: Bool = false) throws {
        #if canImport(Darwin)
        let count = flistxattr(descriptor, nil, 0, 0)
        guard count >= 0 else { throw ConnectionFileError.unsafeFile }
        if count > 0 {
            var names = [CChar](repeating: 0, count: count)
            guard flistxattr(descriptor, &names, count, 0) == count else { throw ConnectionFileError.unsafeFile }
            let allowed = directory ? Set(["com.apple.FinderInfo", "com.apple.icon.folder#S", "com.apple.provenance", "com.apple.macl"]) : Set(["com.apple.provenance"])
            let attributes = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            guard attributes.allSatisfy({ allowed.contains($0) }) else { throw ConnectionFileError.unsafeFile }
        }
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw ConnectionFileError.unsafeFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ConnectionFileError.unsafeFile }
        var entry: acl_entry_t?
        var result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        while result == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard directory, let currentEntry = entry, acl_get_tag_type(currentEntry, &tag) == 0, tag == ACL_EXTENDED_DENY else { throw ConnectionFileError.unsafeFile }
            result = acl_get_entry(acl, Int32(ACL_NEXT_ENTRY.rawValue), &entry)
        }
        guard result == -1, errno == EINVAL else { throw ConnectionFileError.unsafeFile }
        #else
        throw ConnectionFileError.unsupportedFilesystem
        #endif
    }

    func directory(_ url: URL) throws -> Int32 {
        let path = url.path
        guard !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw ConnectionFileError.unsafeFile }
        if let target = ["/tmp": "private/tmp", "/var": "private/var", "/etc": "private/etc"][path] {
            let root = try directory(URL(fileURLWithPath: "/", isDirectory: true))
            var linkInfo = stat()
            var targetBytes = [CChar](repeating: 0, count: 64)
            let count = readlinkat(root, url.lastPathComponent, &targetBytes, targetBytes.count)
            guard fstatat(root, url.lastPathComponent, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  (linkInfo.st_mode & S_IFMT) == S_IFLNK, linkInfo.st_uid == 0, count == target.utf8.count,
                  String(decoding: targetBytes.prefix(max(count, 0)).map { UInt8(bitPattern: $0) }, as: UTF8.self) == target else { throw ConnectionFileError.unsafeFile }
            return try directory(URL(fileURLWithPath: "/" + target, isDirectory: true))
        }
        if let descriptor = directories[path] {
            var pinned = stat()
            guard fstat(descriptor, &pinned) == 0 else { throw ConnectionFileError.unsafeFile }
            if path != "/" {
                let parent = try directory(url.deletingLastPathComponent())
                var named = stat()
                guard fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
                      (named.st_mode & S_IFMT) == S_IFDIR,
                      named.st_uid == 0 || named.st_uid == getuid(),
                      (named.st_mode & 0o022) == 0 || (named.st_uid == 0 && (named.st_mode & S_ISVTX) != 0) else { throw ConnectionFileError.unsafeFile }
                try metadataIsSupported(descriptor, directory: true)
            }
            return descriptor
        }
        if path == "/" {
            let descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ConnectionFileError.unsafeFile }
            directories[path] = descriptor
            return descriptor
        }
        let parent = try directory(url.deletingLastPathComponent())
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ConnectionFileError.unsafeFile }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == getuid(),
                  (info.st_mode & 0o022) == 0 || (info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0) else { throw ConnectionFileError.unsafeFile }
            try metadataIsSupported(descriptor, directory: true)
        } catch { close(descriptor); throw error }
        directories[path] = descriptor
        return descriptor
    }

    func createDirectory(_ url: URL) throws {
        let parent = try directory(url.deletingLastPathComponent())
        guard mkdirat(parent, url.lastPathComponent, 0o700) == 0 || errno == EEXIST else { throw ConnectionFileError.unsafeFile }
        let descriptor = try directory(url)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw ConnectionFileError.unsafeFile }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func entries(_ url: URL) throws -> [String] {
        let descriptor = dup(try directory(url))
        guard descriptor >= 0, let stream = fdopendir(descriptor) else { if descriptor >= 0 { close(descriptor) }; throw ConnectionFileError.unsafeFile }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func inspect(_ url: URL) throws -> (Data, ConnectionFileEvidence) {
        let descriptor = openat(try directory(url.deletingLastPathComponent()), url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ConnectionFileError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o777) == 0o600, info.st_flags == 0 else { throw ConnectionFileError.unsafeFile }
        try metadataIsSupported(descriptor)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ConnectionFileError.unsafeFile }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= 1_048_576 else { throw ConnectionFileError.unsafeFile }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_size == info.st_size, final.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec, bytes.count == info.st_size else { throw ConnectionFileError.staleFile }
        let provenanceSize = fgetxattr(descriptor, "com.apple.provenance", nil, 0, 0, 0)
        var provenance: Data?
        if provenanceSize >= 0 {
            guard provenanceSize <= 4096 else { throw ConnectionFileError.unsafeFile }
            var attribute = [UInt8](repeating: 0, count: provenanceSize)
            guard fgetxattr(descriptor, "com.apple.provenance", &attribute, attribute.count, 0, 0) == provenanceSize else { throw ConnectionFileError.unsafeFile }
            provenance = Data(attribute)
        } else if errno != ENOATTR { throw ConnectionFileError.unsafeFile }
        let evidence = ConnectionFileEvidence(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(info.st_size), owner: info.st_uid, group: info.st_gid, mode: UInt16(info.st_mode & 0o777), links: UInt64(info.st_nlink), flags: info.st_flags, digest: Data(SHA256.hash(data: bytes)), provenance: provenance)
        return (bytes, evidence)
    }

    func swap(_ staged: URL, with destination: URL) throws {
        #if canImport(Darwin)
        let result = renameatx_np(try directory(staged.deletingLastPathComponent()), staged.lastPathComponent, try directory(destination.deletingLastPathComponent()), destination.lastPathComponent, UInt32(RENAME_SWAP))
        guard result == 0 else { throw ConnectionFileError.transactionConflict }
        #else
        throw ConnectionFileError.unsupportedFilesystem
        #endif
    }

    func rename(_ source: URL, to destination: URL) throws {
        guard renameat(try directory(source.deletingLastPathComponent()), source.lastPathComponent, try directory(destination.deletingLastPathComponent()), destination.lastPathComponent) == 0 else { throw ConnectionFileError.transactionConflict }
    }

    func renameExclusive(_ source: URL, to destination: URL) throws {
        guard renameatx_np(try directory(source.deletingLastPathComponent()), source.lastPathComponent, try directory(destination.deletingLastPathComponent()), destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw ConnectionFileError.transactionConflict }
    }

    func remove(_ url: URL) throws {
        guard unlinkat(try directory(url.deletingLastPathComponent()), url.lastPathComponent, 0) == 0 else { throw ConnectionFileError.transactionConflict }
    }

    func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if fstatat(try directory(url.deletingLastPathComponent()), url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw ConnectionFileError.unsafeFile }
        return false
    }

    func syncDirectory(_ url: URL) throws {
        guard fsync(try directory(url)) == 0 else { throw ConnectionFileError.unsafeFile }
    }

    func writePrivate(_ bytes: Data, to url: URL, group: UInt32? = nil, preserving evidence: ConnectionFileEvidence? = nil) throws {
        let descriptor = openat(try directory(url.deletingLastPathComponent()), url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ConnectionFileError.unsafeFile }
        defer { close(descriptor) }
        if let group, fchown(descriptor, getuid(), group) != 0 { throw ConnectionFileError.unsafeFile }
        try metadataIsSupported(descriptor)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let amount = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard amount > 0 else { throw ConnectionFileError.unsafeFile }
                offset += amount
            }
        }
        if let evidence {
            if let provenance = evidence.provenance {
                guard provenance.withUnsafeBytes({ fsetxattr(descriptor, "com.apple.provenance", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw ConnectionFileError.unsafeFile }
            } else {
                guard fremovexattr(descriptor, "com.apple.provenance", 0) == 0 || errno == ENOATTR else { throw ConnectionFileError.unsafeFile }
            }
        }
        guard fsync(descriptor) == 0 else { throw ConnectionFileError.unsafeFile }
    }
}

enum ConnectionJournalState: String, Codable, Sendable { case preparing, prepared, swapAttempted, applied, conflict, restorePrepared, restored, needsAttention }

struct ConnectionTransactionJournal: Codable, Sendable {
    let version: Int
    let recoveryID: UUID
    let projectID: UUID
    let destination: String
    let beforeImage: String
    let staged: String
    let reviewedDigest: Data
    let proposedDigest: Data
    let reviewedEvidence: ConnectionFileEvidence
    var proposedEvidence: ConnectionFileEvidence
    var state: ConnectionJournalState
    var restoreStage: String? = nil
    var restorePublishedEvidence: ConnectionFileEvidence? = nil
}

public enum ConnectionTransactionOutcome: Equatable {
    case applied(UUID)
    case conflict(UUID)
    case needsAttention(UUID)
    case restored(UUID)
}

public struct ConnectionRecoverySummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let state: String
    public let restoreAvailable: Bool
    public let discardAvailable: Bool
    public init(id: UUID, state: String, restoreAvailable: Bool, discardAvailable: Bool) { self.id = id; self.state = state; self.restoreAvailable = restoreAvailable; self.discardAvailable = discardAvailable }
}

public struct ConnectionRecoveryEvidence: Codable, Equatable, Sendable {
    public let artifacts: [String: ConnectionFileEvidence]
    public let intent: ConnectionFileEvidence?
}

public struct ConnectionFileTransaction {
    let boundary = ConnectionFileBoundary()

    public init() {}

    public func apply(destination: URL, recoveryDirectory: URL, reviewedBytes: Data, proposed: ConnectionPatch, projectID: UUID) throws -> ConnectionTransactionOutcome {
        try apply(destination: destination, recoveryDirectory: recoveryDirectory, reviewedBytes: reviewedBytes, proposedBytes: proposed.bytes, projectID: projectID)
    }

    public func apply(destination: URL, recoveryDirectory: URL, reviewedBytes: Data, proposedBytes: Data, projectID: UUID, beforeFinalCheck: (() throws -> Void)? = nil, afterFinalCheckBeforeSwap: (() throws -> Void)? = nil, afterSwap: (() throws -> Void)? = nil) throws -> ConnectionTransactionOutcome {
        let (current, evidence) = try boundary.inspect(destination)
        guard current == reviewedBytes else { throw ConnectionFileError.staleFile }
        let recoveryParent = recoveryDirectory.deletingLastPathComponent()
        try boundary.createDirectory(recoveryParent)
        try boundary.createDirectory(recoveryDirectory)
        var directoryInfo = stat()
        guard fstat(try boundary.directory(recoveryDirectory), &directoryInfo) == 0,
              UInt64(directoryInfo.st_dev) == evidence.device else { throw ConnectionFileError.unsupportedFilesystem }
        guard try boundary.entries(recoveryDirectory).isEmpty else { throw ConnectionFileError.transactionConflict }
        let recoveryID = UUID()
        let before = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).before")
        let staged = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).stage")
        let journalURL = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).json")
        var journal = ConnectionTransactionJournal(version: 1, recoveryID: recoveryID, projectID: projectID, destination: destination.path, beforeImage: before.path, staged: staged.path, reviewedDigest: Data(SHA256.hash(data: reviewedBytes)), proposedDigest: Data(SHA256.hash(data: proposedBytes)), reviewedEvidence: evidence, proposedEvidence: evidence, state: .preparing)
        try writeJournal(journal, to: journalURL)
        try boundary.writePrivate(reviewedBytes, to: before, group: evidence.group, preserving: evidence)
        try boundary.writePrivate(proposedBytes, to: staged, group: evidence.group, preserving: evidence)
        journal.proposedEvidence = try boundary.inspect(staged).1
        journal.state = .prepared
        try writeJournal(journal, to: journalURL)
        journal.state = .swapAttempted
        try writeJournal(journal, to: journalURL)
        try syncDirectory(recoveryDirectory)
        try beforeFinalCheck?()
        let (finalBytes, finalEvidence) = try boundary.inspect(destination)
        guard finalEvidence == evidence, finalBytes == reviewedBytes else { throw ConnectionFileError.staleFile }
        try afterFinalCheckBeforeSwap?()
        try boundary.swap(staged, with: destination)
        try afterSwap?()
        let displaced = try? boundary.inspect(staged)
        let live = try? boundary.inspect(destination)
        let displacedBytes = displaced?.0
        let liveBytes = live?.0
        let successfulPublish = liveBytes == proposedBytes && live?.1 == journal.proposedEvidence
        let exactOccupant = displaced?.1 == evidence
        try syncDirectory(recoveryDirectory)
        try syncDirectory(destination.deletingLastPathComponent())
        journal.state = exactOccupant && displacedBytes == reviewedBytes && successfulPublish ? .applied : .conflict
        try writeJournal(journal, to: journalURL)
        guard exactOccupant, displacedBytes == reviewedBytes, successfulPublish else { return .conflict(recoveryID) }
        return .applied(recoveryID)
    }

    func reconcile(destination: URL, journalURL: URL) throws -> ConnectionTransactionOutcome? {
        let journal = try JSONDecoder().decode(ConnectionTransactionJournal.self, from: boundary.inspect(journalURL).0)
        try validate(journal, journalURL: journalURL, destination: destination)
        let (before, _) = try boundary.inspect(URL(fileURLWithPath: journal.beforeImage))
        let (live, liveEvidence) = try boundary.inspect(destination)
        let beforeDigest = Data(SHA256.hash(data: before))
        guard beforeDigest == journal.reviewedDigest else { throw ConnectionFileError.transactionConflict }
        let liveDigest = Data(SHA256.hash(data: live))
        if let restorePath = journal.restoreStage,
           let (restoreBytes, restoreEvidence) = try? boundary.inspect(URL(fileURLWithPath: restorePath)),
           liveEvidence == journal.restorePublishedEvidence,
           Data(SHA256.hash(data: live)) == journal.reviewedDigest,
           restoreEvidence == journal.proposedEvidence,
           Data(SHA256.hash(data: restoreBytes)) == journal.proposedDigest { try syncDirectory(journalURL.deletingLastPathComponent()); try syncDirectory(destination.deletingLastPathComponent()); return .restored(journal.recoveryID) }
        if journal.state == .restored && liveEvidence == journal.restorePublishedEvidence && liveDigest == journal.reviewedDigest { try syncDirectory(journalURL.deletingLastPathComponent()); try syncDirectory(destination.deletingLastPathComponent()); return .restored(journal.recoveryID) }
        if let (staged, stagedEvidence) = try? boundary.inspect(URL(fileURLWithPath: journal.staged)) {
            let stageDigest = Data(SHA256.hash(data: staged))
            if liveEvidence == journal.proposedEvidence && stageDigest == journal.reviewedDigest && stagedEvidence == journal.reviewedEvidence && beforeDigest == journal.reviewedDigest { try syncDirectory(journalURL.deletingLastPathComponent()); try syncDirectory(destination.deletingLastPathComponent()); return .applied(journal.recoveryID) }
            if liveEvidence == journal.reviewedEvidence && stageDigest == journal.proposedDigest && stagedEvidence == journal.proposedEvidence && beforeDigest == journal.reviewedDigest { return nil }
            if liveEvidence == journal.proposedEvidence && beforeDigest == journal.reviewedDigest { return .conflict(journal.recoveryID) }
        }
        throw ConnectionFileError.transactionConflict
    }

    public func hasOutstandingRecovery(recoveryDirectory: URL) throws -> Bool {
        guard try boundary.exists(recoveryDirectory.deletingLastPathComponent()), try boundary.exists(recoveryDirectory) else { return false }
        return !(try boundary.entries(recoveryDirectory)).isEmpty
    }

    public func recoveryStatus(destination: URL, recoveryDirectory: URL) throws -> [ConnectionRecoverySummary] {
        let parent = recoveryDirectory.deletingLastPathComponent()
        guard try boundary.exists(parent) else { return [] }
        guard try boundary.exists(recoveryDirectory) else { return [] }
        var recoveryInfo = stat()
        guard fstat(try boundary.directory(recoveryDirectory), &recoveryInfo) == 0, recoveryInfo.st_uid == getuid(),
              (recoveryInfo.st_mode & 0o777) == 0o700, recoveryInfo.st_flags == 0 else { throw ConnectionFileError.unsafeFile }
        let names = try boundary.entries(recoveryDirectory)
        let identifiers = Set(names.compactMap { UUID(uuidString: String($0.prefix(36))) })
        return identifiers.map { id -> ConnectionRecoverySummary in
            let url = recoveryDirectory.appendingPathComponent("\(id.uuidString).json")
            let captured = try? recoveryEvidence(destination: destination, recoveryDirectory: recoveryDirectory, recoveryID: id)
            if names.contains("\(id.uuidString).discard") || names.contains("\(id.uuidString).discard.tmp") {
                return ConnectionRecoverySummary(id: id, state: captured == nil ? "needsAttention" : "discarding", restoreAvailable: false, discardAvailable: captured != nil)
            }
            if !names.contains(url.lastPathComponent) {
                return ConnectionRecoverySummary(id: id, state: "interruptedPreparation", restoreAvailable: false, discardAvailable: captured != nil)
            }
            guard let journalBytes = try? boundary.inspect(url).0, let journal = try? JSONDecoder().decode(ConnectionTransactionJournal.self, from: journalBytes), journal.recoveryID == id,
                  (try? validate(journal, journalURL: url, destination: destination)) != nil else {
                return ConnectionRecoverySummary(id: id, state: "needsAttention", restoreAvailable: false, discardAvailable: captured != nil)
            }
            let state: String
            do {
                switch try reconcile(destination: destination, journalURL: url) {
                case .applied: state = "applied"
                case .conflict: state = "conflict"
                case .restored: state = "restored"
                case .needsAttention: state = "needsAttention"
                case nil: state = journal.state == .restored ? "restored" : "prepared"
                }
            } catch {
                state = journal.state == .preparing ? "interruptedPreparation" : "needsAttention"
            }
            return ConnectionRecoverySummary(id: journal.recoveryID, state: state, restoreAvailable: state == "applied", discardAvailable: captured != nil)
        }
    }

    public func restore(destination: URL, recoveryDirectory: URL, recoveryID: UUID, afterSwap: (() throws -> Void)? = nil) throws -> ConnectionTransactionOutcome {
        let journalURL = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).json")
        var journal = try JSONDecoder().decode(ConnectionTransactionJournal.self, from: boundary.inspect(journalURL).0)
        try validate(journal, journalURL: journalURL, destination: destination)
        let (beforeBytes, _) = try boundary.inspect(URL(fileURLWithPath: journal.beforeImage))
        guard Data(SHA256.hash(data: beforeBytes)) == journal.reviewedDigest else { throw ConnectionFileError.transactionConflict }
        let (liveBytes, evidence) = try boundary.inspect(destination)
        guard evidence == journal.proposedEvidence, Data(SHA256.hash(data: liveBytes)) == journal.proposedDigest else { throw ConnectionFileError.staleFile }
        let restoreStage = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).restore-\(UUID().uuidString)")
        try boundary.writePrivate(beforeBytes, to: restoreStage, group: journal.proposedEvidence.group, preserving: journal.reviewedEvidence)
        let (_, restorePublishedEvidence) = try boundary.inspect(restoreStage)
        let (finalBytes, finalEvidence) = try boundary.inspect(destination)
        guard finalBytes == liveBytes, finalEvidence == evidence else { throw ConnectionFileError.staleFile }
        journal.restoreStage = restoreStage.path
        journal.restorePublishedEvidence = restorePublishedEvidence
        journal.state = .restorePrepared
        try writeJournal(journal, to: journalURL)
        try syncDirectory(recoveryDirectory)
        try boundary.swap(restoreStage, with: destination)
        try afterSwap?()
        let displaced = try? boundary.inspect(restoreStage)
        let live = try? boundary.inspect(destination)
        try syncDirectory(recoveryDirectory)
        try syncDirectory(destination.deletingLastPathComponent())
        journal.state = displaced?.1 == journal.proposedEvidence && displaced.map { Data(SHA256.hash(data: $0.0)) == journal.proposedDigest } == true && live?.1 == restorePublishedEvidence && live?.0 == beforeBytes ? .restored : .conflict
        try writeJournal(journal, to: journalURL)
        try syncDirectory(recoveryDirectory)
        return journal.state == .restored ? .restored(recoveryID) : .conflict(recoveryID)
    }

    public func recoveryEvidence(destination: URL, recoveryDirectory: URL, recoveryID: UUID) throws -> ConnectionRecoveryEvidence {
        _ = try boundary.inspect(destination)
        let prefix = recoveryID.uuidString
        let names = try boundary.entries(recoveryDirectory).filter { $0.hasPrefix(prefix) }
        let intentURL = recoveryDirectory.appendingPathComponent("\(prefix).discard")
        let temporaryIntent = intentURL.appendingPathExtension("tmp")
        let intentPath = try boundary.exists(intentURL) ? intentURL : temporaryIntent
        if try boundary.exists(intentPath) {
            let intent = try JSONDecoder().decode(ConnectionRecoveryEvidence.self, from: boundary.inspect(intentPath).0)
            guard intent.intent == nil, !intent.artifacts.isEmpty, intent.artifacts.keys.allSatisfy({ name in
                let suffix = String(name.dropFirst(prefix.count))
                return name.hasPrefix(prefix) && ([".before", ".stage", ".json", ".json.tmp"].contains(suffix) || (suffix.hasPrefix(".restore-") && UUID(uuidString: String(suffix.dropFirst(9))) != nil))
            }) else { throw ConnectionFileError.transactionConflict }
            var seen = Set<String>()
            for name in names where name != intentPath.lastPathComponent {
                let original = name.hasSuffix(".discard-capture") ? String(name.dropLast(".discard-capture".count)) : name
                guard seen.insert(original).inserted, let expected = intent.artifacts[original],
                      try boundary.inspect(recoveryDirectory.appendingPathComponent(name)).1 == expected else { throw ConnectionFileError.staleFile }
            }
            return ConnectionRecoveryEvidence(artifacts: intent.artifacts, intent: try boundary.inspect(intentPath).1)
        }
        var artifacts: [String: ConnectionFileEvidence] = [:]
        for name in names {
            let suffix = String(name.dropFirst(prefix.count))
            guard [".before", ".stage", ".json", ".json.tmp"].contains(suffix) || (suffix.hasPrefix(".restore-") && UUID(uuidString: String(suffix.dropFirst(9))) != nil) else { throw ConnectionFileError.transactionConflict }
            let url = recoveryDirectory.appendingPathComponent(name)
            let (bytes, evidence) = try boundary.inspect(url)
            if suffix == ".json" || suffix == ".json.tmp" {
                let journal = try JSONDecoder().decode(ConnectionTransactionJournal.self, from: bytes)
                try validate(journal, journalURL: recoveryDirectory.appendingPathComponent("\(prefix).json"), destination: destination)
                guard journal.recoveryID == recoveryID else { throw ConnectionFileError.transactionConflict }
            }
            artifacts[name] = evidence
        }
        guard !artifacts.isEmpty else { throw ConnectionFileError.transactionConflict }
        return ConnectionRecoveryEvidence(artifacts: artifacts, intent: nil)
    }

    public func discard(destination: URL, recoveryDirectory: URL, recoveryID: UUID, expectedEvidence: ConnectionRecoveryEvidence? = nil, afterRemoval: (() throws -> Void)? = nil, afterCapture: ((URL) throws -> Void)? = nil) throws {
        let snapshot = try recoveryEvidence(destination: destination, recoveryDirectory: recoveryDirectory, recoveryID: recoveryID)
        guard expectedEvidence == nil || expectedEvidence == snapshot else { throw ConnectionFileError.staleFile }
        let intentURL = recoveryDirectory.appendingPathComponent("\(recoveryID.uuidString).discard")
        if !(try boundary.exists(intentURL)) {
            let temporary = intentURL.appendingPathExtension("tmp")
            if !(try boundary.exists(temporary)) { try boundary.writePrivate(JSONEncoder().encode(snapshot), to: temporary) }
            guard try JSONDecoder().decode(ConnectionRecoveryEvidence.self, from: boundary.inspect(temporary).0).artifacts == snapshot.artifacts else { throw ConnectionFileError.staleFile }
            try boundary.renameExclusive(temporary, to: intentURL)
            try syncDirectory(recoveryDirectory)
        }
        let intentEvidence = try boundary.inspect(intentURL).1
        for (name, evidence) in snapshot.artifacts.sorted(by: { $0.key < $1.key }) {
            let url = recoveryDirectory.appendingPathComponent(name)
            let capture = recoveryDirectory.appendingPathComponent(name + ".discard-capture")
            if try boundary.exists(url) {
                guard !(try boundary.exists(capture)), try boundary.inspect(url).1 == evidence else { throw ConnectionFileError.staleFile }
                try boundary.renameExclusive(url, to: capture)
                try syncDirectory(recoveryDirectory)
                try afterCapture?(capture)
            }
            if try boundary.exists(capture) {
                guard try boundary.inspect(capture).1 == evidence else { throw ConnectionFileError.staleFile }
                try boundary.remove(capture)
                try syncDirectory(recoveryDirectory)
                try afterRemoval?()
            }
        }
        guard try boundary.entries(recoveryDirectory).filter({ $0.hasPrefix(recoveryID.uuidString) }) == [intentURL.lastPathComponent] else { throw ConnectionFileError.transactionConflict }
        guard try boundary.inspect(intentURL).1 == intentEvidence else { throw ConnectionFileError.staleFile }
        try boundary.remove(intentURL)
        try syncDirectory(recoveryDirectory)
    }

    private func writeJournal(_ journal: ConnectionTransactionJournal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        let temporary = url.appendingPathExtension("tmp")
        try boundary.writePrivate(data, to: temporary)
        try boundary.rename(temporary, to: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func validate(_ journal: ConnectionTransactionJournal, journalURL: URL, destination: URL) throws {
        let directory = journalURL.deletingLastPathComponent()
        guard journal.version == 1, journal.destination == destination.path,
              journalURL.lastPathComponent == "\(journal.recoveryID.uuidString).json",
              journal.beforeImage == directory.appendingPathComponent("\(journal.recoveryID.uuidString).before").path,
              journal.staged == directory.appendingPathComponent("\(journal.recoveryID.uuidString).stage").path else { throw ConnectionFileError.transactionConflict }
        if let restoreStage = journal.restoreStage {
            let url = URL(fileURLWithPath: restoreStage)
            let prefix = "\(journal.recoveryID.uuidString).restore-"
            guard url.deletingLastPathComponent().path == directory.path, url.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw ConnectionFileError.transactionConflict }
        }
    }

    private func syncDirectory(_ url: URL) throws {
        try boundary.syncDirectory(url)
    }
}
