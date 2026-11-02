import AppKit
import SwiftUI

/// `SSHFINDER_UITEST=connect|browse|all` drives the running app the way a
/// person would, then prints PASS/FAIL lines and exits. Which hosts it uses
/// comes from the environment (see `connect`). It types through the
/// window's first responder (so focus bugs show up) and sends real mouse
/// clicks to `.testTarget` views and file list rows. SwiftUI buttons aren't in
/// the in-process accessibility tree, hence clicks by position, not label.
@MainActor enum UITest {
    static func runIfRequested(_ tabs: Tabs) async {
        guard let scenario = ProcessInfo.processInfo.environment["SSHFINDER_UITEST"] else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Started from a shell while another app is in front, the app can't
        // become active; checks that need a key window say so when they fail.
        print("INFO app active: \(NSApp.isActive), window key: \(window?.isKeyWindow ?? false)")
        switch scenario {
        case "connect": await connect(tabs)
        case "browse": await browse(tabs)
        case "folder": await folder(tabs)
        case "all":
            await connect(tabs)
            await browse(tabs)
            await folder(tabs)
        default: print("FAIL unknown scenario \(scenario)")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Scenarios

    static let box = "Host or alias from ~/.ssh/config"
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// SSHFINDER_UITEST_HOST: a host to connect to. Optionally a wildcard
    /// pattern from ~/.ssh/config (SSHFINDER_UITEST_PATTERN) and the text that
    /// fills its `*` (SSHFINDER_UITEST_FILL) to test pattern suggestions.
    static func connect(_ tabs: Tabs) async {
        let b = tabs.selected
        guard let host = env["SSHFINDER_UITEST_HOST"] else { return check("SSHFINDER_UITEST_HOST is set", false) }
        if window?.isKeyWindow == true {
            check("connect box has focus at launch", focusedField() == box, "focus=\(focusedField() ?? "none")")
        }
        // A short window, so the dropdown makes the page taller than it.
        window?.setContentSize(NSSize(width: 900, height: 520))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("connect box exists", click(field: box))
        await type(String(host.prefix(1)))
        check("connect box keeps focus after the dropdown appears", focusedField() == box,
              "focus=\(focusedField() ?? "none")")
        await type(String(host.dropFirst()))
        check("further typing reaches the box", b.hostQuery == host, "hostQuery=\(b.hostQuery)")

        var target = host
        if let pattern = env["SSHFINDER_UITEST_PATTERN"], let fill = env["SSHFINDER_UITEST_FILL"] {
            // Typing the pattern's literal parts lists it; clicking it puts it in
            // the box with the * selected, and typing replaces the *.
            b.hostQuery = ""
            click(field: box)
            await type(pattern.replacingOccurrences(of: "*", with: " "))
            check("pattern suggestion is clickable", await click("Suggestion \(pattern)"))
            check("pattern fills the box", b.hostQuery == pattern, "hostQuery=\(b.hostQuery)")
            check("box keeps focus after picking a pattern", focusedField() == box, "focus=\(focusedField() ?? "none")")
            await type(fill)
            target = pattern.replacingOccurrences(of: "*", with: fill)
            check("typing replaces the *", b.hostQuery == target, "hostQuery=\(b.hostQuery)")
        }
        await pressReturn()
        check("Return connects", b.host == target, "host=\(b.host ?? "nil")")
        check("listing loads", await wait { !b.loading && b.error == nil && !b.entries.isEmpty }, b.error ?? "")
    }

    /// Path bar, filter, back/up, double-click and tabs, on SSHFINDER_UITEST_HOST.
    static func browse(_ tabs: Tabs) async {
        guard let host = env["SSHFINDER_UITEST_HOST"] else { return check("SSHFINDER_UITEST_HOST is set", false) }
        let b = tabs.selected
        b.open(host: host)
        check("connects", await wait { b.host == host && !b.loading && b.error == nil }, b.error ?? "")

        click(field: "host:/path")
        (window?.firstResponder as? NSTextView)?.selectAll(nil)
        await type("\(host):/tmp")
        await pressReturn()
        check("path bar opens a typed folder", await wait { b.cwd == "/tmp" && !b.loading }, "cwd=\(b.cwd)")
        check("path bar shows host:/path after loading", b.pathInput == "\(host):/tmp", b.pathInput)
        let firstFile = b.visibleEntries.firstIndex { !$0.isDir } ?? b.visibleEntries.count
        check("folders are listed before files", b.visibleEntries[firstFile...].allSatisfy { !$0.isDir },
              "\(b.visibleEntries.filter(\.isDir).count) folders, \(b.visibleEntries.count - firstFile) files")

        // Filter by the start of some name in /tmp.
        let sample = String(b.entries.first { $0.name.count >= 3 }?.name.prefix(3) ?? "")
        click(field: "Filter")
        await type(sample)
        check("filter narrows the list", !b.visibleEntries.isEmpty && b.visibleEntries.allSatisfy { $0.name.localizedCaseInsensitiveContains(sample) },
              "\(b.visibleEntries.count) shown of \(b.entries.count)")
        check("filter keeps focus while the list updates", focusedField() == "Filter", "focus=\(focusedField() ?? "none")")

        check("Enclosing Folder button works", await click("Enclosing folder"))
        check("up goes to /", await wait { b.cwd == "/" && !b.loading }, "cwd=\(b.cwd)")
        check("filter clears on navigation", b.filter.isEmpty, "filter=\(b.filter)")
        check("up selects the folder we came from", b.selection == ["/tmp"], "\(b.selection)")
        check("Back button works", await click("Back"))
        check("back returns to /tmp", await wait { b.cwd == "/tmp" && !b.loading }, "cwd=\(b.cwd)")
        await click("Enclosing folder")
        _ = await wait { b.cwd == "/" && !b.loading }
        try? await Task.sleep(nanoseconds: 500_000_000)  // let the table take the new rows
        await doubleClick(row: "usr", in: b)
        check("double-click opens a folder", await wait { b.cwd == "/usr" && !b.loading }, "cwd=\(b.cwd)")
        await click("Enclosing folder")
        _ = await wait { b.cwd == "/" && !b.loading }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("going up selects the folder", b.selection == ["/usr"], "\(b.selection)")
        await doubleClick(row: "usr", in: b)
        check("double-click opens the selected folder", await wait { b.cwd == "/usr" && !b.loading }, "cwd=\(b.cwd)")
        b.go(to: "\(host):/tmp")
        _ = await wait { b.cwd == "/tmp" && !b.loading }

        check("New tab button works", await click("New tab"))
        check("new tab is selected and shows the start page", tabs.browsers.count == 2 && tabs.selected.host == nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("new tab focuses its connect box", focusedField() == box, "focus=\(focusedField() ?? "none")")
        check("clicking the first tab switches to it", await click("Tab \(host)"))
        check("first tab kept its folder", tabs.selected === b && b.cwd == "/tmp", "cwd=\(b.cwd)")
        await click("Tab New Tab")
        check("close button closes the tab", await click("Close tab New Tab") && tabs.browsers.count == 1,
              "\(tabs.browsers.count) tabs")
        check("remaining tab is selected", tabs.selected === b)
        await click("Close tab \(host)")
        check("closing the last tab leaves a start page", tabs.browsers.count == 1 && tabs.selected.host == nil)
    }

    /// New Folder in SSHFINDER_UITEST_HOST:/tmp, through the button and dialog.
    /// Removes the folder it made.
    static func folder(_ tabs: Tabs) async {
        guard let host = env["SSHFINDER_UITEST_HOST"] else { return check("SSHFINDER_UITEST_HOST is set", false) }
        let b = tabs.selected
        b.go(to: "\(host):/tmp")
        check("opens /tmp", await wait { b.cwd == "/tmp" && !b.loading && b.error == nil }, b.error ?? "")
        let name = "sshFinder-test-\(UUID().uuidString.prefix(6))"

        check("New folder button works", await click("New folder"))
        check("dialog opens with a suggested name", await wait { window?.attachedSheet != nil }
              && (b.newFolderName ?? "").hasPrefix("untitled folder"), "name=\(b.newFolderName ?? "nil")")
        (window?.attachedSheet?.firstResponder as? NSTextView)?.selectAll(nil)
        await type(name)
        check("typing goes into the dialog", b.newFolderName == name, "name=\(b.newFolderName ?? "nil")")
        check("Create button works", pressSheetButton("Create"))
        check("folder appears and is selected", await wait { b.entries.contains { $0.name == name } && b.selection == ["/tmp/\(name)"] },
              "selection=\(b.selection)")

        // The same name again fails with an explanation, and changes nothing.
        await click("New folder")
        _ = await wait { window?.attachedSheet != nil }
        (window?.attachedSheet?.firstResponder as? NSTextView)?.selectAll(nil)
        await type(name)
        pressSheetButton("Create")
        check("an existing name shows an error", await wait { b.failure != nil }, b.failure?.message ?? "")
        check("error is shown in a dialog", await wait { window?.attachedSheet != nil })
        pressSheetButton("OK")
        _ = await wait { window?.attachedSheet == nil }

        // Inside the new folder: a file and a subfolder to rename, drag and delete.
        let dir = "/tmp/\(name)"
        _ = try? await SSH.remote(host, "cd \(SSH.quote(dir)) && printf hello > a.txt && mkdir sub && printf x > sub/b.txt")
        b.go(to: "\(host):\(dir)")
        check("opens the new folder", await wait { b.cwd == dir && !b.loading && b.entries.count == 2 }, "\(b.entries.map(\.name))")

        b.askRename(["\(dir)/a.txt"])
        check("rename dialog opens with the name", await wait { window?.attachedSheet != nil } && b.renameText == "a.txt")
        (window?.attachedSheet?.firstResponder as? NSTextView)?.selectAll(nil)
        await type("b2.txt")
        check("Rename button works", pressSheetButton("Rename"))
        check("renamed item is listed and selected", await wait { b.entries.contains { $0.name == "b2.txt" } && b.selection == ["\(dir)/b2.txt"] },
              "\(b.entries.map(\.name)) selection=\(b.selection)")

        b.askRename(["\(dir)/b2.txt"])
        _ = await wait { window?.attachedSheet != nil }
        (window?.attachedSheet?.firstResponder as? NSTextView)?.selectAll(nil)
        await type("sub")
        pressSheetButton("Rename")
        check("renaming onto an existing name fails", await wait { b.failure != nil }, b.failure?.message ?? "")
        _ = await wait { window?.attachedSheet != nil }
        pressSheetButton("OK")
        _ = await wait { window?.attachedSheet == nil }
        check("nothing was renamed", b.entries.map(\.name).sorted() == ["b2.txt", "sub"], "\(b.entries.map(\.name))")

        // Dragging to Finder: load the rows the way a drop target does.
        if let file = b.entries.first(where: { $0.name == "b2.txt" }) {
            check("dragged file arrives with its contents", await dragged(file, in: b) == "b2.txt: hello")
        }
        if let folder = b.entries.first(where: { $0.name == "sub" }) {
            check("dragged folder arrives with its contents", await dragged(folder, in: b) == "sub: [b.txt]")
        }

        b.askDelete(Set(b.entries.map(\.id)))
        check("delete asks first", await wait { window?.attachedSheet != nil } && b.deleting?.count == 2)
        check("Delete button works", pressSheetButton("Delete"))
        check("deleted items are gone", await wait { !b.loading && b.entries.isEmpty }, "\(b.entries.map(\.name))")

        b.go(to: "\(host):/tmp")
        _ = await wait { b.cwd == "/tmp" && !b.loading }
        b.askDelete(["\(dir)"])
        _ = await wait { window?.attachedSheet != nil }
        pressSheetButton("Delete")
        check("test folder deleted", await wait { !b.loading && !b.entries.contains { $0.name == name } })
    }

    /// Loads a row's drag item like a drop target (e.g. Finder) would, and
    /// describes what arrived: "name: contents" or "name: [files]".
    static func dragged(_ e: RemoteEntry, in b: Browser) async -> String {
        guard let provider = b.dragProvider(for: e),
              let type = provider.registeredTypeIdentifiers.first(where: { $0 != Browser.remoteDragType }) else { return "no provider" }
        return await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { return cont.resume(returning: "error: \(error?.localizedDescription ?? "?")") }
                let fm = FileManager.default
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                let body = isDir.boolValue
                    ? "[" + ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted().joined(separator: ", ") + "]"
                    : ((try? String(contentsOf: url, encoding: .utf8)) ?? "?")
                cont.resume(returning: "\(url.lastPathComponent): \(body)")
            }
        }
    }

    // MARK: Helpers

    /// Clicks a button in the sheet over the window (e.g. an alert's), by title.
    @discardableResult
    static func pressSheetButton(_ title: String) -> Bool {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.title == title { return b }
            for sub in v.subviews { if let b = find(sub) { return b } }
            return nil
        }
        guard let root = window?.attachedSheet?.contentView, let button = find(root) else { return false }
        button.performClick(nil)
        return true
    }

    private static var failures = 0
    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        fflush(stdout)
    }

    /// Placeholder of the text field being edited, or nil if no field has focus.
    static func focusedField() -> String? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return nil }
        return field.placeholderString ?? field.placeholderAttributedString?.string ?? ""
    }

    static func textField(_ placeholder: String) -> NSTextField? {
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, (f.placeholderString ?? f.placeholderAttributedString?.string) == placeholder { return f }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        return window?.contentView?.superview.flatMap(find)
    }

    /// Focuses the text field with this placeholder, as a click would. (A test
    /// run started from a shell is in the background, where a click doesn't
    /// focus a field.)
    @discardableResult
    static func click(field placeholder: String) -> Bool {
        guard let field = textField(placeholder) else { return false }
        return window?.makeFirstResponder(field) ?? false
    }

    /// Types one character at a time into whatever has focus, like a person.
    static func type(_ text: String) async {
        for ch in text {
            if let editor = (window?.attachedSheet ?? window)?.firstResponder as? NSTextView {
                editor.insertText(String(ch), replacementRange: editor.selectedRange())
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static func pressReturn() async {
        ((window?.attachedSheet ?? window)?.firstResponder as? NSTextView)?.insertNewline(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Screen frames of views marked `.testTarget(name)`, in SwiftUI's global
    /// (window, top-left) coordinates. Only recorded during a UI test.
    static var frames: [String: CGRect] = [:]
    static let enabled = ProcessInfo.processInfo.environment["SSHFINDER_UITEST"] != nil

    /// A real click (through hit-testing) at the center of a `.testTarget`.
    @discardableResult
    static func click(_ name: String, count: Int = 1) async -> Bool {
        guard let rect = frames[name], let host = window?.contentView else { return false }
        await mouseClick(at: host.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), count: count)
        return true
    }

    /// Double-clicks the file list row whose name is `name`.
    @discardableResult
    static func doubleClick(row name: String, in b: Browser) async -> Bool {
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for sub in v.subviews { if let t = table(sub) { return t } }
            return nil
        }
        guard let root = window?.contentView, let t = table(root),
              let i = b.visibleEntries.firstIndex(where: { $0.name == name }) else { return false }
        // Middle of the list: a row at the edge auto-scrolls on mouse-down.
        if let scroll = t.enclosingScrollView {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, t.rect(ofRow: i).midY - clip.bounds.height / 2)))
            scroll.reflectScrolledClipView(clip)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let r = t.convert(t.rect(ofRow: i), to: nil)
        await mouseClick(at: NSPoint(x: r.minX + 60, y: r.midY), count: 2)
        return true
    }

    static func mouseClick(at point: NSPoint, count: Int = 1) async {
        guard let w = window else { return }
        func event(_ type: NSEvent.EventType, _ n: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: n, pressure: 1)
        }
        for n in 1...count {
            // Queue the mouse-up first: views like NSTableView track the mouse in
            // a nested loop on mouse-down and wait for the up from the queue.
            if let up = event(.leftMouseUp, n) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, n) { w.sendEvent(down) }
            // Without tracking (e.g. a SwiftUI button) the queued up is delivered here.
            while let next = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.05),
                                             inMode: .default, dequeue: true) {
                w.sendEvent(next)
            }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    static func wait(until condition: () -> Bool, timeout: Double = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return condition()
    }
}

extension View {
    /// Records this view's frame for the UI test mode; does nothing otherwise.
    @ViewBuilder func testTarget(_ name: String) -> some View {
        if UITest.enabled {
            background(GeometryReader { g in
                Color.clear
                    .onAppear { UITest.frames[name] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { UITest.frames[name] = $1 }
                    .onChange(of: name) { UITest.frames[name] = g.frame(in: .global) }
            })
        } else {
            self
        }
    }
}
