import Foundation

/// Host names from ~/.ssh/config (following Include). Concrete aliases can be
/// listed directly; wildcard patterns need a real name typed in.
enum SSHConfig {
    static func load() -> (hosts: [String], patterns: [String]) {
        var hosts: [String] = [], patterns: [String] = [], seen = Set<String>()
        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath

        func read(_ path: String, depth: Int) {
            guard depth < 8, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                guard parts.count == 2 else { continue }
                var values: [String] = []
                for v in parts[1].split(whereSeparator: \.isWhitespace) {
                    if v.hasPrefix("#") { break }
                    values.append(v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
                switch parts[0].lowercased() {
                case "include":
                    for v in values {
                        var pattern = NSString(string: v).expandingTildeInPath
                        if !pattern.hasPrefix("/") { pattern = sshDir + "/" + pattern }
                        for p in expandGlob(pattern) { read(p, depth: depth + 1) }
                    }
                case "host":
                    for v in values where v != "*" && !v.hasPrefix("!") && seen.insert(v).inserted {
                        if v.contains("*") || v.contains("?") { patterns.append(v) } else { hosts.append(v) }
                    }
                default:
                    break
                }
            }
        }

        read(sshDir + "/config", depth: 0)
        return (hosts, patterns)
    }

    private static func expandGlob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }
}
