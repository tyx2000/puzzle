# Gift — a minimal native Git client

A small AppKit Git client in Swift, grown out of the Puzzle editor and keeping
its look: Ayu Dark throughout, Monaco 12, fully flat. It does Git and nothing
else — no editor, no file tree, no search, no settings.

## Features
- **Projects down the side** — every repository in the window is a row: its
  name, the branch it is on, who commits there, and how many files it has
  changed. Click a row to expand it; click it again to collapse it. Rows are
  dragged into order (with every project collapsed), and ✕ takes one out of the
  window.
- **Changes** — under the expanded row, a one-line commit message with Commit
  (⌘↩) and Push (⇧⌘↩, badged with how many commits are waiting). Changes are
  staged automatically, scoped to the project folder. Click a file to see its
  diff; right-click it to copy its path, reveal it in Finder, or discard it (or
  every change) — confirmed first, with new files going to the Trash.
- **History** — under the changes, one line per commit:
  branch · commit ID · message · author · time ("3 hours ago"). Unpushed
  commits are marked ↑. Click a commit to list its files, and a file to see
  that commit's diff; right-click to copy the ID or message. The list reads 200
  commits at a time and asks for more at the end. The line between the changes
  and the history is dragged, and remembered.
- **Branches** — click the branch on a project row, or beside the traffic
  lights, for the branch menu: switch to a local branch (remote ones in a
  submenu), create one from a chosen base, or delete a merged one.
- **Diffs** — read-only, one tab per file (and per commit), unified or side by
  side, with ↑↓ stepping through changes. A working-tree diff follows the file
  as it changes without losing your place. ⌘C copies the diff as Git wrote it.
- **Live** — FSEvents watch the working tree and `.git`, so edits, commits and
  checkouts made elsewhere show up on their own; coming back to the app
  re-reads every project.

## Build
```bash
./build.sh
```
On first run this clones the Material Icon Theme into `vendor/` (via
`vendor/fetch.sh`) and bundles the file icons the lists use
(`Tools/generate-file-icons.py`). Requires the Xcode command-line tools;
targets macOS 13+.

## Test
```bash
./Tests/run.sh
```

## Install
```bash
./build.sh release        # optimised build
./Tools/install.sh        # copy to /Applications + install the `gift` command
```
`install.sh` falls back to `~/Applications` when `/Applications` is not
writable, and puts `gift` in the first writable directory on your login shell's
PATH. Installing is optional — the app also runs straight out of `build/`.

## Run
```bash
open build/Gift.app                              # pick a repository on launch
open build/Gift.app --args /path/to/repo         # open a repository
gift                                             # open the current directory
```
Ad-hoc signed (not notarized). If Gatekeeper blocks it, right-click → Open, or
`xattr -dr com.apple.quarantine build/Gift.app`.

On first launch, Gift installs or refreshes the bundled `gift` command in the
first writable directory on your login shell's `PATH`. It never overwrites an
unrelated command with the same name.

## Shortcuts
⌘O open · ⌘N new window · ⌘R refresh · ⌘↩ commit · ⇧⌘↩ push ·
⇧⌘] next tab · ⇧⌘[ previous tab · ⌘W close tab · ⇧⌘T reopen closed tab

## Layout
```
Sources/             Swift (theme, window, project rows, Git lists, diffs, GitService)
Tests/               regression suite (Tests/run.sh)
Tools/makeicon.swift masks Tools/appicon.jpg into AppIcon.icns
Tools/gift           the command-line launcher
vendor/              Material Icon Theme (fetched)
build.sh             compiles Swift, builds the icon, bundles icons, signs
```
