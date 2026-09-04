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
