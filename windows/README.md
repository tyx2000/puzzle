# Gift for Windows

A native Windows port of Gift — C++20, Win32, Direct2D and DirectWrite, no
framework and no runtime to install. One `Gift.exe` (about 1.6 MB), the
Material file icons beside it, and the `gift` command.

It is the macOS app feature for feature: the same Ayu Dark palette, the same
layout, the same Git behaviour, with each Mac service mapped to its Windows
counterpart.

## What it does
- **Projects down the side** — a row per repository: name, branch, who
  commits there, and a badge with how many files changed. Click to expand,
  click again to collapse; drag rows to reorder (with every project
  collapsed); ✕ takes one out of the window. The Git mark on a row pulls
  (fast-forward only), and a band of light runs down it while a fetch or pull
  is going.
- **Changes** — a one-line commit message with Commit (Ctrl+Enter) and Push
  (Ctrl+Shift+Enter, badged with the commits waiting). Changes are staged
  automatically. Click a file for its diff; right-click to copy its path, show
  it in Explorer, or discard it (or every change) — confirmed first, new files
  going to the Recycle Bin.
- **History** — one line per commit: graph · refs · commit ID · message ·
  author · time, with the coloured lane graph, ref pills, ↑ on unpushed
  commits, 200 commits a page, and a commit's files under it when opened. The
  line between changes and history is dragged, and remembered.
- **Branches** — click the branch in the title band: switch (remote branches in
  a submenu), create from a chosen base, or delete a merged one.
- **Terminal** — `>_` opens the project in Windows Terminal (a new window), or
  PowerShell / the Command Prompt without it.
- **Diffs** — read-only tabs, unified or side by side, ↑↓ through the changes,
  Ctrl+C copies the diff as Git wrote it, 50,000-line model budget, bodies
  released under memory pressure and read again from Git.
- **Live** — ReadDirectoryChangesW watches the working tree and `.git`;
  switching back to the app re-reads every project; a project coming on screen
  is fetched in the background.

## Mac → Windows
| macOS | Windows |
|---|---|
| traffic lights, full-size titlebar | caption buttons drawn at the top-right, the band still drags the window |
| menu bar | the ≡ button at the top-left (File, Edit, View, Window, Help) |
| ⌘ shortcuts | Ctrl (Ctrl+Tab / Ctrl+PageDown also step tabs, F5 refreshes) |
| Dock menu of recent projects | taskbar jump list (ten newest) |
| Finder “Open With” on folders | “Open in Gift” on folders in Explorer |
| Trash | Recycle Bin |
| iTerm / Terminal | Windows Terminal / PowerShell |
| `gift` shell script | `gift.cmd` on PATH |
| UserDefaults | `HKCU\Software\Gift` |
| Monaco 12 | Consolas 12 |

A second launch (`gift`, Explorer, a jump list entry) hands its folders to the
running copy, as `open -a` does on the Mac.

## Build
Cross-compiles from macOS or Linux with mingw-w64 (on Windows, MSYS2's
`mingw-w64-x86_64-gcc` works the same):
```bash
brew install mingw-w64 makensis
windows/build.sh            # Gift.exe + resources + installer
windows/build.sh debug      # unoptimised, with symbols
```
Output: `windows/build/Gift/` (the app folder, runnable as is) and
`windows/dist/Gift-Setup-<version>-x64.exe`.

## Install
Run `Gift-Setup-1.0.0-x64.exe`. It installs for the current user (no
administrator rights) into `%LOCALAPPDATA%\Programs\Gift`, adds a Start menu
entry, “Open in Gift” on folders, and the `gift` command on PATH; a desktop
shortcut is optional. Uninstall from Settings → Apps.

Requires Windows 10 1809 or later (11 recommended) and
[Git for Windows](https://git-scm.com).

## Layout
```
windows/src/        C++ (window host, views, Git service, panels, diffs, app)
windows/res/        icon, manifest, version resource
windows/installer/  NSIS script
windows/tools/      gift.cmd, make-ico.py
windows/build.sh    compile, link, bundle icons, build the installer
```
