import Foundation
import Observation

extension Notification.Name {
    /// Posted after an upload or copy lands, with "host" and "dir" in userInfo,
    /// so tabs showing that folder can refresh.
    static let remoteFolderChanged = Notification.Name("sshFinderRemoteFolderChanged")
}

/// Changed on the main thread only (progress hops there), hence the unchecked
/// Sendable for the background reporters that hold it.
@Observable final class Transfer: Identifiable, @unchecked Sendable {
    /// copy: remote to remote, streamed through this Mac (also within one host:
    /// a remote `cp` would keep running after a cancel and still finish).
    enum Direction { case download, upload, copy }
    enum Status: Equatable {
        case queued, running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let direction: Direction
    let host: String
    /// Download: the remote source. Upload and copy: the remote destination.
    let remotePath: String
    let isDir: Bool
    /// Upload and copy: overwrite an existing remote file of the same name.
    let replace: Bool
    /// Copy only: where it comes from.
    let source: (host: String, path: String)?
    var status: Status = .queued
    var total: Int64 = 0
    var done: Int64 = 0
    var bytesPerSecond: Double = 0
    /// Download: the local destination, picked when it starts. Upload: the source.
    var localURL: URL?
    /// Download only: the folder to download into, instead of ~/Downloads.
    var destination: URL?
    /// Called once when it finishes, with where it landed or why it failed.
    var onFinish: ((Result<URL, Error>) -> Void)?
    var note: String?
    fileprivate var cancelBox = CancelBox()

    var name: String { (remotePath as NSString).lastPathComponent }
    var remoteDir: String { (remotePath as NSString).deletingLastPathComponent }
    var isActive: Bool { status == .queued || status == .running }

    init(_ direction: Direction, host: String, remotePath: String, isDir: Bool,
         localURL: URL? = nil, replace: Bool = false, source: (host: String, path: String)? = nil) {
        self.direction = direction
        self.host = host
        self.remotePath = remotePath
        self.isDir = isDir
        self.localURL = localURL
        self.replace = replace
        self.source = source
    }
}

/// "report.txt" -> "report (1).txt", the first numbered name not taken.
func numberedName(_ name: String, isTaken: (String) -> Bool) -> String {
    let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
    var candidate = name, n = 1
    while isTaken(candidate) {
        candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
        n += 1
    }
    return candidate
}

@Observable @MainActor final class TransferManager {
    var items: [Transfer] = []
    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private let maxConcurrent = 3
    private var reserved = Set<String>()

    func download(host: String, entries: [RemoteEntry]) {
        for e in entries {
            items.insert(Transfer(.download, host: host, remotePath: e.path, isDir: e.isDir), at: 0)
        }
        pump()
    }

    /// `items` pairs each local file or folder with its remote name in `dir`.
    func upload(host: String, dir: String, items new: [(url: URL, remoteName: String, replace: Bool)]) {
        for item in new {
            let path = remotePath(dir, item.remoteName)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.url.path, isDirectory: &isDir)
            items.insert(Transfer(.upload, host: host, remotePath: path, isDir: isDir.boolValue,
                                  localURL: item.url, replace: item.replace), at: 0)
        }
        pump()
    }

    /// Copy remote entries from `fromHost` into `dir` on `host`; `items` pairs
    /// each entry with its name at the destination.
    func copy(from fromHost: String, to host: String, dir: String,
              items new: [(entry: RemoteEntry, remoteName: String, replace: Bool)]) {
        for item in new {
            let path = remotePath(dir, item.remoteName)
            items.insert(Transfer(.copy, host: host, remotePath: path, isDir: item.entry.isDir,
                                  replace: item.replace, source: (fromHost, item.entry.path)), at: 0)
        }
        pump()
    }

    /// Downloads into a fresh temp folder for a drag to Finder, which copies
    /// the result to where it was dropped. Shows in the list like any download.
    func downloadForDrag(host: String, entry: RemoteEntry) async throws -> URL {
        let dir = Self.dragFolder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Transfer(.download, host: host, remotePath: entry.path, isDir: entry.isDir)
        t.destination = dir
        items.insert(t, at: 0)
        return try await withCheckedThrowingContinuation { cont in
            t.onFinish = { cont.resume(with: $0) }
            pump()
        }
    }

    /// Where drag downloads wait for Finder to copy them; emptied at launch.
    static let dragFolder = SSH.cacheDir.appendingPathComponent("drag")

    func cancel(_ t: Transfer) {
        if t.status == .queued {
            t.status = .cancelled
            finish(t, .failure(CancellationError()))
        }
        t.cancelBox.cancel()
    }

    private func finish(_ t: Transfer, _ result: Result<URL, Error>) {
        t.onFinish?(result)
        t.onFinish = nil
    }

    func retry(_ t: Transfer) {
        t.cancelBox = CancelBox()
        t.status = .queued
        t.note = nil
        pump()
    }

    /// Also deletes the .part file of any download that didn't finish: once the
    /// row is gone there is no Resume button, so it would just be clutter.
    func clearFinished() {
        for t in items where t.direction == .download && !t.isActive && t.status != .done {
            if let url = t.localURL { try? FileManager.default.removeItem(at: url.appendingPathExtension("part")) }
        }
        items.removeAll { !$0.isActive }
    }

    private func pump() {
        var running = items.filter { $0.status == .running }.count
        for t in items.reversed() where t.status == .queued && running < maxConcurrent {
            running += 1
            t.status = .running
            t.done = 0
            t.bytesPerSecond = 0
            Task {
                do {
                    switch (t.direction, t.isDir) {
                    case (.download, false): try await downloadFile(t)
                    case (.download, true): try await downloadFolder(t)
                    case (.upload, false): try await uploadFile(t)
                    case (.upload, true): try await uploadFolder(t)
                    case (.copy, false): try await relayFile(t)
                    case (.copy, true): try await relayFolder(t)
                    }
                    t.status = .done
                    if let url = t.localURL { finish(t, .success(url)) }
                    if t.direction != .download {
                        NotificationCenter.default.post(name: .remoteFolderChanged, object: nil,
                                                        userInfo: ["host": t.host, "dir": t.remoteDir])
                    }
                } catch is CancellationError {
                    t.status = .cancelled
                    finish(t, .failure(CancellationError()))
                } catch {
                    t.status = .failed(error.localizedDescription)
                    finish(t, .failure(error))
                }
                if t.direction == .download, let url = t.localURL { reserved.remove(url.path) }
                pump()
            }
        }
    }

    // MARK: Downloads

    /// A free name in `dir`, also avoiding names other downloads have taken.
    private func reserveName(_ name: String, in dir: URL) -> URL {
        let picked = numberedName(name) {
            let path = dir.appendingPathComponent($0).path
            return FileManager.default.fileExists(atPath: path) || reserved.contains(path)
        }
        let url = dir.appendingPathComponent(picked)
        reserved.insert(url.path)
        return url
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Streams `cat` into a .part file; an interrupted download resumes from
    /// where the .part file ends.
    private func downloadFile(_ t: Transfer) async throws {
        let q = SSH.quote(t.remotePath)
        let stat = try await SSH.remote(t.host, "stat -Lc %s \(q)")
        guard stat.status == 0, let total = stat.number else { throw SSHError(message: SSH.errorMessage(stat)) }
        t.total = total

        let dest: URL
        if let previous = t.localURL {
            // A retry keeps its name so it picks up its own .part file.
            dest = previous
            reserved.insert(dest.path)
        } else {
            let existing = folder.appendingPathComponent(t.name)
            if t.destination == nil, fileSize(existing) == total {
                t.localURL = existing
                t.done = total
                t.note = "Already in Downloads"
                return
            }
            dest = reserveName(t.name, in: t.destination ?? folder)
            t.localURL = dest
        }

        let part = dest.appendingPathExtension("part")
        var offset = fileSize(part) ?? 0
        if offset > total {
            try? FileManager.default.removeItem(at: part)
            offset = 0
        }
        if offset == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let out = try FileHandle(forWritingTo: part)
        defer { try? out.close() }
        try out.seekToEnd()

        t.done = offset
        let command = offset > 0 ? "tail -c +\(offset + 1) \(q)" : "cat \(q)"
        let progress = progressReporter(t, start: offset)
        try await SSH.stream(host: t.host, command: command, cancel: t.cancelBox) { chunk in
            try out.write(contentsOf: chunk)
            progress(chunk.count)
        }
        try out.close()

        let got = fileSize(part) ?? 0
        guard got == total else {
            throw SSHError(message: "Got \(got) of \(total) bytes. Is the file still being written?")
        }
        try FileManager.default.moveItem(at: part, to: dest)
        t.done = total
    }

    /// Streams `tar` from the remote side into a local `tar -x`, in a hidden
    /// temp folder that is renamed once complete. No resume for folders.
    private func downloadFolder(_ t: Transfer) async throws {
        let q = SSH.quote(t.remotePath)
        t.total = (try? await SSH.remote(t.host, Self.tarSizeCommand(t.remotePath), timeout: 60))?.number ?? 0

        let base = t.destination ?? folder
        let dest = reserveName(t.name, in: base)
        t.localURL = dest
        let tmp = base.appendingPathComponent(".\(t.name).sshFinder-\(t.id.uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let tar = Self.localTar(["-xf", "-", "-C", tmp.path])
        let input = Pipe()
        tar.standardInput = input
        do {
            try tar.run()
            let writer = input.fileHandleForWriting
            let progress = progressReporter(t, start: 0)
            try await SSH.stream(host: t.host, command: "cd \(q) && tar -cf - .", cancel: t.cancelBox) { chunk in
                try writer.write(contentsOf: chunk)
                progress(chunk.count)
            }
            try writer.close()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw SSHError(message: "Unpacking failed (tar exited \(tar.terminationStatus))") }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            if tar.isRunning { tar.terminate() }
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        t.total = max(t.done, t.total)
        t.done = t.total
    }

    // MARK: Uploads
    //
    // Both kinds write to a hidden temp name in the destination folder and only
    // rename it into place once complete, so a cancelled or broken upload never
    // leaves a truncated file under the real name. The remote side cleans up
    // the temp name on failure.

    private static let incomplete = "echo 'Incomplete, or the name was taken meanwhile. Nothing was changed.' >&2; exit 1"

    /// Remote side of receiving one file on stdin. A cancelled stream still
    /// ends `cat` cleanly, so the size check is what keeps a partial file from
    /// being renamed into place.
    private func receiveFileCommand(_ t: Transfer, size: Int64) -> String {
        let tmp = SSH.quote(".\(t.name).sshFinder-\(t.id.uuidString.prefix(8)).part")
        let name = SSH.quote(t.name)
        let keepExisting = t.replace ? "" : "[ ! -e \(name) ] && "
        return "cd \(SSH.quote(t.remoteDir)) && cat > \(tmp)"
            + " && [ \"$(stat -c %s \(tmp))\" = \(size) ] && \(keepExisting)mv -f \(tmp) \(name)"
            + " || { rm -f \(tmp); \(Self.incomplete); }"
    }

    /// Remote side of receiving a tar archive whose single top-level entry is
    /// `archivedName`; it is unpacked into a temp folder and moved into place.
    private func receiveFolderCommand(_ t: Transfer, archivedName: String) -> String {
        let tmp = SSH.quote(".sshFinder-upload-\(t.id.uuidString.prefix(8))")
        return "cd \(SSH.quote(t.remoteDir)) && mkdir \(tmp) && { tar -xf - -C \(tmp)"
            + " && mv -T \(tmp)/\(SSH.quote(archivedName)) \(SSH.quote(t.name)) && rmdir \(tmp)"
            + " || { rm -rf \(tmp); \(Self.incomplete); }; }"
    }

    private func uploadFile(_ t: Transfer) async throws {
        guard let src = t.localURL else { return }
        let total = fileSize(src) ?? 0
        t.total = total
        let command = receiveFileCommand(t, size: total)

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let progress = progressReporter(t, start: 0)
        try await SSH.send(host: t.host, command: command, cancel: t.cancelBox) { write in
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try write(chunk)
                progress(chunk.count)
            }
        }
        t.done = total
    }

    private func uploadFolder(_ t: Transfer) async throws {
        guard let src = t.localURL else { return }
        t.total = Self.tarSize(of: src)
        let command = receiveFolderCommand(t, archivedName: src.lastPathComponent)

        // No macOS metadata: no ._ files or xattr headers for Linux tar to trip on.
        let tar = Self.localTar(["-cf", "-", "--no-xattrs", "--no-mac-metadata",
                                 "-C", src.deletingLastPathComponent().path, src.lastPathComponent])
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let output = Pipe()
        tar.standardOutput = output
        try tar.run()
        defer { if tar.isRunning { tar.terminate() } }

        let progress = progressReporter(t, start: 0)
        try await SSH.send(host: t.host, command: command, cancel: t.cancelBox) { write in
            let reader = output.fileHandleForReading
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try write(chunk)
                progress(chunk.count)
            }
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw SSHError(message: "Reading the local folder failed (tar exited \(tar.terminationStatus))")
            }
        }
        t.total = max(t.done, t.total)
        t.done = t.total
    }

    // MARK: Copies between hosts
    //
    // The source streams through this Mac into the same receive commands as
    // uploads, so the destination gets the same temp-name-then-rename safety.

    private func relayFile(_ t: Transfer) async throws {
        guard let (from, path) = t.source else { return }
        let stat = try await SSH.remote(from, "stat -Lc %s \(SSH.quote(path))")
        guard stat.status == 0, let total = stat.number else { throw SSHError(message: "\(from): " + SSH.errorMessage(stat)) }
        t.total = total
        try await relay(t, from: from, sourceCommand: "cat \(SSH.quote(path))",
                        destCommand: receiveFileCommand(t, size: total))
        t.done = total
    }

    private func relayFolder(_ t: Transfer) async throws {
        guard let (from, path) = t.source else { return }
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        t.total = try await SSH.remote(from, Self.tarSizeCommand(path), timeout: 60).number ?? 0
        try await relay(t, from: from,
                        sourceCommand: "tar -cf - -C \(SSH.quote(parent.isEmpty ? "/" : parent)) \(SSH.quote(name))",
                        destCommand: receiveFolderCommand(t, archivedName: name))
        t.total = max(t.done, t.total)
        t.done = t.total
    }

    private func relay(_ t: Transfer, from: String, sourceCommand: String, destCommand: String) async throws {
        try await SSH.connect(from)
        let progress = progressReporter(t, start: 0)
        try await SSH.send(host: t.host, command: destCommand, cancel: t.cancelBox) { write in
            let source = try SSH.startReading(host: from, command: sourceCommand)
            defer { if source.process.isRunning { source.process.terminate() } }
            while let chunk = try source.output.read(upToCount: 1 << 20), !chunk.isEmpty {
                try write(chunk)
                progress(chunk.count)
            }
            if let message = source.finish() { throw SSHError(message: "\(from): \(message)") }
        }
    }

    private static func localTar(_ args: [String]) -> Process {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = args
        tar.standardError = FileHandle.nullDevice
        return tar
    }

    /// Remote command printing the expected tar stream size of a folder, for the
    /// progress bar: a 512-byte header per entry, file data padded to 512, a
    /// 1024-byte trailer, rounded up to GNU tar's 10240-byte records.
    private static func tarSizeCommand(_ path: String) -> String {
        "cd \(SSH.quote(path)) && find . -printf '%y %s\\n' 2>/dev/null | awk "
            + #"'{ t += 512; if ($1 == "f") t += int(($2 + 511) / 512) * 512 } "#
            + #"END { t += 1024; print int((t + 10239) / 10240) * 10240 }'"#
    }

    /// Expected size of a tar stream of `url`: a 512-byte header per entry, file
    /// data padded to 512, a 1024-byte trailer, rounded up to 10240-byte records.
    private nonisolated static func tarSize(of url: URL) -> Int64 {
        var total: Int64 = 512
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let item as URL in walk {
            total += 512
            if let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += (Int64(v.fileSize ?? 0) + 511) / 512 * 512
            }
        }
        return (total + 1024 + 10239) / 10240 * 10240
    }

    /// Progress and speed reach the UI a few times a second, not on every chunk.
    private nonisolated func progressReporter(_ t: Transfer, start: Int64) -> (Int) -> Void {
        var done = start
        var lastTime = Date(), lastBytes = start
        return { count in
            done += Int64(count)
            let now = Date(), dt = now.timeIntervalSince(lastTime)
            if dt >= 0.3 {
                let rate = Double(done - lastBytes) / dt
                let value = done
                lastTime = now
                lastBytes = done
                DispatchQueue.main.async {
                    t.done = value
                    t.bytesPerSecond = rate
                }
            }
        }
    }
}
