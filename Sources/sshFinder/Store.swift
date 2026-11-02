import Foundation
import Observation

struct HostSuggestion: Hashable {
    let host: String
    let detail: String
    /// A wildcard pattern from ~/.ssh/config; choosing it fills it in for editing.
    let isPattern: Bool
}

/// State shared by every tab: known, saved and recent hosts, and transfers.
@Observable @MainActor final class Store {
    static let shared = Store()

    let configHosts: [String]
    let patterns: [String]
    var recentHosts: [String] { didSet { save() } }
    var savedHosts: [String] { didSet { save() } }
    var lastDir: [String: String] { didSet { save() } }
    let transfers = TransferManager()
    /// Remote items from "Copy", waiting to be pasted in some tab. Not saved.
    var clipboard: (host: String, entries: [RemoteEntry])?

    private init() {
        (configHosts, patterns) = SSHConfig.load()
        let defaults = UserDefaults.standard
        recentHosts = defaults.stringArray(forKey: "recentHosts") ?? []
        savedHosts = defaults.stringArray(forKey: "savedHosts") ?? []
        lastDir = defaults.dictionary(forKey: "lastDir") as? [String: String] ?? [:]
        defaults.removeObject(forKey: "favorites")  // from v0.1, which saved folders
    }

    /// Stored: up to 8 recent hosts, saved hosts, and the last folder of each of
    /// those. Nothing about hosts that drop off both lists is kept.
    private func save() {
        let defaults = UserDefaults.standard
        let kept = Set(recentHosts + savedHosts)
        defaults.set(recentHosts, forKey: "recentHosts")
        defaults.set(savedHosts, forKey: "savedHosts")
        defaults.set(lastDir.filter { kept.contains($0.key) }, forKey: "lastDir")
    }

    var recentUnsaved: [String] { recentHosts.filter { !savedHosts.contains($0) } }

    func toggleSaved(_ h: String) {
        if let i = savedHosts.firstIndex(of: h) { savedHosts.remove(at: i) } else { savedHosts.append(h) }
    }

    func recordVisit(host: String, folder: String) {
        lastDir[host] = folder
        recentHosts = [host] + Array(recentHosts.filter { $0 != host }.prefix(7))
    }

    /// The ssh config pattern a typed host name falls under, if any.
    func matchingPattern(_ name: String) -> String? {
        patterns.first { fnmatch($0, name, 0) == 0 }
    }

    func isKnownHost(_ name: String) -> Bool {
        savedHosts.contains(name) || recentHosts.contains(name) || configHosts.contains(name)
            || matchingPattern(name) != nil
    }

    /// Every typed word must appear in the name, so "app login" finds
    /// "app-login". For a pattern with one `*`, a single word that isn't in it
    /// fills the `*`: with `server-*`, "server 15" suggests server-15.
    func suggestions(for query: String) -> [HostSuggestion] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !query.contains(":") else { return [] }
        var seen = Set<String>(), filled: [HostSuggestion] = [], rest: [HostSuggestion] = []
        func add(_ s: HostSuggestion, to list: inout [HostSuggestion]) {
            if seen.insert(s.host).inserted { list.append(s) }
        }
        func containsAll(_ name: String) -> Bool {
            words.allSatisfy { name.localizedCaseInsensitiveContains($0) }
        }
        for (list, detail) in [(savedHosts, "saved"), (recentHosts, "recent"), (configHosts, "ssh config")] {
            for h in list where containsAll(h) { add(HostSuggestion(host: h, detail: detail, isPattern: false), to: &rest) }
        }
        for p in patterns {
            let missing = words.filter { !p.localizedCaseInsensitiveContains($0) }
            if missing.isEmpty {
                add(HostSuggestion(host: p, detail: "fill in *", isPattern: true), to: &rest)
            } else if missing.count == 1, words.count > 1, p.filter({ $0 == "*" }).count == 1, !p.contains("?") {
                let h = p.replacingOccurrences(of: "*", with: missing[0])
                add(HostSuggestion(host: h, detail: "matches \(p)", isPattern: false), to: &filled)
            }
        }
        return Array((rest.filter { !$0.isPattern } + filled + rest.filter(\.isPattern)).prefix(8))
    }
}
