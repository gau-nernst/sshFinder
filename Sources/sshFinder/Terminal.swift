import AppKit

/// Opens a terminal tab that SSHes to a host and starts a login shell in a
/// folder: iTerm2 if installed, otherwise Terminal.app.
enum Terminal {
    /// The line typed into the new terminal. RemoteCommand=none because ssh
    /// refuses a command line when the host config sets one; the shell is the
    /// user's own, so the tab stays a normal session after `cd`.
    static func command(host: String, folder: String) -> String {
        let remote = "cd \(SSH.quote(folder)) && exec \"$SHELL\" -l"
        return "ssh -t -o RemoteCommand=none \(SSH.quote(host)) \(SSH.quote(remote))"
    }

    static var hasITerm: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    static func script(for command: String, iTerm: Bool) -> String {
        let text = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        if !iTerm {
            return """
            tell application "Terminal"
                activate
                do script \(text)
            end tell
            """
        }
        // A new tab in the front window, or a new window if there is none.
        return """
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
                tell current session of current window to write text \(text)
            else
                tell current window
                    create tab with default profile
                    tell current session to write text \(text)
                end tell
            end if
        end tell
        """
    }

    static func open(host: String, folder: String) {
        let iTerm = hasITerm
        var error: NSDictionary?
        NSAppleScript(source: script(for: command(host: host, folder: folder), iTerm: iTerm))?
            .executeAndReturnError(&error)
        guard let error else { return }
        let app = iTerm ? "iTerm2" : "Terminal"
        let alert = NSAlert()
        alert.messageText = "Couldn't open \(app)"
        // -1743: the user declined, or hasn't yet allowed, controlling the app.
        alert.informativeText = (error[NSAppleScript.errorNumber] as? Int) == -1743
            ? "Allow sshFinder to control \(app) in System Settings › Privacy & Security › Automation, then try again."
            : (error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        alert.runModal()
    }
}
