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

    static func heading(_ title: String, subtitle: String? = nil, color: Bool? = nil) -> String {
        let title = semantic(title, tint: 33, color: color)
        return [title, subtitle].compactMap { $0 }.joined(separator: "\n")
    }

    static func aligned(_ rows: [(String, String)], width requestedWidth: Int? = nil, color: Bool? = nil) -> String {
        guard !rows.isEmpty else { return "" }
        let width = max(20, requestedWidth ?? terminalWidth)
        let labelWidth = min(rows.map { visibleWidth($0.0) }.max() ?? 0, max(10, width / 3))
        return rows.map { label, value in
            let styledLabel = semantic(label, tint: 36, color: color)
            let prefix = "  \(styledLabel)\(String(repeating: " ", count: max(0, labelWidth - visibleWidth(label))))  "
            return wrap(value, width: width, firstPrefix: prefix, nextPrefix: String(repeating: " ", count: visibleWidth(prefix)))
        }.joined(separator: "\n")
    }

    static func list(_ rows: [[String]], headers: [String], empty: String, width requestedWidth: Int? = nil) -> String {
        guard !rows.isEmpty else { return empty }
        return table(rows, headers: headers, width: requestedWidth)
    }

    /// Shared renderer for command lists and grouped informational records.
    /// It deliberately favors simple aligned text over grids and card borders.
    static func table(_ rows: [[String]], headers: [String], width requestedWidth: Int? = nil, color: Bool? = nil) -> String {
        guard !rows.isEmpty, !headers.isEmpty else { return "" }
        let width = max(20, requestedWidth ?? terminalWidth)
        if headers == ["Command", "What it does"] || headers == ["Command / form", "What it does"] {
            return commandList(rows.map { ($0.first ?? "", $0.dropFirst().first ?? "") }, width: width, color: color)
        }
        if headers == ["Property", "Value"] {
            return aligned(rows.compactMap { row in
                guard row.count >= 2 else { return nil }
                return (row[0], row[1])
            }, width: width, color: color)
        }
        if headers.count == 1 {
            return rows.map { row in
                "  " + semantic("›", tint: 36, color: color) + " " + wrap(row.first ?? "", width: max(1, width - 4), firstPrefix: "", nextPrefix: "    ")
            }.joined(separator: "\n")
        }
        return rows.map { row in
            let values = headers.indices.map { row.indices.contains($0) ? row[$0] : "" }
            let first = values.first ?? ""
            let rest = zip(headers.dropFirst(), values.dropFirst()).map { label, value in
                aligned([(label, value)], width: width, color: color)
            }
            let firstLabel = headers.first ?? ""
            let firstLine = wrap("\(firstLabel): \(first)", width: max(1, width - 2), firstPrefix: "  ", nextPrefix: "    ")
                .components(separatedBy: "\n")
                .map { semantic($0, tint: 36, color: color) }
            return (firstLine + rest).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func commandList(_ rows: [(String, String)], width requestedWidth: Int? = nil, color: Bool? = nil) -> String {
        guard !rows.isEmpty else { return "" }
        let width = max(20, requestedWidth ?? terminalWidth)
        let splitForms = rows.map { $0.0.components(separatedBy: "  ·  ") }
        let commandWidth = min(splitForms.compactMap(\.first).map(visibleWidth).max() ?? 0, max(12, width / 2))
        return zip(rows, splitForms).map { row, forms in
            let command = forms.first ?? row.0
            let description = row.1
            let commandLines = wrap(command, width: max(1, width - 2), firstPrefix: "  ", nextPrefix: "    ").components(separatedBy: "\n")
            var lines = commandLines.map { semantic($0, tint: 36, color: color) }
            if width >= 64 && visibleWidth(command) <= commandWidth {
                let prefixWidth = commandWidth + 4
                lines[0] += String(repeating: " ", count: max(2, prefixWidth - visibleWidth("  \(command)")))
                let descriptionLines = wrap(description, width: width - prefixWidth).components(separatedBy: "\n")
                lines[0] += descriptionLines.first ?? ""
                lines += descriptionLines.dropFirst().map { String(repeating: " ", count: prefixWidth) + $0 }
            } else {
                lines.append(wrap(description, width: width, firstPrefix: "    ", nextPrefix: "    "))
            }
            for form in forms.dropFirst() {
                lines.append(wrap(semantic("    \(form)", tint: 36, color: color), width: width, firstPrefix: "", nextPrefix: "      "))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func status(_ label: String, _ detail: String) -> String {
        aligned([(label, detail)])
    }

    static func report(_ title: String, rows: [(String, String)], width: Int? = nil, color: Bool? = nil) -> String {
        heading(title, color: color) + (rows.isEmpty ? "" : "\n" + aligned(rows, width: width, color: color))
    }

    static func success(_ message: String) -> String {
        self.message(message, tint: 32)
    }

    static func message(_ message: String, tint: Int = 0) -> String {
        message.components(separatedBy: "\n").map { paragraph in
            wrap(paragraph, width: terminalWidth).components(separatedBy: "\n")
                .map { semantic($0, tint: tint) }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func state(_ value: String) -> String { semantic(value, tint: stateColor(value)) }

    static func semantic(_ message: String, tint: Int, color: Bool? = nil) -> String {
        guard (color ?? colorEnabled), tint != 0 else { return message }
        return "\u{001B}[\(tint)m\(message)\u{001B}[0m"
    }

    static func stateColor(_ value: String) -> Int {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
        switch normalized {
        case "healthy", "running", "ownedrunning", "active", "trusted", "local", "secured", "satisfied", "available", "success", "succeeded", "complete", "completed", "ready", "confirmed", "removed", "enabled", "resolved", "high": return 32
        case "warning", "degraded", "partial", "starting", "stopping", "installing", "removing", "downloading", "verifying", "conflict", "mismatch", "not trusted", "untrusted", "not-initialized", "not initialized", "notinitialized", "blocked", "deferred", "medium": return 33
        case "unhealthy", "failed", "error", "broken", "invalid", "low": return 31
        case "unavailable", "off", "stopped", "installed", "missing", "not installed", "notinstalled", "not running", "notrunning", "unknown", "not checked", "notchecked", "none", "absent", "disabled", "pending", "info", "not requested", "notrequested": return 90
        default: return 0
        }
    }

    static func warning(_ message: String) -> String {
        styledMessage("Warning: ", message, tint: 33)
    }

    static func error(_ message: String) -> String {
        styledMessage("Error: ", message, tint: 31)
    }

    static func conflict(_ message: String) -> String { styledMessage("Conflict: ", message, tint: 33) }

    private static func styledMessage(_ label: String, _ message: String, tint: Int) -> String {
        let paragraphs = message.components(separatedBy: "\n")
        let lines = paragraphs.enumerated().flatMap { index, paragraph in
            wrap(paragraph, width: terminalWidth, firstPrefix: index == 0 ? label : String(repeating: " ", count: label.count), nextPrefix: String(repeating: " ", count: label.count)).components(separatedBy: "\n")
        }.joined(separator: "\n")
        return lines.components(separatedBy: "\n").map { semantic($0, tint: tint) }.joined(separator: "\n")
    }

    static func wrap(_ text: String, width: Int, firstPrefix: String = "", nextPrefix: String = "") -> String {
        let width = max(1, width)
        let words = terminalWords(text)
        var result: [String] = []
        var prefix = firstPrefix
        var line = ""
        var lineWidth = visibleWidth(prefix)
        var contentWidth = 0
        var activeSGR = ""

        func nextLine() {
            result.append(prefix + line)
            prefix = nextPrefix
            line = activeSGR
            lineWidth = visibleWidth(prefix)
            contentWidth = 0
        }

        for word in words {
            let wordWidth = word.units.reduce(0) { $0 + $1.width }
            let separatorWidth = visibleWidth(word.separator)
            if contentWidth == 0, line.isEmpty, !firstPrefix.isEmpty,
               lineWidth + separatorWidth + wordWidth > width,
               visibleWidth(nextPrefix) + separatorWidth + wordWidth <= width {
                let label = prefix.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                result.append(label)
                prefix = nextPrefix
                line = activeSGR
                lineWidth = visibleWidth(prefix)
            }
            if contentWidth > 0 && lineWidth + separatorWidth + wordWidth > width {
                nextLine()
            }
            if !word.separator.isEmpty {
                line += word.separator
                lineWidth += separatorWidth
                contentWidth += separatorWidth
            }
            for (index, unit) in word.units.enumerated() {
                if unit.isANSI {
                    line += unit.raw
                    if unit.raw.hasPrefix("\u{001B}[") && unit.raw.hasSuffix("m") {
                        let parameters = unit.raw.dropFirst(2).dropLast()
                        if parameters.isEmpty || parameters == "0" { activeSGR = "" }
                        else { activeSGR = unit.raw }
                    }
                    continue
                }
                if unit.raw == "/", contentWidth > 0 {
                    var componentWidth = unit.width
                    var componentIndex = index + 1
                    while componentIndex < word.units.count, word.units[componentIndex].raw != "/" {
                        componentWidth += word.units[componentIndex].width
                        componentIndex += 1
                    }
                    if lineWidth + componentWidth > width,
                       componentWidth <= width - visibleWidth(nextPrefix) {
                        nextLine()
                    }
                }
                if lineWidth + unit.width > width {
                    nextLine()
                }
                line += unit.raw
                lineWidth += unit.width
                contentWidth += unit.width
            }
        }
        if contentWidth > 0 || !line.isEmpty { result.append(prefix + line) }
        return result.joined(separator: "\n")
    }

    private struct TerminalUnit {
        let raw: String
        let width: Int
        let isANSI: Bool
    }

    private struct TerminalWord {
        let separator: String
        let units: [TerminalUnit]
    }

    private static func terminalWords(_ text: String) -> [TerminalWord] {
        var words = [TerminalWord]()
        var units = [TerminalUnit]()
        var separator = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{001B}" {
                var end = text.index(after: index)
                if end < text.endIndex {
                    let introducer = text[end]
                    if introducer == "[" {
                        end = text.index(after: end)
                        while end < text.endIndex {
                            let scalar = text[end].unicodeScalars.first?.value ?? 0
                            end = text.index(after: end)
                            if (0x40...0x7E).contains(scalar) { break }
                        }
                    } else if introducer == "]" {
                        end = text.index(after: end)
                        while end < text.endIndex {
                            if text[end] == "\u{0007}" { end = text.index(after: end); break }
                            if text[end] == "\u{001B}" {
                                let maybeEnd = text.index(after: end)
                                if maybeEnd < text.endIndex && text[maybeEnd] == "\\" {
                                    end = text.index(after: maybeEnd)
                                    break
                                }
                            }
                            end = text.index(after: end)
                        }
                    } else {
                        end = text.index(after: end)
                    }
                }
                units.append(TerminalUnit(raw: String(text[index..<end]), width: 0, isANSI: true))
                index = end
                continue
            }
            if character.isWhitespace {
                if !units.isEmpty {
                    words.append(TerminalWord(separator: separator, units: units))
                    separator = ""
                    units = []
                }
                separator.append(character)
            } else {
                units.append(TerminalUnit(raw: String(character), width: cellWidth(String(character)), isANSI: false))
            }
            index = text.index(after: index)
        }
        if !units.isEmpty {
            words.append(TerminalWord(separator: separator, units: units))
            separator = ""
        }
        if !separator.isEmpty { words.append(TerminalWord(separator: separator, units: [])) }
        return words
    }

    private static func cellWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let value = scalar.value
            let measured = Int(wcwidth(wchar_t(value)))
            if measured >= 0 { return width + measured }
            if value < 0x20 || (0x7F...0x9F).contains(value) || isCombining(value) { return width }
            return width + (isWide(value) ? 2 : 1)
        }
    }

    private static func isCombining(_ value: UInt32) -> Bool {
        (0x0300...0x036F).contains(value) || (0x1AB0...0x1AFF).contains(value) ||
        (0x1DC0...0x1DFF).contains(value) || (0x20D0...0x20FF).contains(value) ||
        (0xFE00...0xFE0F).contains(value) || (0xFE20...0xFE2F).contains(value) ||
        (0xE0100...0xE01EF).contains(value) || value == 0x200D
    }

    private static func isWide(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value) || value == 0x2329 || value == 0x232A ||
        (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value) ||
        (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE19).contains(value) ||
        (0xFE30...0xFE6F).contains(value) || (0xFF00...0xFF60).contains(value) ||
        (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value) ||
        (0x20000...0x3FFFD).contains(value)
    }

    private static func visibleWidth(_ text: String) -> Int {
        let pattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))"
        let plain = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cellWidth(plain)
    }
}
