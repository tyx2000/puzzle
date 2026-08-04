# Puzzle — a minimal native code editor

A tiny AppKit code editor in Swift, styled after Zed, with real tree-sitter
syntax highlighting. **~3.9 MB app bundle, ~60 MB RAM.**

## Features
- **Zed-matched theme & layout** — One Light / One Dark that follow the system
  appearance (like Zed with no theme pinned), Monaco 12 with configurable exact
  code/tree row heights.
  Zed-style header (tabs beside the traffic lights), full-width bottom status bar
  with a left **activity bar** (project · search · git · outline · settings) and
  right branch · line/col · language, editor tabs with an active accent, compact
  file tree with type icons + git-dirty markers, aligned gutter, current-line
  highlight. Fully flat — no Liquid Glass.
- **Editor split** — top-right split icon (or ⌘\) opens a second vertical pane
  with its **own independent tab strip**. Panes share document buffers via
  `DocumentStore`, so the same file open in both panes edits one buffer (Zed
  behavior). Toggling again collapses back to one pane.
- **Tree ↔ tab sync** — the active tab's file gets a persistent background row in
  the tree; the tree also shows git-dirty coloring.
- **No status bar** — four evenly-spaced buttons (project · search · git ·
  settings) live in the sidebar's 40pt bottom action bar, whose width is the
  panel's width and stays fixed when switching panels. The active button has a
  white background; tapping the active one collapses the panel.
- **File tabs** — row height follows the window traffic lights and wraps when
  needed; active tabs use the same edge-to-edge background rule as the panel
  action buttons.
- **Search panel** — results grouped per file (name + folder) with line numbers
  and the match highlighted; click a file to open it, a line to jump to it.
- **Git panel** — flat Changes / History tabs, automatically staged changed
  files with status codes, branch, full-width commit message editor + commit.
- **Settings** — the gear opens `~/.config/puzzle/settings.json`. Editor font:
  `buffer_font_family`, `buffer_font_size`, `buffer_font_weight`,
  `code_line_height`, `tab_size`. Panel/UI
  font: `ui_font_family`, `ui_font_size`, `ui_font_weight` (`ui_font_size` scales
  the whole tree/tab/panel type hierarchy), with `tree_line_height` controlling
  file-tree rows. Saving re-applies live; `//` comments are allowed.
- **Editor details** — active-line band and caret use the configured code-row
  height, with code, line numbers and inline blame vertically centered; no gutter separator, and hover-only gutter-arrow
  code folding that preserves source line numbers.
- **File tree** — lazy `NSOutlineView`, folders-first, git-dirty markers.
- **Dock menu** — right-click the running app icon to open one of the ten most
  recently used valid project folders in a new Puzzle window.
- **Editor** — `NSTextView` (TextKit 1), multi-file tabs, undo, 350ms debounced
  auto-save, and immediate manual save (⌘S).
- **Syntax highlighting** — vendored **tree-sitter** grammars for JSON, YAML,
  Bash, TypeScript/JS, and Markdown, with `#eq?`/`#match?`/`#any-of?` predicate
  evaluation and a One Dark capture→color map. Adding a language is one entry in
  `SyntaxHighlighter.languages` + a bundled `highlights.scm`.
- **Find in file** — native incremental find bar (⌘F).
- **Find in folder** — project-wide search via ripgrep (built-in fallback).
- **Git** — branch in the status bar, dirty files marked, status sheet (⌘G).

## Build
```bash
./build.sh
```
On first run this clones the tree-sitter runtime + grammars into `vendor/`
(via `vendor/fetch.sh`), compiles them to cached objects in `.obj/`, links them
into the Swift build, and bundles the highlight queries. Requires the Xcode
command-line tools; targets macOS 13+.

## Run
```bash
open build/Puzzle.app                              # pick a folder on launch
open build/Puzzle.app --args /path/to/repo         # open a project
open build/Puzzle.app --args /path/to/repo a.ts b.json   # open files as tabs
open build/Puzzle.app --args /path/to/repo a.ts --split   # start split
```
Ad-hoc signed (not notarized). If Gatekeeper blocks it, right-click → Open, or
`xattr -dr com.apple.quarantine build/Puzzle.app`.

On first launch, Puzzle automatically installs or refreshes the bundled `pz`
command in the first writable directory on your login shell's `PATH`. It never
overwrites an unrelated command with the same name.

## Shortcuts
⌘O open folder · ⌘S save · ⌘F find in file · ⇧⌘F find in folder ·
⌘1 files · ⌘2 search · ⌘B toggle sidebar · ⌘\ split editor · ⌘G git ·
⌥⌘[ fold/unfold current block · ⌥⌘] unfold all

## Layout
```
Sources/            Swift (Theme, workspace, tabs, tree, search, git, highlighter)
Sources/ts_bridge.h C bridging header for the tree-sitter API
Queries/            supplemental highlight queries (TS/JS ecma)
Tools/makeicon.swift draws the app icon (puzzle pieces) -> AppIcon.icns
vendor/             tree-sitter runtime + grammars (fetched)
build.sh            compiles C + Swift, builds the icon, bundles queries, signs
```

## settings.json
Opened by the gear button; created on first use at `~/.config/puzzle/settings.json`
with every property documented inline. Keys and defaults:

| key | default | controls |
|---|---|---|
| `buffer_font_family` | `"Monaco"` | code font in the editor |
| `buffer_font_size` | `12` | code font size (6–72) |
| `buffer_font_weight` | `400` | code weight; 600+ renders bold |
| `code_line_height` | `27` | exact code-row height in points (8–200) |
| `tab_size` | `4` | tab width in characters (1–16) |
| `ui_font_family` | `"Monaco"` | font for tree / tabs / panels |
| `ui_font_size` | `12` | base UI size; scales the whole panel hierarchy (8–32) |
| `ui_font_weight` | `400` | UI weight; 600+ renders bold |
| `tree_line_height` | `22` | exact file-tree row height in points (8–200) |

## Notes / limits
- `NSTextView` is great for normal source files; multi-hundred-MB files are the
  wall that pushed Zed to a custom GPU renderer. Highlighting is skipped above
  ~500 KB to stay responsive.
- Highlighting re-parses the whole document on edit (debounced). Fine for basic
  editing; incremental `ts_tree_edit` reparsing would be the next optimization.
