import AppKit
import Foundation

// Debug entry points, for testing without clicking through the app. See
// "Building and testing" in DESIGN.md.

/// For looking at the UI without Screen Recording permission: with
/// SSHFINDER_SNAPSHOT=<png> set, the app optionally opens a second tab
/// (SSHFINDER_NEWTAB=1), opens SSHFINDER_OPEN (host:/path) in it, and then
/// saves an image of its window. Without SSHFINDER_OPEN it captures the start
/// page, with SSHFINDER_QUERY typed into the connect box if set. Scroll views
/// draw blank in these images, even though they render normally on screen.
@MainActor enum Snapshot {
    private static var started = false

    static func runIfRequested(_ tabs: Tabs) async {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SSHFINDER_SNAPSHOT"], !started else { return }
        started = true
        if env["SSHFINDER_NEWTAB"] == "1" {
            tabs.newTab()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let browser = tabs.selected
        if let loc = env["SSHFINDER_OPEN"] { browser.go(to: loc) }
        if let q = env["SSHFINDER_QUERY"] { browser.hostQuery = q }
        while browser.loading {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // The frame view includes the title bar, which the content view does not.
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    }
}

/// Command-line modes that run the app's own code and exit:
/// - `--smoke <host> <path>` lists a remote folder and downloads everything in
///   it to ~/Downloads; with local paths after `<path>` it uploads them there
///   instead (SSHFINDER_REPLACE=1 overwrites same-named files).
/// - `--relay <from-host> <path> <to-host> <dir>` copies like Paste does.
/// - `--suggest <text>...` prints the connect box suggestions.
/// - `--terminal-command|--terminal-script <host> <folder>` print what the
///   Terminal button would type or run.
/// SSHFINDER_CANCEL_AFTER=<seconds> cancels uploads and copies midway.
enum Smoke {
    static func runIfRequested() {
        let args = CommandLine.arguments
        for flag in ["--terminal-script", "--terminal-command"] {
            guard let i = args.firstIndex(of: flag), i + 2 < args.count else { continue }
            let command = Terminal.command(host: args[i + 1], folder: args[i + 2])
            print(flag == "--terminal-command" ? command : Terminal.script(for: command, iTerm: true))
            exit(0)
        }
        if let i = args.firstIndex(of: "--suggest") {
            MainActor.assumeIsolated {
                let store = Store.shared
                for q in args[(i + 1)...] {
                    print("\"\(q)\" -> pattern: \(store.matchingPattern(q) ?? "-")")
                    for s in store.suggestions(for: q) { print("   \(s.host)  [\(s.detail)]") }
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--relay"), i + 4 < args.count {
            SSH.setUp()
            let from = args[i + 1], path = args[i + 2], to = args[i + 3], dir = args[i + 4]
            Task { @MainActor in
                do {
                    let parent = (path as NSString).deletingLastPathComponent
                    let listing = try await SSH.list(host: from, path: parent)
                    guard let entry = listing.entries.first(where: { $0.path == path }) else {
                        print("error: \(path) not found on \(from)"); exit(1)
                    }
                    let manager = TransferManager()
                    manager.copy(from: from, to: to, dir: dir, items: [(entry, entry.name, false)])
                    try await cancelIfAsked(manager)
                    let start = Date()
                    while manager.items.contains(where: { $0.isActive }) { try await Task.sleep(nanoseconds: 100_000_000) }
                    let t = manager.items[0]
                    print(String(format: "copy %@ %@ -> %@:%@ %lld/%lld in %.1fs", "\(t.status)", path, to, t.remotePath,
                                 t.done, t.total, Date().timeIntervalSince(start)))
                    exit(t.status == .done ? 0 : 1)
                } catch {
                    print("error: \(error.localizedDescription)"); exit(1)
                }
            }
            dispatchMain()
        }
        guard let i = args.firstIndex(of: "--smoke"), i + 2 < args.count else { return }
        let host = args[i + 1], path = args[i + 2]
        let env = ProcessInfo.processInfo.environment
        SSH.setUp()
        Task { @MainActor in
            do {
                let start = Date()
                let r = try await SSH.list(host: host, path: path)
                print(String(format: "listed %@: %d entries in %.2fs", r.cwd, r.entries.count,
                             Date().timeIntervalSince(start)))
                let manager = TransferManager()
                if args.count > i + 3 {
                    // Extra arguments are local paths to upload into <path>, with
                    // numbered names where the listing already has that name.
                    var taken = Set(r.entries.map(\.name))
                    let items = args[(i + 3)...].map { arg -> (url: URL, remoteName: String, replace: Bool) in
                        let url = URL(fileURLWithPath: arg)
                        if env["SSHFINDER_REPLACE"] == "1" { return (url, url.lastPathComponent, true) }
                        let name = numberedName(url.lastPathComponent) { taken.contains($0) }
                        taken.insert(name)
                        return (url, name, false)
                    }
                    manager.upload(host: host, dir: r.cwd, items: items)
                    try await cancelIfAsked(manager)
                } else {
                    manager.download(host: host, entries: r.entries)
                }
                while manager.items.contains(where: { $0.isActive }) {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                for d in manager.items {
                    print("\(d.direction) \(d.status) \(d.remotePath) <-> \(d.localURL?.path ?? "-") \(d.done)/\(d.total)")
                }
                exit(manager.items.allSatisfy { $0.status == .done } ? 0 : 1)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor private static func cancelIfAsked(_ manager: TransferManager) async throws {
        guard let delay = ProcessInfo.processInfo.environment["SSHFINDER_CANCEL_AFTER"].flatMap(Double.init) else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        manager.items.forEach(manager.cancel)
    }
}
