# sshFinder

A small macOS app for browsing files on SSH hosts and moving them around.

- Uses your system `ssh` and `~/.ssh/config`.
- Download, upload (drag and drop), and copy between hosts.
- Open a terminal in the current folder.

Requires macOS 15+ on Apple silicon. Remote hosts need GNU `find`, `stat` and `tar`.

## Install

Download `sshFinder.zip` from [Releases](../../releases), unzip, and move `sshFinder.app` to Applications.

The app isn't notarized, so macOS blocks it the first time: open it once, then click **Open Anyway** in System Settings → Privacy & Security. Or:

```sh
xattr -dr com.apple.quarantine /Applications/sshFinder.app
```

## Build from source

Needs the Xcode Command Line Tools.

```sh
git clone https://github.com/gau-nernst/sshFinder.git
cd sshFinder
./scripts/bundle.sh
open build/sshFinder.app
```

Design notes: [DESIGN.md](DESIGN.md).
