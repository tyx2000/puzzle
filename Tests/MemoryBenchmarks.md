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
| Project and six files, all as launch arguments¹ | 142 MB | 105 MB |
| Project, Git history (`--history 0`) | 91 MB | 60 MB |
| Project search (`--search FlatView`) | 77 MB | 51 MB |
| Three windows (`--windows 3`) | 156 MB | 72 MB |

¹ A file named on the command line can bring its own folder in as a project too,
so this row has more than one project open. The table below opens the files
inside the project that is already open, which is how they are normally opened.

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

### Start page and tree-sitter

These are medians of three runs. Each run opens the project, then opens the files
inside it once it has loaded. Both builds were measured with the same working tree.

| Scenario | `ef10f66` | This change |
| --- | ---: | ---: |
| Project open, no file | 49.6 MB | 41.8 MB |
| Project, then six files | 97.8 MB | 86.6 MB |
| Project, then one 600 KB Swift file | 83.1 MB | 75.9 MB |

- **Start page.** Every window built a start page, and a window opened for a
  project dropped it straight away. The page is now made one turn after it is
  asked for, and only if it is still wanted, so a window opened with `pz`, from
  Finder or with a launch argument never builds one. A window that has a
  project lets its start page go. Live malloc fell by only 3 MB, but the build
  and the drop cost 8 MB of footprint.
- **Tree-sitter.** Compiling a highlight query (`ts_query_new`) allocates a
  transient block of about 5 MB. Once freed, malloc kept it in its cache of
  large blocks, which still counts against the footprint.
  `malloc_zone_pressure_relief` returned nothing. `TreeSitterAllocator` now
  maps any tree-sitter block of 1 MB or more directly and unmaps it when
  tree-sitter frees it.

Opening a file still costs 17–19 MB of drawable surface for the text area and
the gutter. A minimal `NSTextView` window pays the same. About 10 MB of the
malloc heap is free space in partly used pages, which no API returns.
