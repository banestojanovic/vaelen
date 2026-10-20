import SwiftUI
import AppKit
import VaelenCore
import VaelenIPC

struct ManagedLogsWindow: View {
    let model: ManagedLogViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedLog?.title ?? "Service Logs").font(.headline)
                    Text(model.selectedLog?.service ?? "Vaelen-managed services").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Log", selection: selection) {
                    Text("Select a log").tag(Optional<String>.none)
                    ForEach(model.catalog, id: \.id) { entry in Text(entry.title).tag(Optional(entry.id)) }
                }
                .labelsHidden().frame(minWidth: 220).accessibilityLabel("Managed service log")
                Picker("Recent lines", selection: lineSelection) {
                    ForEach(ManagedLogViewerModel.lineChoices, id: \.self) { Text("\($0) lines").tag($0) }
                }
                .frame(width: 125).accessibilityLabel("Number of recent log lines")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .controlSize(.small).accessibilityLabel("Refresh selected service log")
                    .disabled(model.catalogState == .loading)
                Button("Copy", systemImage: "doc.on.doc") { copyDisplayedText() }
                    .controlSize(.small).accessibilityLabel("Copy displayed service log text")
                    .disabled(model.copyText == nil)
            }
            .padding(14)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
        }
        .frame(minWidth: 620, minHeight: 360)
        .task { await model.refresh() }
        .onDisappear { model.invalidatePendingReads() }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .idle:
            if case .loading = model.catalogState { ProgressView("Loading managed logs…") }
            else { stateMessage("Select a managed service log to view recent entries.", symbol: "doc.text") }
        case .loading:
            VStack(spacing: 8) { ProgressView(); Text("Loading log…").font(.caption).foregroundStyle(.secondary) }
        case .empty: stateMessage("This log is empty.", symbol: "text.alignleft")
        case .text(let text, let truncated, let linesReturned):
            VStack(alignment: .leading, spacing: 8) {
                if truncated {
                    Label("Showing the last \(linesReturned) lines. Earlier content was omitted.", systemImage: "arrow.down.to.line")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(text.isEmpty ? " " : text).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
        case .missing: stateMessage("Core reports that this service log is missing. Refresh to check again.", symbol: "doc.questionmark")
        case .unreadable: stateMessage("Core could not read this service log.", symbol: "lock.slash")
        case .unsafePath: stateMessage("Core declined to read this log because its path is outside the managed log location.", symbol: "exclamationmark.shield")
        case .disconnected: stateMessage("Vaelen Core is disconnected. Reconnect and refresh to read managed service logs.", symbol: "cable.connector.slash")
        case .failed(let message): stateMessage("Could not read this log: \(message)", symbol: "exclamationmark.triangle")
        case .removedFromCatalog(let id): stateMessage("\(id) is no longer listed by Core. It may have been removed or is no longer installed.", symbol: "minus.circle")
        }
        if case .disconnected = model.catalogState {
            Text("The managed log catalog is unavailable because Vaelen Core is disconnected.")
                .font(.caption).foregroundStyle(.orange).padding(.top, 7)
        } else if case .failed(let error) = model.catalogState {
            Text("Could not load the managed log catalog: \(error)").font(.caption).foregroundStyle(.orange).padding(.top, 7)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedID }, set: { value in Task { await model.select(id: value) } })
    }
    private var lineSelection: Binding<Int> {
        Binding(get: { model.lineCount }, set: { value in Task { await model.selectLineCount(value) } })
    }
    private func stateMessage(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol).font(.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 540)
    }
    private func copyDisplayedText() {
        guard let text = model.copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
