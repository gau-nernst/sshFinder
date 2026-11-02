import AppKit
import SwiftUI

/// Back/up, the editable host:/path, filter, and folder actions in one row.
struct ActionBar: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        HStack(spacing: 4) {
            BarButton(symbol: "chevron.left", help: "Back") { browser.goBack() }
                .disabled(!browser.canGoBack)
            BarButton(symbol: "arrow.up", help: "Enclosing folder") { browser.goUp() }
                .disabled(!browser.canGoUp)
            field {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("host:/path", text: $browser.pathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { browser.go(to: browser.pathInput) }
                    .help("Paste host:/path or a path on this host, then press Return")
                if browser.loading { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 4)
            field {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter", text: $browser.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !browser.filter.isEmpty {
                    Button { browser.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170)
            .padding(.trailing, 4)
            BarButton(symbol: "arrow.clockwise", help: "Refresh") { browser.refresh() }
            BarButton(symbol: "folder.badge.plus", help: "New folder") { browser.askNewFolder() }
                .disabled(!browser.canReceive)
            BarButton(symbol: "apple.terminal", title: "Terminal",
                      help: "Open a terminal on this host, in this folder (\(Terminal.hasITerm ? "iTerm2" : "Terminal"))") {
                if let host = browser.host { Terminal.open(host: host, folder: browser.cwd) }
            }
            .disabled(browser.cwd.isEmpty)
            BarButton(symbol: "arrow.up.doc", title: "Upload",
                      help: "Upload files or folders here. You can also drag them in from Finder.") { chooseUpload() }
                .disabled(!browser.canReceive)
            if let clip = browser.store.clipboard {
                BarButton(symbol: "doc.on.clipboard", title: "Paste \(clip.entries.count)",
                          help: "Paste \(clip.entries.count) item\(clip.entries.count == 1 ? "" : "s") copied from \(clip.host) into this folder") {
                    browser.paste()
                }
                .disabled(!browser.canReceive)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(browser.host ?? ""):\(browser.cwd)"
        if panel.runModal() == .OK { browser.upload(panel.urls) }
    }
}

/// The file list of a connected tab; also the drop target for uploads.
struct BrowserPane: View {
    @Environment(Browser.self) private var browser
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var browser = browser
        let deleting = browser.deleting ?? []
        FileList()
            .alert("New Folder", isPresented: shown(\.newFolderName)) {
                TextField("Name", text: Binding(get: { browser.newFolderName ?? "" }, set: { browser.newFolderName = $0 }))
                Button("Create") {
                    let name = browser.newFolderName ?? ""
                    Task { await browser.createFolder(name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In \(browser.cwd)")
            }
            .alert("Rename", isPresented: shown(\.renaming), presenting: browser.renaming) { e in
                TextField("Name", text: $browser.renameText)
                Button("Rename") {
                    let name = browser.renameText
                    Task { await browser.rename(e, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { e in
                Text("“\(e.name)” in \(browser.cwd)")
            }
            .alert(deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) items?",
                   isPresented: shown(\.deleting), presenting: browser.deleting) { items in
                Button("Delete", role: .destructive) { Task { await browser.delete(items) } }
                Button("Cancel", role: .cancel) {}
            } message: { items in
                let names = items.prefix(5).map(\.name).joined(separator: ", ") + (items.count > 5 ? ", …" : "")
                let folders = items.contains(where: \.isDir) ? " Folders are deleted with everything in them." : ""
                Text("\(items.count > 1 ? names + "\n\n" : "")From \(browser.host ?? ""):\(browser.cwd). This can't be undone.\(folders)")
            }
            .alert(browser.failure?.title ?? "", isPresented: shown(\.failure)) {
                Button("OK") {}
            } message: {
                Text(browser.failure?.message ?? "")
            }
            .onDrop(of: [.fileURL], delegate: UploadDrop(browser: browser, targeted: $dropTargeted))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.08))
                        .overlay(alignment: .bottom) {
                            Label("Upload to \(browser.cwd)", systemImage: "arrow.up.doc")
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .padding(16)
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }

    /// An alert's isPresented for an optional piece of state: shown while it is
    /// set, cleared when the alert closes.
    private func shown<T>(_ key: ReferenceWritableKeyPath<Browser, T?>) -> Binding<Bool> {
        Binding(get: { browser[keyPath: key] != nil }, set: { if !$0 { browser[keyPath: key] = nil } })
    }
}

/// Uploads files dropped from Finder. Rows dragged out of the list carry
/// `Browser.remoteDragType` and are refused, so they can't come back in as
/// uploads of themselves.
struct UploadDrop: DropDelegate {
    let browser: Browser
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && browser.canReceive
            && !info.itemProviders(for: [.item]).contains { $0.hasItemConformingToTypeIdentifier(Browser.remoteDragType) }
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        var urls: [URL] = []
        let lock = NSLock(), group = DispatchGroup()
        for provider in info.itemProviders(for: [.fileURL]) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        // After the drop returns: the name-clash prompt is modal.
        group.notify(queue: .main) { browser.upload(urls) }
        return true
    }
}

struct FileList: View {
    @Environment(Browser.self) private var model

    var body: some View {
        Group {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't open this folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { model.refresh() }
                }
            } else {
                table
            }
        }
        .overlay {
            if model.error == nil {
                if model.loading && model.entries.isEmpty {
                    ProgressView("Connecting to \(model.host ?? "")…")
                } else if !model.loading && model.entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder",
                                           description: Text("Drag files here from Finder to upload them."))
                } else if model.visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: model.filter)
                }
            }
        }
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: RemoteEntry.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { e in
                let (symbol, color) = Self.icon(for: e)
                Label {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                }
            }
            TableColumn("Size", value: \.size) { e in
                Text(e.isDir ? "—" : e.size.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modified) { e in
                Text(e.modified, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .help(e.modified.formatted(date: .abbreviated, time: .standard))
            }
            .width(min: 110, ideal: 140)
        } rows: {
            ForEach(model.visibleEntries) { e in
                // Dragged to Finder, a row downloads to where it is dropped.
                TableRow(e).itemProvider { model.dragProvider(for: e) }
            }
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            if !ids.isEmpty {
                Button("Download") { model.download(ids) }
                Button("Copy") { model.copy(ids) }
                    .help("Then paste in a folder on any host, in this tab or another")
                Button("Copy Path") { model.copyPaths(ids) }
                Divider()
                Button("Rename…") { model.askRename(ids) }
                    .disabled(ids.count != 1 || !model.canReceive)
                Button("Delete…", role: .destructive) { model.askDelete(ids) }
                    .disabled(!model.canReceive)
            }
            if ids.isEmpty {
                Button("New Folder") { model.askNewFolder() }
                    .disabled(!model.canReceive)
            }
            if let clip = model.store.clipboard {
                Divider()
                Button("Paste \(clip.entries.count) Item\(clip.entries.count == 1 ? "" : "s") from \(clip.host)") { model.paste() }
                    .disabled(!model.canReceive)
            }
        } primaryAction: { ids in
            model.activate(ids)
        }
        .onDeleteCommand { model.askDelete(model.selection) }
    }

    /// A symbol and tint by kind, so text, data, code and archives stand apart.
    static func icon(for e: RemoteEntry) -> (String, Color) {
        if e.isDir { return ("folder.fill", .accentColor) }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "log", "txt", "out", "err", "md": return ("doc.text", .secondary)
        case "json", "jsonl", "yaml", "yml", "toml", "csv", "sqlite": return ("curlybraces.square", .orange)
        case "py", "sh", "cu", "cuh", "cpp", "cc", "c", "h", "hpp", "rs", "go", "js", "ts", "swift", "patch", "diff":
            return ("chevron.left.forwardslash.chevron.right", .teal)
        case "tar", "gz", "tgz", "zip", "xz", "zst", "bz2": return ("archivebox", .brown)
        case "png", "jpg", "jpeg", "svg", "gif", "pdf": return ("photo", .green)
        default: return ("doc", .secondary)
        }
    }
}
