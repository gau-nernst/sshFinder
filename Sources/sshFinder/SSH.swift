import Foundation

struct RemoteEntry: Identifiable, Hashable {
    let path: String  // absolute remote path
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
    var id: String { path }
}

struct SSHError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String
    var timedOut = false

    /// stdout as a number, for commands like `stat -c %s`.
    var number: Int64? { Int64(String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// "/a" + "b" -> "/a/b", and "/" + "b" -> "/b".
func remotePath(_ dir: String, _ name: String) -> String {
    dir == "/" ? "/" + name : dir + "/" + name
}

/// Lets a running transfer be cancelled from the UI thread.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    /// Returns false if cancel() already happened, so the caller must not start.
    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }
}

/// Everything goes through the system ssh, so ~/.ssh/config (ProxyJump, keys,
/// agent) behaves exactly as in the terminal. One ControlMaster connection per
/// host is shared by all commands, so after the first connect each listing is
/// a single round trip.
enum SSH {
    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sshFinder")
    static var askpass: URL { cacheDir.appendingPathComponent("askpass") }

    static var commonOptions: [String] {
        ["-o", "ControlPath=\(cacheDir.path)/%C",
         "-o", "ConnectTimeout=15",
         "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
         // A host's config may set these to start something else; we need a plain shell.
         "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
         "-o", "LogLevel=ERROR"]
    }

    static func setUp() {
        // Writing to an upload's ssh after it exits (cancel, remote error) must
        // fail with EPIPE, not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Passwords, 2FA codes and new host keys are asked through a macOS dialog.
        let script = """
        #!/bin/sh
        case "$1" in
          *yes/no*) hidden="" ;;
          *) hidden="with hidden answer" ;;
        esac
        exec /usr/bin/osascript -e "on run argv" \\
          -e "display dialog (item 1 of argv) default answer \\"\\" $hidden with title \\"sshFinder\\"" \\
          -e "text returned of result" -e "end run" "$1"
        """
        try? script.write(to: askpass, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
    }

    static func isValidHost(_ host: String) -> Bool {
        host.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.@-]*$"#, options: .regularExpression) != nil
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func cdCommand(_ path: String) -> String {
        if path.isEmpty || path == "~" { return "cd" }
        if path.hasPrefix("~/") { return "cd ~/" + quote(String(path.dropFirst(2))) }
        return "cd " + quote(path)
    }

    // MARK: Processes

    static func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// A command over the host's shared connection. ControlMaster=no: a client
    /// that became a master itself would hold our pipes open after exiting.
    static func client(_ host: String, _ command: String) -> Process {
        makeProcess(commonOptions + ["-o", "ControlMaster=no", host, command])
    }

    /// Reads a pipe to the end on another thread (so a full pipe can't block
    /// the process); the returned function waits for it and gives the text.
    static func collect(_ pipe: Pipe) -> () -> String {
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        return { group.wait(); return String(decoding: data, as: UTF8.self) }
    }

    static func failure(_ status: Int32, _ stderr: String) -> SSHError {
        SSHError(message: errorMessage(ProcessResult(status: status, stdout: Data(), stderr: stderr)))
    }

    static func errorMessage(_ r: ProcessResult) -> String {
        let lines = r.stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        return lines.isEmpty ? "ssh exited with status \(r.status)" : lines
    }

    static func run(_ args: [String], timeout: TimeInterval? = nil) async -> ProcessResult {
        await run(makeProcess(args), timeout: timeout)
    }

    private static func run(_ p: Process, timeout: TimeInterval?) async -> ProcessResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    return cont.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: "\(error)"))
                }
                var timedOut = false
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if p.isRunning {
                            timedOut = true
                            p.terminate()
                        }
                    }
                }
                let stderr = collect(err)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let errText = stderr()
                p.waitUntilExit()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: stdout,
                                                     stderr: errText, timedOut: timedOut))
            }
        }
    }

    // MARK: Connection sharing

    private static let gate = MasterGate()

    static func connect(_ host: String) async throws {
        guard isValidHost(host) else { throw SSHError(message: "Invalid host name: \(host)") }
        try await gate.ensure(host)
    }

    /// Start the shared connection explicitly with -f. The backgrounded master
    /// keeps its stderr open, so it goes to a file rather than a pipe we wait on.
    fileprivate static func startMaster(_ host: String) async throws {
        if await run(commonOptions + ["-O", "check", host]).status == 0 { return }
        let (status, stderr): (Int32, String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let log = cacheDir.appendingPathComponent("master-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: log) }
                guard let fh = try? FileHandle(forWritingTo: log) else {
                    return cont.resume(returning: (-1, "cannot write \(log.path)"))
                }
                let p = makeProcess(commonOptions + ["-o", "ControlMaster=yes", "-o", "ControlPersist=15m",
                                                     "-f", "-N", host])
                p.standardOutput = FileHandle.nullDevice
                p.standardError = fh
                do { try p.run() } catch { return cont.resume(returning: (-1, "\(error)")) }
                p.waitUntilExit()
                try? fh.close()
                cont.resume(returning: (p.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? ""))
            }
        }
        if status != 0 { throw failure(status, stderr) }
    }

    /// Run a command on the host over the shared connection.
    static func remote(_ host: String, _ command: String, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await connect(host)
        let r = await run(client(host, command), timeout: timeout)
        if r.timedOut {
            // On a flaky link the shared connection can go stale and hang every
            // command. Drop it so the next action reconnects from scratch.
            _ = await run(commonOptions + ["-O", "exit", host], timeout: 5)
            throw SSHError(message: "No response from \(host) for \(Int(timeout)) s. "
                           + "The connection was reset; try again.")
        }
        return r
    }

    // MARK: Listing

    private static let marker = "__SSHFINDER__"

    static func list(host: String, path: String) async throws -> (cwd: String, entries: [RemoteEntry]) {
        // -L: report the size of what a symlink points to, not the link.
        let r = try await remote(host, "\(cdCommand(path)) && echo \(marker) && pwd && "
            + #"find -L . -mindepth 1 -maxdepth 1 -printf '%Y\t%s\t%T@\t%f\0'"#)
        guard r.status == 0 else { throw SSHError(message: errorMessage(r)) }
        // Skip anything a login script printed before our output.
        guard let m = r.stdout.range(of: Data((marker + "\n").utf8)),
              let nl = r.stdout[m.upperBound...].firstIndex(of: 0x0A) else {
            throw SSHError(message: "Unexpected output from remote host")
        }
        let cwd = String(decoding: r.stdout[m.upperBound..<nl], as: UTF8.self)
        let entries = r.stdout[(nl + 1)...].split(separator: 0).compactMap { record -> RemoteEntry? in
            let f = String(decoding: record, as: UTF8.self)
                .split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4 else { return nil }
            let name = String(f[3])
            return RemoteEntry(path: remotePath(cwd, name), name: name,
                               isDir: f[0] == "d",  // %Y follows symlinks, so links to folders are folders
                               size: Int64(f[1]) ?? 0,
                               modified: Date(timeIntervalSince1970: Double(f[2]) ?? 0))
        }
        return (cwd, entries)
    }

    // MARK: Streaming

    /// Start a command whose stdout the caller reads synchronously, over a
    /// shared connection that `connect` already set up. `finish()` waits for
    /// it and returns its error message, if it failed.
    static func startReading(host: String, command: String) throws
        -> (process: Process, output: FileHandle, finish: () -> String?) {
        let p = client(host, command)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stderr = collect(err)
        return (p, out.fileHandleForReading, {
            p.waitUntilExit()
            let text = stderr()
            return p.terminationStatus == 0 ? nil : errorMessage(ProcessResult(status: p.terminationStatus,
                                                                               stdout: Data(), stderr: text))
        })
    }

    /// Run a command and hand its stdout to `onChunk` as it arrives.
    static func stream(host: String, command: String, cancel: CancelBox,
                       onChunk: @escaping (Data) throws -> Void) async throws {
        try await connect(host)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let p = client(host, command)
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                guard cancel.attach(p) else { return cont.resume(throwing: CancellationError()) }
                do { try p.run() } catch { return cont.resume(throwing: error) }
                let stderr = collect(err)
                var writeError: Error?
                while let chunk = try? out.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
                    do { try onChunk(chunk) } catch {
                        writeError = error
                        p.terminate()
                        break
                    }
                }
                p.waitUntilExit()
                let errText = stderr()
                if cancel.cancelled { return cont.resume(throwing: CancellationError()) }
                if let writeError { return cont.resume(throwing: writeError) }
                if p.terminationStatus != 0 { return cont.resume(throwing: failure(p.terminationStatus, errText)) }
                cont.resume()
            }
        }
    }

    /// Run a command and feed its stdin from `produce`, which is handed a
    /// write function and runs on a background thread.
    static func send(host: String, command: String, cancel: CancelBox,
                     produce: @escaping (_ write: (Data) throws -> Void) throws -> Void) async throws {
        try await connect(host)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let p = client(host, command)
                let input = Pipe(), err = Pipe()
                p.standardInput = input
                p.standardOutput = FileHandle.nullDevice
                p.standardError = err
                guard cancel.attach(p) else { return cont.resume(throwing: CancellationError()) }
                do { try p.run() } catch { return cont.resume(throwing: error) }
                let stderr = collect(err)
                var produceError: Error?
                let writer = input.fileHandleForWriting
                do { try produce { try writer.write(contentsOf: $0) } } catch { produceError = error }
                try? writer.close()
                p.waitUntilExit()
                let errText = stderr()
                if cancel.cancelled { return cont.resume(throwing: CancellationError()) }
                // Our own errors (e.g. the copy source failing) say the most. A
                // remote failure also breaks our writes (EPIPE), and then the
                // remote message says more than the EPIPE does.
                if let produceError = produceError as? SSHError { return cont.resume(throwing: produceError) }
                if p.terminationStatus != 0 { return cont.resume(throwing: failure(p.terminationStatus, errText)) }
                if let produceError { return cont.resume(throwing: produceError) }
                cont.resume()
            }
        }
    }
}

/// Makes concurrent callers share one connection attempt per host, so a 2FA
/// prompt shows up once rather than once per request.
private actor MasterGate {
    private var inFlight: [String: Task<Void, Error>] = [:]

    func ensure(_ host: String) async throws {
        if let t = inFlight[host] { return try await t.value }
        let t = Task { try await SSH.startMaster(host) }
        inFlight[host] = t
        defer { inFlight[host] = nil }
        try await t.value
    }
}
