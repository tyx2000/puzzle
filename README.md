# Puzzle — a minimal native code editor

A tiny AppKit code editor in Swift, styled after Zed, with real tree-sitter
syntax highlighting. **~3.9 MB app bundle, ~60 MB RAM.**

## Features
- **Zed-matched theme & layout** — One Light / One Dark that follow the system
  appearance (like Zed with no theme pinned), Monaco 12 with 1.8 line height.
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
  the tree; the tree also shows indent guides and git-dirty coloring.
- **No status bar** — four evenly-spaced buttons (project · search · git ·
  settings) live in the sidebar's 40pt bottom action bar, whose width is the
  panel's width and stays fixed when switching panels. The active button has a
  white background; tapping the active one collapses the panel.
- **Pill tabs** — floating rounded tabs that wrap to more rows when they don't
  fit; the active tab is a plain white pill with no border, with a file-type icon.
- **Search panel** — results grouped per file (name + folder) with line numbers
  and the match highlighted; click a file to open it, a line to jump to it.
- **Git panel** — Changes / History, Tracked & Untracked sections with status
  codes, per-file stage checkboxes, Stage All, branch, commit message + commit.
- **Settings** — the gear opens `~/.config/puzzle/settings.json`. Editor font:
  `buffer_font_family`, `buffer_font_size`, `buffer_font_weight`,
  `buffer_line_height`, `tab_size`, `show_wrap_guides`, `wrap_column`. Panel/UI
  font: `ui_font_family`, `ui_font_size`, `ui_font_weight` (`ui_font_size` scales
  the whole tree/tab/panel type hierarchy). Saving re-applies live; `//` comments
  are allowed.
- **Editor details** — active-line band centered on the text, caret sized to the
  text (not the tall line box), no gutter separator.
- **File tree** — lazy `NSOutlineView`, folders-first, git-dirty markers.
- **Editor** — `NSTextView` (TextKit 1), multi-file tabs, undo, save (⌘S).
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

## Shortcuts
⌘O open folder · ⌘S save · ⌘F find in file · ⇧⌘F find in folder ·
⌘1 files · ⌘2 search · ⌘B toggle sidebar · ⌘\ split editor · ⌘G git

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
| `buffer_line_height` | `1.8` | line height as a multiple of natural height (1.0–3.0) |
| `tab_size` | `4` | tab width in characters (1–16) |
| `show_wrap_guides` | `false` | draw the vertical wrap rule |
| `wrap_column` | `80` | column for the wrap rule |
| `ui_font_family` | `"Monaco"` | font for tree / tabs / panels |
| `ui_font_size` | `12` | base UI size; scales the whole panel hierarchy (8–32) |
| `ui_font_weight` | `400` | UI weight; 600+ renders bold |

## Notes / limits
- `NSTextView` is great for normal source files; multi-hundred-MB files are the
  wall that pushed Zed to a custom GPU renderer. Highlighting is skipped above
  ~500 KB to stay responsive.
- Highlighting re-parses the whole document on edit (debounced). Fine for basic
  editing; incremental `ts_tree_edit` reparsing would be the next optimization.
