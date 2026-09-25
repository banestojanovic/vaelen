import Darwin
import Foundation

/// Shared terminal presentation policy for Vaelen's human-readable CLI output.
/// Machine-readable and child-process output deliberately bypasses this type.
enum HumanOutput {
    static var terminalWidth: Int {
        var size = winsize()
        if isatty(STDOUT_FILENO) == 1,
           ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0,
           size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return max(40, min(120, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "80") ?? 80))
    }

    static var colorEnabled: Bool {
        DoctorReport.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) == 1,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func heading(_ title: String, subtitle: String? = nil) -> String {
        let title = colorEnabled ? "\u{001B}[1;36m\(title)\u{001B}[0m" : title
        return [title, subtitle].compactMap { $0 }.joined(separator: "\n")
    }

    static func aligned(_ rows: [(String, String)]) -> String {
        guard !rows.isEmpty else { return "" }
        let keyWidth = min(rows.map { $0.0.count }.max() ?? 0, max(10, terminalWidth / 3))
        return rows.map { key, value in
            let prefix = "\(key.padding(toLength: keyWidth, withPad: " ", startingAt: 0))  "
            return wrap(value, width: max(12, terminalWidth - prefix.count), firstPrefix: prefix, nextPrefix: String(repeating: " ", count: prefix.count))
        }.joined(separator: "\n")
    }

    static func list(_ rows: [[String]], headers: [String], empty: String, width requestedWidth: Int? = nil) -> String {
        guard !rows.isEmpty else { return empty }
        let width = max(40, requestedWidth ?? terminalWidth)
        let natural = (0..<headers.count).map { column in
            max(headers[column].count, rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0)
        }
        // Prefer aligned columns when they fit. On narrow terminals, preserve all data
        // as labeled, wrapped records rather than truncating paths or statuses.
        if natural.reduce(0, +) + (headers.count - 1) * 2 <= width {
            let sizes = natural
            func line(_ cells: [String]) -> String {
                cells.enumerated().map { index, cell in
                    index == cells.count - 1 ? cell : cell.padding(toLength: sizes[index], withPad: " ", startingAt: 0)
                }.joined(separator: "  ")
            }
            return ([line(headers)] + rows.map(line)).joined(separator: "\n")
        }
        return rows.map { row in
            zip(headers, row).map { label, value in
                wrap(value, width: max(12, width - label.count - 4), firstPrefix: "  \(label): ", nextPrefix: "    ")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func status(_ label: String, _ detail: String) -> String {
        aligned([(label, detail)])
    }

    static func warning(_ message: String) -> String {
        let text = wrappedMessage("Warning: ", message)
        return colorEnabled ? "\u{001B}[33m\(text)\u{001B}[0m" : text
    }

    static func error(_ message: String) -> String {
        let text = wrappedMessage("Error: ", message)
        return colorEnabled ? "\u{001B}[31m\(text)\u{001B}[0m" : text
    }

    private static func wrappedMessage(_ label: String, _ message: String) -> String {
        let paragraphs = message.components(separatedBy: "\n")
        return paragraphs.enumerated().map { index, paragraph in
            wrap(paragraph, width: max(12, terminalWidth - (index == 0 ? label.count : 0)), firstPrefix: index == 0 ? label : "", nextPrefix: String(repeating: " ", count: label.count))
        }.joined(separator: "\n")
    }

    static func wrap(_ text: String, width: Int, firstPrefix: String = "", nextPrefix: String = "") -> String {
        let limit = max(1, width)
        var result: [String] = []
        var prefix = firstPrefix
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.count > limit {
                if !line.isEmpty {
                    result.append(prefix + line)
                    prefix = nextPrefix
                    line = ""
                }
                var remainder = word[...]
                while remainder.count > limit {
                    let end = remainder.index(remainder.startIndex, offsetBy: limit)
                    result.append(prefix + remainder[..<end])
                    prefix = nextPrefix
                    remainder = remainder[end...]
                }
                line = String(remainder)
                continue
            }
            if !line.isEmpty && line.count + 1 + word.count > limit {
                result.append(prefix + line)
                prefix = nextPrefix
                line = word
            } else {
                line += (line.isEmpty ? "" : " ") + word
            }
        }
        if !line.isEmpty { result.append(prefix + line) }
        return result.joined(separator: "\n")
    }
}
