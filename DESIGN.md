# sshFinder: design notes

A small macOS app for browsing remote hosts over SSH and moving files to and
from them without remembering commands.

## Decided

- **Transport: the system `ssh`**, never a built-in SSH library. `~/.ssh/config`
  (ProxyJump, per-host keys, agent) then behaves exactly like the terminal.
  - One ControlMaster connection per host (`ControlPersist`), so listing a
    directory after the first connect is a single round trip instead of a
    full SSH handshake.
  - A shared connection can go stale on a flaky link and hang every command.
    Listings time out after 30 s, close the master (`ssh -O exit`), and the
    next action reconnects. `ServerAliveInterval` drops a dead master in ~30 s.
  - Password and 2FA prompts go through `SSH_ASKPASS` as a macOS dialog.
- **Downloads:** files use `ssh host cat` (`tail -c +N` to resume a `.part`
  file), with exact progress. Folders stream as a tar archive and are
  unpacked locally. No rsync: macOS ships `openrsync`, which has weak
  progress output.
- **Uploads:** drag files or folders from Finder onto the list, or use the
  Upload button; they go into the folder the tab shows.
  - Files stream into `cat` on the remote side, folders as a tar archive
    (without macOS `._`/xattr metadata). Both land under a hidden temp name and
    are renamed into place only when complete; a file's size is checked first,
    because a cancelled stream still ends `cat` cleanly. Failures remove the
    temp name.
  - Name clashes ask: Keep Both (numbered name) or Replace. Only a file can
    replace a file; a folder is never replaced or merged.
  - No resume for uploads, and no delete or rename of remote files.
- **Host to host:** right-click → Copy, then Paste (toolbar or right-click on
  empty space) in a folder on any host, in this tab or another. The data
  streams through this Mac (`ssh A cat|tar` → `ssh B`), into the same receive
  commands as uploads, so it gets the same safety and clash handling. Speed is
  bounded by this Mac's network link.
  - Same host also relays: a remote `cp` keeps running after a cancel and
    would still finish, and stopping it cleanly needs a pty and signal traps.
  - A direct copy that skips this Mac needs one host to reach the other.
  - Pasting a folder into itself is refused.
- **Terminal:** the Terminal button opens a new iTerm2 tab (Terminal.app if
  iTerm2 is missing) through AppleScript, typing
  `ssh -t -o RemoteCommand=none <host> 'cd <folder> && exec "$SHELL" -l'`, so
  the tab is a normal session that outlives the app. macOS asks once to allow
  sshFinder to control iTerm2. A built-in terminal (SwiftTerm) was judged not
  worth it next to iTerm2.
- **Hosts:** concrete aliases come from `~/.ssh/config` (following `Include`),
  plus a recently-used list. Wildcard patterns such as `server-*`
  need a real node name typed once; it then stays under Recent.
- **Window and tabs:** one window with app-drawn tabs in the title row
  (`hiddenTitleBar`), always at least one tab, `+` right after the last tab,
  ⌘T for a new tab. Native macOS tabs can't sit in the title row, so they were
  dropped. Below the tabs, one action bar: back, up, the editable `host:/path`,
  filter, refresh, Upload, and Paste when something is copied. A new tab shows
  a start page: a connect box with Saved and Recent hosts. Back from a tab's
  first folder returns to its start page. Saved and recent hosts, the
  clipboard and the Transfers panel are shared by all tabs.
- **Features:**
  - Browse folders, newest first by default, with a filter box.
  - Saved hosts (☆ on a host row) and Recent hosts; each host reopens its
    last folder. Saved folders may come later.
  - The connect box suggests hosts from `~/.ssh/config` while typing. Every
    word must appear in the name; for a pattern with one `*`, a word not in
    it fills the `*` ("server 15" suggests `server-15`).
  - Double-click a folder to open it, a file to download it to `~/Downloads`
    (right-click also offers Download and Copy Path). Transfers show progress,
    cancel, and resume for downloads; Open and Show in Finder when done.
  - A pasted `host:/path` in the path bar opens that folder (or the file's
    folder with the file selected).
- **Stored state, kept minimal:** up to 8 recent hosts, saved hosts, and the
  last folder of each of those (UserDefaults). Clearing an unfinished download
  deletes its `.part` file. Nothing else is kept beyond the askpass script and
  short-lived connection sockets in `~/Library/Caches/sshFinder`.
- **UI: SwiftUI**, macOS 15+, built with SwiftPM and the Command Line Tools
  only (no Xcode project). Less code than Tauri (one layer, no IPC) and native
  table, tabs and drag-and-drop. Finder conventions without copying its
  layout: no dual pane, a `host:/path` bar that accepts pasted paths, newest
  first, no toolbar buttons for things the list already does.
- **Later:** direct host-to-host copy; a "recent files" view across hosts;
  dragging rows out to Finder.

## Known issues

- AppKit logs "reentrant operation in its NSTableView delegate" once per folder
  load. It comes from SwiftUI's `Table` itself (it persists with selection,
  sorting, context menu, dimming, relative dates and search each removed).

## Code map

`Sources/sshFinder/`:

| File | What |
|---|---|
| `App.swift` | App scene and the window's layout |
| `TabBar.swift` | Tab strip in the title row, `BarButton` |
| `Browse.swift` | Action bar, file list, drop-to-upload |
| `StartPage.swift` | Connect box with suggestions, Saved and Recent hosts |
| `TransfersView.swift` | Transfers panel |
| `Browser.swift` | Tabs and per-tab navigation, upload/copy/paste planning |
| `Store.swift` | Shared state: hosts, suggestions, transfers, clipboard |
| `SSH.swift` | Everything that runs `ssh`: shared connections, listing, streaming |
| `SSHConfig.swift` | Host names from `~/.ssh/config` |
| `Transfers.swift` | Download, upload and relay copy |
| `Terminal.swift` | Open iTerm2/Terminal on a host and folder |
| `Debug.swift`, `UITest.swift` | Test entry points below |

## Building and testing

- `scripts/bundle.sh` builds `build/sshFinder.app`, drawing the icon with
  `scripts/make-icon.swift` (no image files in the repo). Launch it with
  `open`: started directly from a shell, the release binary opened no window
  in testing.
- `sshFinder --smoke <host> <path>` lists a folder and downloads everything in
  it to `~/Downloads` through the app's own code, then exits. With local paths
  after `<path>` it uploads them there instead (`SSHFINDER_REPLACE=1`,
  `SSHFINDER_CANCEL_AFTER=<s>` for the replace and cancel paths).
- `sshFinder --relay <from-host> <path> <to-host> <dir>` copies one remote file
  or folder between hosts as Paste does (`SSHFINDER_CANCEL_AFTER=<s>` too).
- `sshFinder --suggest <text>...` prints the connect box suggestions;
  `--terminal-command|--terminal-script <host> <folder>` print what the
  Terminal button would type or run.
- `SSHFINDER_SNAPSHOT=<png>` makes the app save an image of its window (no
  Screen Recording permission needed), optionally after `SSHFINDER_NEWTAB=1`,
  `SSHFINDER_OPEN=<host:/path>` or `SSHFINDER_QUERY=<text>`. Scroll views draw
  blank in these images even though they render normally on screen.
- `SSHFINDER_UITEST=connect|browse|all` drives the app like a person and
  prints PASS/FAIL: it types through the focused field (so focus bugs show)
  and sends real mouse clicks to views marked `.testTarget(name)` and to file
  list rows. It needs `SSHFINDER_UITEST_HOST` (a host whose `/tmp` it
  browses) and optionally `SSHFINDER_UITEST_PATTERN` (a `*` pattern from your
  ssh config) with `SSHFINDER_UITEST_FILL`. Focus and table double-click need
  the window in front, so run it with `open -n --stdout <log> --env
  SSHFINDER_UITEST=all --env SSHFINDER_UITEST_HOST=<host> build/sshFinder.app`
  (it takes focus for ~30 s, and leaves a resized window frame in the app's
  defaults: `defaults delete io.github.gau-nernst.sshFinder "NSWindow Frame main"`).
