# Memory benchmark

Run `bash Tests/benchmark-memory.sh` from the repository after building the C
grammar objects. The script builds an optimized executable and runs each scenario
in a fresh process. Fixtures are generated in a separate process. It reports
Mach physical footprint, rather than RSS, and keeps fixture files in
`/tmp/puzzle-memory-fixtures`.

For a source snapshot comparison, use:

```sh
bash Tests/benchmark-memory.sh /path/to/before/Sources /tmp/puzzle-benchmark-before
bash Tests/benchmark-memory.sh
```

The baseline below used commit `770fcee` and the same benchmark source on the same
machine. These are isolated editor-pane workloads, not a prediction of the
complete application's idle memory. AppKit/system caches and display scale can
affect results.

| Scenario | Before | After |
| --- | ---: | ---: |
| Audio preview, physical footprint | 23.61 MiB | 21.63 MiB |
| 4096 × 4096 JPEG, 600 × 500-point window | 850.64 MiB | 18.16 MiB |
| Five image/audio/PDF/text cycles, final footprint | 1263.83 MiB | 76.89 MiB |
| Same cycles, peak footprint | 1921.49 MiB | 92.31 MiB |
| Preview views retained after returning to text | 3 | 0 |
| 40 edits to 2,000 lines, mean highlighting time | 17.32 ms | 9.38 ms |
| Same editing workload, physical footprint | 14.36 MiB | 14.58 MiB |

Highlighting time includes parsing, capture queries and applying text attributes.
Incremental parsing retains a bounded previous tree/source, so a small increase
in steady memory is expected. Queries still cover the full document. The large
image gain includes removal of AppKit snapshot caches as well as decoding only
the resolution needed by the viewport. The benchmark does not start playback.

`RegressionTests.swift` separately checks Unicode/newline/deletion edits against
fresh parses, unchanged-text reuse, different-buffer isolation, image resolution
changes on resize, preview deallocation and PDF reading-position restoration.

## Whole application

The editor-pane workloads above leave out the window around them. For the whole
app, launch a release build (`./build.sh release`) with `open -n` and read
`footprint <pid>` once it has settled (6–10 s). These numbers are from a 5K
display at 2× with the default window (1706 × 1353 points). Window size and
display scale move every row, so compare builds only on the same machine.

| Scenario | `66405d1` | Flat layers |
| --- | ---: | ---: |
| Welcome page | 56 MB | 35 MB |
| Project open, no file | 89 MB | 49 MB |
| Project and six files | 142 MB | 105 MB |
| Project, Git history (`--history 0`) | 91 MB | 60 MB |
| Project search (`--search FlatView`) | 77 MB | 51 MB |
| Three windows (`--windows 3`) | 156 MB | 72 MB |

At `66405d1` the largest category in `footprint` was CoreAnimation: 25–86 MB of
bitmaps that hold one flat colour each. Any view that overrides `draw(_:)` gets
a backing store the size of itself, and flat grounds (`FlatView`), list rows,
the projects splitter and the empty-editor hints were all drawn. They now show
their colour as `layer.backgroundColor`. The splitter's line is its own 1-point
view, and the hints are drawn by a view only as big as the text.
`testFlatSurfacesHoldNoBitmap` keeps it that way. Screenshots of the welcome
page, a file, Markdown, an image, the Git panel, Git history and a history diff
match the earlier build pixel for pixel.

Swapping AppKit for another toolkit does not help. A minimal window with one
`NSTextView` measures 39 MB from Swift, Objective-C and Rust (`objc2`) alike.
The same window takes 128 MB in egui (wgpu), 182 MB in WKWebView with its helper
processes, and 321 MB in Fyne. GPU and web toolkits keep several window-sized
drawables in flight, and the language runtime is not what costs memory.
