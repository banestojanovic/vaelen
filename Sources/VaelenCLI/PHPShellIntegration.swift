import Darwin
import Foundation

enum PHPShellIntegration {
    private static let begin = "# >>> Vaelen PHP runtime resolution >>>"
    private static let end = "# <<< Vaelen PHP runtime resolution <<<"
    private static var fileManager: FileManager { .default }
    static let shellBlock = #"""
    # >>> Vaelen PHP runtime resolution >>>
    function php() {
      local _vaelen_php_path _vaelen_php_result _vaelen_php_status _vaelen_activity _vaelen_php_version _vaelen_php_ini
      _vaelen_php_result="$("$HOME/Library/Application Support/Vaelen/bin/vaelen-php-resolver" php resolve --path 2>&1)"
      _vaelen_php_status=$?
      if (( _vaelen_php_status != 0 )); then
        if (( _vaelen_php_status == 3 )); then
          _vaelen_activity="$HOME/Library/Application Support/Vaelen/state/activity"
          if [[ -r "$_vaelen_activity" ]] && [[ "$(<"$_vaelen_activity")" == inactive ]]; then
            command php "$@"
            return $?
          fi
          if [[ ! -r "$_vaelen_activity" ]]; then
            print -u2 "Vaelen activity is unknown; refusing to switch PHP runtimes. Start Vaelen or retry after a clean Quit."
            return 3
          fi
        fi
        [[ -n "$_vaelen_php_result" ]] && print -u2 -- "$_vaelen_php_result"
        return $_vaelen_php_status
      fi
      _vaelen_php_path="$_vaelen_php_result"
      if [[ ! -x "$_vaelen_php_path" ]]; then
        print -u2 "Vaelen could not resolve an executable PHP runtime. Check that Vaelen Core is running and a PHP version is installed."
        return 127
      fi
      _vaelen_php_version="${_vaelen_php_path:h:t}"
      _vaelen_php_ini="$HOME/Library/Application Support/Vaelen/config/php/versions/${_vaelen_php_version}/cli.ini"
      if [[ ! -r "$_vaelen_php_ini" ]]; then
        print -u2 "Vaelen's managed PHP configuration for ${_vaelen_php_version} is unavailable. Open Vaelen Settings → PHP and retry."
        return 127
      fi
      PHPRC="$_vaelen_php_ini" PHP_INI_SCAN_DIR="" "$_vaelen_php_path" "$@"
    }
    # <<< Vaelen PHP runtime resolution <<<
    """#

    private static var zshrcURL: URL {
        if let override = ProcessInfo.processInfo.environment["VAELEN_ZSHRC"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    private static var resolverDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaelen/bin", isDirectory: true)
    }

    private static var resolverURL: URL { resolverDirectory.appendingPathComponent("vaelen-php-resolver") }
    private static var ownershipURL: URL { resolverDirectory.appendingPathComponent("vaelen-php-resolver.sha256") }

    static func status() throws -> String {
        let source = try readZshrc()
        let scan = scanBlocks(in: source)
        if scan.malformed { return "Shell integration: Broken (incomplete or misordered Vaelen block in \(zshrcURL.path))" }
        if scan.blocks.count > 1 { return "Shell integration: Broken (multiple Vaelen blocks in \(zshrcURL.path))" }
        guard let block = scan.blocks.first else { return "Shell integration: Disabled" }
        guard block == (try template()), resolverIsOwnedAndValid() else {
            return "Shell integration: Broken (block or resolver is missing, modified, or not executable)"
        }
        return "Shell integration: Enabled (zsh)"
    }

    static func install() throws -> String {
        let source = try readZshrc()
        let scan = scanBlocks(in: source)
        guard !scan.malformed else {
            throw CLIError.message("Cannot install shell integration because the Vaelen block markers in \(zshrcURL.path) are incomplete or misordered.")
        }
        let block = try template()
        try installResolver()

        let alreadySingle = scan.blocks.count == 1 && scan.blocks[0] == block
        if !alreadySingle {
            let remainder = removingBlocks(scan.ranges, from: source)
            var updated = remainder
            if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
            updated += block
            try writeZshrc(updated)
        }
        return "Shell integration installed (zsh). Open a new shell or source \(zshrcURL.path)."
    }

    static func uninstall() throws -> String {
        let source = try readZshrc()
        let scan = scanBlocks(in: source)
        guard !scan.malformed else {
            throw CLIError.message("Cannot remove shell integration because the Vaelen block markers in \(zshrcURL.path) are incomplete or misordered. No files were changed.")
        }
        if !scan.ranges.isEmpty { try writeZshrc(removingBlocks(scan.ranges, from: source)) }

        var resolverRemoved = false
        if resolverIsOwnedAndValid() {
            try fileManager.removeItem(at: resolverURL)
            try fileManager.removeItem(at: ownershipURL)
            resolverRemoved = true
        }
        let extra = resolverRemoved ? " The Vaelen resolver was removed." : ""
        return "Shell integration uninstalled. Unrelated zsh configuration was preserved.\(extra)"
    }

    private struct BlockScan {
        var ranges: [Range<String.Index>] = []
        var blocks: [String] = []
        var malformed = false
    }

    private static func scanBlocks(in text: String) -> BlockScan {
        var result = BlockScan()
        var openStart: String.Index?
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            var contentEnd = lineEnd
            if contentEnd > lineStart, text[text.index(before: contentEnd)] == "\r" { contentEnd = text.index(before: contentEnd) }
            let line = text[lineStart..<contentEnd]
            if line == begin {
                if openStart != nil { result.malformed = true }
                else { openStart = lineStart }
            } else if line == end {
                guard let start = openStart else { result.malformed = true; lineStart = next; continue }
                result.ranges.append(start..<next)
                result.blocks.append(String(text[start..<next]))
                openStart = nil
            }
            lineStart = next
        }
        if openStart != nil { result.malformed = true }
        return result
    }

    private static func removingBlocks(_ ranges: [Range<String.Index>], from source: String) -> String {
        var result = source
        for range in ranges.reversed() { result.removeSubrange(range) }
        return result
    }

    private static func readZshrc() throws -> String {
        guard fileManager.fileExists(atPath: zshrcURL.path) else { return "" }
        return try String(contentsOf: zshrcURL, encoding: .utf8)
    }

    private static func template() throws -> String {
        shellBlock
    }

    private static func installResolver() throws {
        if fileManager.fileExists(atPath: resolverURL.path), !fileManager.fileExists(atPath: ownershipURL.path) {
            throw CLIError.message("Refusing to replace an unowned file at \(resolverURL.path). Move it aside, then run `val shell install` again.")
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), fileManager.isExecutableFile(atPath: executable.path) else {
            throw CLIError.message("Unable to locate the Vaelen CLI executable to install the PHP resolver.")
        }
        try fileManager.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)
        let temporary = resolverDirectory.appendingPathComponent(".vaelen-php-resolver.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: executable, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        try replace(temporary, at: resolverURL)
        try Data((try sha256(resolverURL) + "\n").utf8).write(to: ownershipURL, options: .atomic)
    }

    private static func resolverIsOwnedAndValid() -> Bool {
        guard fileManager.isExecutableFile(atPath: resolverURL.path),
              let expected = try? String(contentsOf: ownershipURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let actual = try? sha256(resolverURL) else { return false }
        return expected == actual
    }

    private static func sha256(_ url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let line = String(data: data, encoding: .utf8), let digest = line.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError.message("Unable to verify the installed Vaelen PHP resolver.")
        }
        return String(digest)
    }

    private static func replace(_ temporary: URL, at destination: URL) throws {
        if rename(temporary.path, destination.path) != 0 {
            throw CLIError.message("Unable to update the Vaelen PHP resolver at \(destination.path).")
        }
    }

    private static func writeZshrc(_ text: String) throws {
        try fileManager.createDirectory(at: zshrcURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = zshrcURL.deletingLastPathComponent().appendingPathComponent(".zshrc.vaelen.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try Data(text.utf8).write(to: temporary)
        if fileManager.fileExists(atPath: zshrcURL.path),
           let permissions = (try? fileManager.attributesOfItem(atPath: zshrcURL.path)[.posixPermissions]) as? NSNumber {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
        }
        try replace(temporary, at: zshrcURL)
    }
}
