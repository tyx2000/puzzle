# Puzzle GPUI memory prototype

This is an isolated rendering benchmark, not a Puzzle rewrite. It creates a
1773×1351 macOS window with the same broad shape as Puzzle's primary workspace:

- 260-point virtualized project tree
- tab bar and status bar
- 10,000-line virtualized, syntax-colored read-only editor surface
- Monaco 12-point text and Puzzle's light palette

The benchmark is deliberately limited to the UI surface. It does not include
TextKit-equivalent editing, selections, IME, undo, accessibility, search, Git,
filesystem watching, syntax parsing, or document storage. Its memory result is
therefore a best-case lower bound for a GPUI rewrite, not an application-parity
number.

Build with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  cargo build --release --offline
```

A full Xcode installation is required because GPUI's Metal shaders are
compiled during the build. Change `DEVELOPER_DIR` if Xcode is installed at a
different path.

## Result (2026-07-28)

Both applications were measured after warm-up with a single 1773×1351 window
using macOS `footprint`:

| Build | Physical footprint |
| --- | ---: |
| GPUI rendering prototype (two repeat samples) | 107 MB |
| Current Puzzle release | 126–133 MB |
| Best-case reduction | 19–26 MB |

The experiment's rewrite gate was a reduction of at least 30–40 MB. The
prototype does not pass it.

The allocation shape also explains the result. The GPUI prototype used 73 MB
of IOSurface memory and only 256 KB of Core Animation memory. Puzzle used
roughly 60–65 MB of IOSurface memory and 11–13 MB of Core Animation memory.
GPUI moves much of the display cost from AppKit/Core Animation to Metal-backed
surfaces; it does not eliminate that cost.

Because the prototype omits the editing and application capabilities listed
above, 107 MB is a favorable lower bound. Adding feature parity would likely
reduce the observed saving further. The decision from this benchmark is to
keep Puzzle's native Swift/AppKit implementation and continue targeted memory
work rather than rewrite it in GPUI for memory savings.
