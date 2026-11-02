import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct Location: Hashable {
    let host: String
    let path: String
}

/// The window's tabs. There is always at least one.
@Observable @MainActor final class Tabs {
    var browsers: [Browser]
    var selectedID: UUID

    init() {
        let first = Browser()
        browsers = [first]
        selectedID = first.id
    }

    var selected: Browser { browsers.first { $0.id == selectedID } ?? browsers[0] }

    func newTab() {
        let b = Browser()
        browsers.append(b)
        selectedID = b.id
    }

    /// Closing the last tab leaves a fresh start page.
    func close(_ b: Browser) {
        guard let i = browsers.firstIndex(where: { $0.id == b.id }) else { return }
        browsers.remove(at: i)
        if browsers.isEmpty { browsers = [Browser()] }
        if selectedID == b.id { selectedID = browsers[min(i, browsers.count - 1)].id }
    }

    func closeOthers(_ b: Browser) {
        browsers = [b]
        selectedID = b.id
    }
}

/// One tab: either the start page (no host yet) or browsing a host.
@Observable @MainActor final class Browser: Identifiable {
    let id = UUID()
    let store = Store.shared

    var host: String?
    var cwd = ""
    var entries: [RemoteEntry] = []
    var selection = Set<RemoteEntry.ID>()
    var sortOrder = [KeyPathComparator(\RemoteEntry.modified, order: .reverse)]
    var filter = ""
    var pathInput = ""
    var hostQuery = ""
    var loading = false
    var error: String?
    /// Non-nil while the New Folder prompt is up: the name being typed.
    var newFolderName: String?
    /// Non-nil while the Rename prompt is up, with the name being typed.
    var renaming: RemoteEntry?
    var renameText = ""
    /// Non-nil while Delete waits for confirmation.
    var deleting: [RemoteEntry]?
    /// A failed folder operation, shown as an alert.
    var failure: (title: String, message: String)?
    private var backStack: [Location] = []
    private var loadToken = 0

    var visibleEntries: [RemoteEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        // Folders first, each group in the chosen order.
        let sorted = shown.sorted(using: sortOrder)
        return sorted.filter(\.isDir) + sorted.filter { !$0.isDir }
    }

    // Back from the first folder of a tab returns to its start page.
    var canGoBack: Bool { host != nil }
    var canGoUp: Bool { host != nil && !cwd.isEmpty && cwd != "/" }

    // MARK: Navigation

    func open(host h: String) {
        navigate(Location(host: h, path: store.lastDir[h] ?? ""))
    }

    func navigate(_ loc: Location, select name: String? = nil) {
        if let host, !cwd.isEmpty { backStack.append(Location(host: host, path: cwd)) }
        load(loc, select: name)
    }

    func goBack() {
        if let loc = backStack.popLast() { return load(loc) }
        showStartPage()
    }

    func showStartPage() {
        loadToken += 1
        host = nil
        cwd = ""
        entries = []
        selection = []
        filter = ""
        error = nil
        loading = false
    }

    func goUp() {
        guard let host, canGoUp else { return }
        let parent = (cwd as NSString).deletingLastPathComponent
        navigate(Location(host: host, path: parent.isEmpty ? "/" : parent),
                 select: (cwd as NSString).lastPathComponent)
    }

    func refresh(select name: String? = nil) {
        guard let host else { return }
        load(Location(host: host, path: cwd), select: name)
    }

    /// Accepts "host:/path", "host", or a path on the current host.
    func go(to text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let colon = text.firstIndex(of: ":") {
            let h = String(text[..<colon])
            if !h.contains("/") && SSH.isValidHost(h) {
                return navigate(Location(host: h, path: String(text[text.index(after: colon)...])))
            }
        }
        if let host, text.hasPrefix("/") || text.hasPrefix("~") {
            return navigate(Location(host: host, path: text))
        }
        if SSH.isValidHost(text) { open(host: text) }
    }

    /// Return in the connect field: connect if the text is already a usable
    /// host, otherwise take the top suggestion. Returns a pattern for the view
    /// to fill in, since it owns the text selection.
    func submitHostQuery() -> String? {
        let q = hostQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if q.contains(":") || store.isKnownHost(q) {
            go(to: q)
        } else if let top = store.suggestions(for: q).first {
            if top.isPattern { return top.host }
            open(host: top.host)
        } else {
            go(to: q)
        }
        hostQuery = ""
        return nil
    }

    private func load(_ loc: Location, select name: String? = nil) {
        loadToken += 1
        let token = loadToken
        if host != loc.host { entries = [] }
        host = loc.host
        pathInput = "\(loc.host):\(loc.path)"
        loading = true
        error = nil
        Task {
            do {
                var result: (cwd: String, entries: [RemoteEntry])
                var selectName = name
                do {
                    result = try await SSH.list(host: loc.host, path: loc.path)
                } catch let e where !loc.path.isEmpty && loc.path != "/" {
                    // A pasted path may point at a file: open its folder with the file selected.
                    let parent = (loc.path as NSString).deletingLastPathComponent
                    let file = (loc.path as NSString).lastPathComponent
                    guard let r = try? await SSH.list(host: loc.host, path: parent.isEmpty ? "/" : parent),
                          r.entries.contains(where: { $0.name == file }) else { throw e }
                    result = r
                    selectName = file
                }
                guard token == loadToken else { return }
                cwd = result.cwd
                entries = result.entries
                filter = ""
                selection = selectName.map { [remotePath(result.cwd, $0)] } ?? []
                pathInput = "\(loc.host):\(result.cwd)"
                store.recordVisit(host: loc.host, folder: result.cwd)
            } catch {
                guard token == loadToken else { return }
                self.error = error.localizedDescription
                entries = []
            }
            loading = false
        }
    }

    // MARK: Actions

    func activate(_ ids: Set<RemoteEntry.ID>) {
        let chosen = entries.filter { ids.contains($0.id) }
        if chosen.count == 1, let e = chosen.first, e.isDir, let host {
            navigate(Location(host: host, path: e.path))
        } else {
            download(ids)
        }
    }

    func download(_ ids: Set<RemoteEntry.ID>) {
        guard let host else { return }
        store.transfers.download(host: host, entries: entries.filter { ids.contains($0.id) })
    }

    /// Upload local files and folders into the folder this tab shows.
    func upload(_ urls: [URL]) {
        guard let host, canReceive, !urls.isEmpty else { return }
        let incoming = urls.map { url -> (name: String, isDir: Bool) in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return (url.lastPathComponent, isDir.boolValue)
        }
        guard let names = planNames(incoming) else { return }
        store.transfers.upload(host: host, dir: cwd, items: zip(urls, names).map { ($0, $1.remoteName, $1.replace) })
    }

    func copy(_ ids: Set<RemoteEntry.ID>) {
        guard let host else { return }
        let chosen = entries.filter { ids.contains($0.id) }
        if !chosen.isEmpty { store.clipboard = (host, chosen) }
    }

    /// Paste copied remote items into the folder this tab shows. Between hosts
    /// the data streams through this Mac.
    func paste() {
        guard let host, canReceive, let clip = store.clipboard else { return }
        if clip.host == host, let folder = clip.entries.first(where: { $0.isDir && (cwd == $0.path || cwd.hasPrefix($0.path + "/")) }) {
            let alert = NSAlert()
            alert.messageText = "Can't paste “\(folder.name)” into itself"
            alert.informativeText = "Open a folder outside \(folder.path) and paste there."
            alert.runModal()
            return
        }
        guard let names = planNames(clip.entries.map { ($0.name, $0.isDir) }) else { return }
        store.transfers.copy(from: clip.host, to: host, dir: cwd,
                             items: zip(clip.entries, names).map { ($0, $1.remoteName, $1.replace) })
    }

    var canReceive: Bool { host != nil && !cwd.isEmpty && error == nil }

    /// Names for items arriving in this folder. Name clashes ask first: Keep
    /// Both picks a numbered name; Replace applies only where a file replaces a
    /// file. Returns nil if cancelled.
    private func planNames(_ incoming: [(name: String, isDir: Bool)]) -> [(remoteName: String, replace: Bool)]? {
        let existing = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let clashes = incoming.filter { existing[$0.name] != nil }
        var replace = false
        if !clashes.isEmpty {
            let alert = NSAlert()
            alert.messageText = clashes.count == 1
                ? "“\(clashes[0].name)” already exists in \(cwd)"
                : "\(clashes.count) items already exist in \(cwd)"
            alert.informativeText = "Keep Both uses a new name like “name (1)”. "
                + "Replace overwrites existing files; folders are never replaced."
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: replace = false
            case .alertSecondButtonReturn: replace = true
            default: return nil
            }
        }
        var taken = Set(existing.keys)
        return incoming.map { item in
            if let old = existing[item.name], replace, !old.isDir, !item.isDir {
                return (item.name, true)
            }
            let picked = numberedName(item.name) { taken.contains($0) }
            taken.insert(picked)
            return (picked, false)
        }
    }

    // MARK: Changing the folder

    func askNewFolder() {
        guard canReceive else { return }
        newFolderName = numberedName("untitled folder") { name in entries.contains { $0.name == name } }
    }

    /// Makes a folder here, then selects it. `mkdir` without -p, so an existing
    /// name fails instead of being reused.
    func createFolder(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard isValidName(name, for: "Couldn't create the folder") else { return }
        await runHere("mkdir -- \(SSH.quote(name))", failing: "Couldn't create the folder", select: name)
    }

    func askRename(_ ids: Set<RemoteEntry.ID>) {
        guard canReceive, ids.count == 1, let e = entries.first(where: { ids.contains($0.id) }) else { return }
        renameText = e.name
        renaming = e
    }

    /// Renames within this folder, refusing a name that already exists rather
    /// than letting `mv` replace it (or move into it, for a folder).
    func rename(_ e: RemoteEntry, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard name != e.name, isValidName(name, for: "Couldn't rename") else { return }
        let new = SSH.quote(name)
        await runHere("if [ -e \(new) ] || [ -L \(new) ]; then printf '%s already exists\\n' \(new) >&2; exit 1; fi"
                      + " && mv -- \(SSH.quote(e.name)) \(new)", failing: "Couldn't rename", select: name)
    }

    func askDelete(_ ids: Set<RemoteEntry.ID>) {
        guard canReceive else { return }
        let chosen = entries.filter { ids.contains($0.id) }
        if !chosen.isEmpty { deleting = chosen }
    }

    /// Deletes entries of this folder, folders with everything in them. Only
    /// names listed here: never this folder itself or anything above it.
    func delete(_ items: [RemoteEntry]) async {
        let names = items.map(\.name).filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }
        guard !names.isEmpty else { return }
        await runHere("rm -rf -- " + names.map(SSH.quote).joined(separator: " "),
                      failing: "Couldn't delete", timeout: 3600)
    }

    private func isValidName(_ name: String, for title: String) -> Bool {
        guard name.isEmpty || name == "." || name == ".." || name.contains("/") else { return true }
        failure = (title, "A name can't be empty, “.”, “..”, or contain “/”.")
        return false
    }

    /// Runs a command in the folder this tab shows, then refreshes it if the
    /// tab is still there, selecting `select`.
    private func runHere(_ command: String, failing title: String, select: String? = nil,
                         timeout: TimeInterval = 30) async {
        guard let host, canReceive else { return }
        let dir = cwd
        loading = true
        defer { if self.host == host && cwd == dir { refresh(select: select) } }
        do {
            let r = try await SSH.remote(host, "cd \(SSH.quote(dir)) && \(command)", timeout: timeout)
            if r.status != 0 { failure = (title, SSH.errorMessage(r)) }
        } catch {
            failure = (title, error.localizedDescription)
        }
    }

    /// Marks drags that start in the list, so the list refuses them as uploads.
    nonisolated static let remoteDragType = "io.github.gau-nernst.sshFinder.remote-item"

    /// What a row offers when dragged: the file (or folder) itself, downloaded
    /// only once it is dropped somewhere that wants it, like Finder.
    func dragProvider(for e: RemoteEntry) -> NSItemProvider? {
        guard let host else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = e.name
        let type = e.isDir ? UTType.folder : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)
        let transfers = store.transfers
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                do { done(try await transfers.downloadForDrag(host: host, entry: e), false, nil) }
                catch { done(nil, false, error) }
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: Self.remoteDragType, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return provider
    }

    func copyPaths(_ ids: Set<RemoteEntry.ID>) {
        guard let host else { return }
        let text = entries.filter { ids.contains($0.id) }.map { "\(host):\($0.path)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
