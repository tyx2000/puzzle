# Puzzle for Windows

A native Windows port of Puzzle — C++20, Win32, Direct2D and DirectWrite, with
Scintilla as the editing component and tree-sitter for highlighting. No
framework and no runtime to install: one `Puzzle.exe`, the highlight queries
and Material file icons beside it, and the `pz` command.

It is the macOS app feature for feature: the same Ayu Dark palette, the same
Zed-style layout, the same editor and Git behaviour, with each Mac service
mapped to its Windows counterpart.

## What it does
- **Editor** — tabs, tree-sitter highlighting for JSON, Shell, YAML,
  TypeScript/TSX, Markdown, Swift, HTML, CSS, Python, Rust, Go, C, TOML, XML,
  SQL, Dockerfile and .gitignore; code folding, bracket matching, JSX tag
  matching, comment toggling (Ctrl+/), smart indent, duplicate/delete line,
  go to definition, find and replace with Aa / wd / .* toggles and a match
  navigator, exact `code_line_height` rows, inline blame, Git change marks in
  the gutter with a diff popover and Revert.
- **Markdown** — live styling with the syntax hidden off the caret line,
  images inline, link cards.
- **Previews** — images (WIC), SVG (rendered, beside its source), PDF
  (Windows.Data.Pdf, with thumbnails), audio and video (Media Foundation),
  EPUB (a reader with chapters), and a file's Git history as a table.
- **Projects** — the window's projects down the side; the one shown expands
  to its file tree beside its changes over its history, split by lines that
  are dragged and remembered. Click the branch on a row for its Git panel,
  the Git mark to pull. Drag rows to reorder with every project collapsed.
- **File tree** — Git colours, ignored files dimmed, new file/folder, rename,
  delete to the Recycle Bin, copy path, show in Explorer, open in a terminal.
- **Search** — the whole project, grouped by file, with ripgrep when it is on
  PATH and a built-in search otherwise; unsaved edits are searched as typed.
- **Git panel** — Changes (staged automatically, Discard and Open on each
  row, a commit message box, Commit with Ctrl+Enter, Push with
  Ctrl+Shift+Enter), Branch (switch, create, delete, remotes) and History
  (the lane graph over every branch, ref pills, a commit's files).
- **Quick Open** (Ctrl+P) and **Go to Line** (Ctrl+L) in a floating palette.
- **Settings** — `%USERPROFILE%\.config\puzzle\settings.json`, opened from
  the gear; saving it applies fonts and row heights at once.
- **Live** — ReadDirectoryChangesW watches the working tree and `.git`; open
  buffers reload when changed on disk; a project coming on screen is fetched
  in the background.

## Mac → Windows
| macOS | Windows |
|---|---|
| traffic lights, full-size titlebar | caption buttons drawn at the top-right, the band still drags the window |
| menu bar | the ≡ button at the top-left (File, Edit, View, Window, Help) |
| ⌘ shortcuts | Ctrl (Ctrl+Tab / Ctrl+PageDown also step tabs) |
| Dock menu of recent projects | taskbar jump list (ten newest) |
| Finder “Open With” | “Open with Puzzle” on files and folders in Explorer |
| Trash | Recycle Bin |
| iTerm / Terminal | Windows Terminal / PowerShell |
| `pz` shell script | `pz.cmd` on PATH |
| UserDefaults | `HKCU\Software\Puzzle` |
| NSTextView + TextKit | Scintilla, drawn over by the app for gutter and decorations |
| PDFKit / AVKit / ImageIO | Windows.Data.Pdf / Media Foundation / WIC |
| Monaco 12 | Consolas 12 |

A second launch (`pz`, Explorer, a jump list entry) hands its paths to the
running copy, as `open -a` does on the Mac.

## Build
Cross-compiles from macOS or Linux with mingw-w64 (on Windows, MSYS2's
`mingw-w64-x86_64-gcc` works the same):
```bash
brew install mingw-w64 makensis
vendor/fetch.sh             # tree-sitter + grammars, icons, Scintilla 5.5.7
windows/build.sh            # Puzzle.exe + resources + installer
windows/build.sh debug      # unoptimised, with symbols
```
Output: `windows/build/Puzzle/` (the app folder, runnable as is) and
`windows/dist/Puzzle-Setup-<version>-x64.exe`.

## Install
Run `Puzzle-Setup-1.0.0-x64.exe`. It installs for the current user (no
administrator rights) into `%LOCALAPPDATA%\Programs\Puzzle`, adds a Start menu
entry, “Open with Puzzle” in Explorer, and the `pz` command on PATH; a desktop
shortcut is optional. Uninstall from Settings → Apps.

Requires Windows 10 1809 or later (11 recommended). The Git features need
[Git for Windows](https://git-scm.com); the editor works without it.

## Layout
```
windows/src/        C++ (window host, views, editor, previews, Git, panels, app)
windows/res/        icon, manifest, version resource
windows/installer/  NSIS script
windows/tools/      pz.cmd, make-ico.py
```
