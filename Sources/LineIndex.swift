import Foundation

/// Line starts for a document, so "which line is this offset on" and "where
/// does line N start" are lookups rather than scans.
///
/// The scans they replace walked the text one `character(at:)` at a time —
/// fine for a source file, 400ms on a minified bundle where the whole file is
/// a single line and every caret move paid for it.
struct LineIndex {
    /// UTF-16 offset of the first character of each line. Always starts at 0.
    private(set) var starts: [Int]
    private(set) var length: Int

    /// Scans the UTF-8 bytes and counts UTF-16 units as it goes.
    ///
    /// Asking an `NSTextStorage`'s string for characters — one at a time or in
    /// chunks — cost 388ms on a 3.8M-character file, which the editor would pay
    /// again after every edit. The byte scan is ~50x faster and a newline byte
    /// cannot appear inside a multi-byte sequence, so it needs no decoding.
    init(_ text: String) {
        var starts: [Int] = [0]
        var utf16Offset = 0
        // A string bridged from an `NSTextStorage` has no contiguous UTF-8
        // buffer, and the byte-at-a-time fallback below is four times slower.
        // Making it contiguous once is cheaper than paying that on every byte.
        var contiguous = text
        contiguous.makeContiguousUTF8()
        var utf8 = contiguous.utf8
        let scanned: Void? = utf8.withContiguousStorageIfAvailable { buffer in
            for byte in buffer {
                // Continuation bytes carry no UTF-16 unit of their own.
                if byte & 0xC0 == 0x80 { continue }
                if byte == 0x0A { starts.append(utf16Offset + 1) }
                // Only scalars outside the BMP (4-byte sequences) need two.
                utf16Offset += byte >= 0xF0 ? 2 : 1
            }
        }
        if scanned == nil {
            // Non-contiguous storage: same walk, one byte at a time.
            for byte in utf8 {
                if byte & 0xC0 == 0x80 { continue }
                if byte == 0x0A { starts.append(utf16Offset + 1) }
                utf16Offset += byte >= 0xF0 ? 2 : 1
            }
        }
        length = utf16Offset
        self.starts = starts
    }

    init(_ text: NSString) { self.init(text as String) }

    /// 1-based line containing `location`.
    func line(at location: Int) -> Int {
        guard location > 0 else { return 1 }
        let clamped = min(location, length)
        // Last start <= clamped.
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= clamped { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// Offset where a 1-based line begins, clamped to the text's end.
    func start(ofLine line: Int) -> Int {
        guard line > 1 else { return 0 }
        let index = line - 1
        return index < starts.count ? starts[index] : length
    }

    var lineCount: Int { starts.count }

    /// Fold one text-storage edit into the index instead of rebuilding it.
    ///
    /// A full rebuild is ~135ms on a four-million-character file, and the
    /// gutter needs the index on the very next draw — so typing in a big file
    /// would hitch after every keystroke. This touches only the lines the edit
    /// covers plus a shift of the ones after it.
    ///
    /// `editedRange` is in the text as it is *now*; `delta` is how much longer
    /// it became (negative when text was deleted).
    mutating func apply(editedRange: NSRange, delta: Int, text: NSString) {
        let newEnd = editedRange.location + editedRange.length
        let oldEnd = newEnd - delta
        // Lines that began inside the replaced span are gone.
        var first = 1
        var last = starts.count            // exclusive
        while first < last {
            let middle = (first + last) / 2
            if starts[middle] <= editedRange.location { first = middle + 1 } else { last = middle }
        }
        var removeEnd = first
        while removeEnd < starts.count, starts[removeEnd] <= oldEnd { removeEnd += 1 }
        var rebuilt = Array(starts[..<first])

        // Newlines inside the replacement, in the text as it stands now.
        let scanStart = min(editedRange.location, text.length)
        let scanEnd = min(newEnd, text.length)
        if scanStart < scanEnd {
            let chunk = 4096
            var buffer = [unichar](repeating: 0, count: chunk)
            var offset = scanStart
            while offset < scanEnd {
                let count = min(chunk, scanEnd - offset)
                buffer.withUnsafeMutableBufferPointer { pointer in
                    text.getCharacters(pointer.baseAddress!,
                                       range: NSRange(location: offset, length: count))
                }
                for index in 0..<count where buffer[index] == 0x0A {
                    rebuilt.append(offset + index + 1)
                }
                offset += count
            }
        }

        // Everything after the edit keeps its line, at a shifted offset.
        if removeEnd < starts.count {
            rebuilt.append(contentsOf: starts[removeEnd...].map { $0 + delta })
        }
        starts = rebuilt
        length = text.length
    }

    /// Longest line, in UTF-16 units. A minified bundle or a source map is one
    /// line of megabytes, which TextKit lays out as a single unit.
    var longestLine: Int {
        var longest = 0
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : length
            longest = max(longest, end - start)
        }
        return longest
    }
}
