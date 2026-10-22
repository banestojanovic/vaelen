import Foundation

public struct PHPReleaseAdvisory: Codable, Equatable, Sendable {
    public let version: String
    public let releasedAt: Date
    public let isSecurity: Bool
    public func formattedReleaseDate(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: releasedAt)
    }

    public var announcementURL: URL { URL(string: "https://www.php.net/releases/\(version.replacingOccurrences(of: ".", with: "_")).php")! }

    public static func parse(_ data: Data, family: String) throws -> Self {
        struct Release: Decodable {
            let version: String
            let date: String
            let tags: [String]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yyyy"
        formatter.isLenient = false
        guard let version = PHPVersion(release.version), version.isStable,
              version.description == release.version, version.family == family,
              release.tags.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.unicodeScalars.allSatisfy { CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_ ")).contains($0) } }),
              release.date.range(of: #"^[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}$"#, options: .regularExpression) != nil,
              let date = formatter.date(from: release.date), [formatter.string(from: date), "0" + formatter.string(from: date)].contains(release.date),
              date <= Date().addingTimeInterval(24 * 60 * 60) else { throw PHPReleaseAdvisoryError.invalidRelease }
        return Self(version: release.version, releasedAt: date, isSecurity: release.tags.contains("security"))
    }
}

public struct PHPReleaseSourceStatus: Codable, Equatable, Sendable {
    public let family: String
    public let release: PHPReleaseAdvisory?
    public let lastAttemptAt: Date?
    public let lastSuccessfulAt: Date?
    public let error: String?

    public init(family: String, release: PHPReleaseAdvisory? = nil, lastAttemptAt: Date? = nil, lastSuccessfulAt: Date? = nil, error: String? = nil) {
        self.family = family; self.release = release; self.lastAttemptAt = lastAttemptAt; self.lastSuccessfulAt = lastSuccessfulAt; self.error = error
    }
}

public struct PHPUpdateReport: Codable, Equatable, Sendable {
    public let family: String
    public let installedVersion: String
    public let packageVersion: String?
    public let upstreamRelease: PHPReleaseAdvisory?
    public let upstreamPackageAvailable: Bool
    public let source: PHPReleaseSourceStatus

    public static func project(installed: [PHPRuntimeVersion], available: [String], sources: [PHPReleaseSourceStatus]) -> [Self] {
        sources.compactMap { source in
            guard let newest = installed.compactMap({ PHPVersion($0.version) }).filter({ $0.family == source.family }).max() else { return nil }
            let package = available.compactMap(PHPVersion.init).filter { $0.isStable && $0.family == newest.family && $0 > newest }.max()
            let release = source.release.flatMap { advisory -> PHPReleaseAdvisory? in
                guard let version = PHPVersion(advisory.version), version > newest else { return nil }
                return advisory
            }
            return Self(family: source.family, installedVersion: newest.description, packageVersion: package?.description, upstreamRelease: release, upstreamPackageAvailable: release.map { available.contains($0.version) } ?? false, source: source)
        }
    }
}

enum PHPReleaseAdvisoryError: Error { case invalidRelease, invalidResponse }

final class PHPReleaseAdvisoryStore: @unchecked Sendable {
    private static let lock = NSLock()
    private let directory: URL
    private let fetch: (URL, TimeInterval) throws -> Data

    init(directory: URL, fetch: ((URL) throws -> Data)? = nil) {
        self.directory = directory.appendingPathComponent("php-official-releases", isDirectory: true)
        self.fetch = fetch.map { operation in { url, _ in try operation(url) } } ?? Self.download
    }

    func snapshot(families: [String]) -> [PHPReleaseSourceStatus] {
        return families.sorted().map { read($0) }
    }

    func refresh(families: [String], force: Bool) {
        guard Self.lock.try() else { return }
        defer { Self.lock.unlock() }
        let deadline = Date().addingTimeInterval(22)
        for family in families.sorted() {
            guard let parsed = PHPVersion(family + ".0"), parsed.family == family else { continue }
            let prior = read(family)
            let now = Date()
            if !force, let attempt = prior.lastAttemptAt, now.timeIntervalSince(attempt) < 12 * 60 * 60 { continue }
            let state: PHPReleaseSourceStatus
            do {
                let url = URL(string: "https://www.php.net/releases/index.php?json&version=\(family)")!
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw URLError(.timedOut) }
                let release = try PHPReleaseAdvisory.parse(fetch(url, remaining), family: family)
                state = PHPReleaseSourceStatus(family: family, release: release, lastAttemptAt: now, lastSuccessfulAt: now)
            } catch {
                state = PHPReleaseSourceStatus(family: family, release: prior.release, lastAttemptAt: now, lastSuccessfulAt: prior.lastSuccessfulAt, error: "Official PHP release check failed: \(error.localizedDescription)")
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(state).write(to: file(family), options: .atomic)
        }
    }

    private func file(_ family: String) -> URL { directory.appendingPathComponent(family + ".json") }
    private func read(_ family: String) -> PHPReleaseSourceStatus {
        guard let parsed = PHPVersion(family + ".0"), parsed.family == family,
              let state = try? JSONDecoder().decode(PHPReleaseSourceStatus.self, from: Data(contentsOf: file(family))), state.family == family,
              state.release.map({ PHPVersion($0.version)?.family == family && PHPVersion($0.version)?.isStable == true }) ?? true else { return PHPReleaseSourceStatus(family: family) }
        return state
    }

    private static func download(_ url: URL, timeout: TimeInterval) throws -> Data {
        let delegate = PHPReleaseDownloadDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(15, timeout)
        configuration.timeoutIntervalForResource = min(20, timeout)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        guard delegate.finished.wait(timeout: .now() + timeout) == .success else { throw URLError(.timedOut) }
        guard delegate.error == nil, delegate.accepted else { throw PHPReleaseAdvisoryError.invalidResponse }
        return delegate.data
    }
}

private final class PHPReleaseDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    var data = Data()
    var error: Error?
    var accepted = false

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        accepted = response.url?.scheme == "https" && response.url?.host == "www.php.net" && (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 256 * 1024
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count + bytes.count <= 256 * 1024 else { accepted = false; dataTask.cancel(); return }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { self.error = error; finished.signal() }
}
