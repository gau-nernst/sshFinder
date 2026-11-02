import AppKit
import SwiftUI

struct TransfersPanel: View {
    @State private var expanded = true

    var body: some View {
        let manager = Store.shared.transfers
        if !manager.items.isEmpty {
            let active = manager.items.filter(\.isActive)
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Text("Transfers").font(.headline)
                            Text(active.isEmpty ? "\(manager.items.count) finished" : "\(active.count) active")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide transfers" : "Show transfers")
                    // Collapsed, one bar still shows how far the active ones are.
                    if !expanded && !active.isEmpty {
                        let total = active.reduce(Int64(0)) { $0 + $1.total }
                        let done = active.reduce(Int64(0)) { $0 + min($1.done, $1.total) }
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                            .frame(maxWidth: 200)
                    }
                    Spacer()
                    Button("Clear Finished") { manager.clearFinished() }
                        .buttonStyle(.link)
                        .disabled(!manager.items.contains { !$0.isActive })
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                if expanded {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(manager.items) { t in
                                Divider()
                                TransferRow(transfer: t, manager: manager)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
            .background(.bar)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    var body: some View {
        let t = transfer
        // Copies land remotely like uploads, so they show and retry the same way.
        let isUpload = t.direction != .download
        HStack(spacing: 10) {
            Image(systemName: t.direction == .copy ? "arrow.left.arrow.right.circle"
                  : isUpload ? "arrow.up.circle" : "arrow.down.circle")
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .help(t.direction == .copy ? "Copy between hosts" : isUpload ? "Upload" : "Download")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: t.isDir ? "folder" : "doc").foregroundStyle(.secondary)
                    Text(isUpload ? t.name : (t.localURL?.lastPathComponent ?? t.name))
                        .lineLimit(1).truncationMode(.middle)
                    Text(t.source.map { "from \($0.host) to \(t.host):\(t.remoteDir)" }
                         ?? (isUpload ? "to \(t.host):\(t.remoteDir)" : "from \(t.host)"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if t.status == .running {
                    if t.total > 0 {
                        ProgressView(value: Double(min(t.done, t.total)), total: Double(t.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            switch t.status {
            case .queued, .running:
                iconButton("xmark.circle.fill", "Cancel") { manager.cancel(t) }
            case .failed, .cancelled:
                iconButton("arrow.clockwise.circle", isUpload || t.isDir ? "Retry" : "Resume") { manager.retry(t) }
            case .done:
                if !isUpload, let url = t.localURL {
                    Button("Open") { NSWorkspace.shared.open(url) }
                    iconButton("magnifyingglass.circle", "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var isFailed: Bool {
        if case .failed = transfer.status { return true }
        return false
    }

    private var statusText: String {
        let t = transfer
        let done = t.done.formatted(.byteCount(style: .file, spellsOutZero: false))
        let total = t.total.formatted(.byteCount(style: .file, spellsOutZero: false))
        switch t.status {
        case .queued: return "Waiting…"
        case .running:
            let speed = Int64(t.bytesPerSecond).formatted(.byteCount(style: .file, spellsOutZero: false)) + "/s"
            return t.total > 0 ? "\(done) of \(total) · \(speed)" : "\(done) · \(speed)"
        case .done:
            let verb = t.direction == .download ? "Done" : t.replace ? "Replaced" : t.direction == .copy ? "Copied" : "Uploaded"
            return t.note ?? "\(total) · \(verb)"
        case .cancelled: return "Cancelled at \(done)"
        case .failed(let message): return message
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).imageScale(.large) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
