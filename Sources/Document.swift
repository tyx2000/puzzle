import AppKit
import ImageIO

/// An open file's buffer. Shared between editor panes so the same file opened in
/// two panes edits one buffer (Zed behavior) while each pane keeps its own tabs.
final class Document {
    static let structureDidChange = Notification.Name("PuzzleDocumentStructureDidChange")
    static let didReloadFromDisk = Notification.Name("PuzzleDocumentDidReloadFromDisk")

    private enum SaveError: LocalizedError {
        case readOnly
        case encodingFailure
        var errorDescription: String? {
            switch self {
            case .readOnly: return "This document is read-only and cannot be saved."
            case .encodingFailure: return "The document could not be encoded as UTF-8."
            }
        }
    }

    let url: URL
    let storage: NSTextStorage
    /// Cheap language *spec* — describes the language without loading its
    /// grammar. The heavy `LanguageDefinition` is materialised only when the
    /// document is actually highlighted.
    let languageSpec: SyntaxHighlighter.LanguageSpec?
    var isModified = false

    /// True when the file isn't displayable text (binary: images, archives,
    /// object files…). Such documents show a placeholder and are read-only.
    private(set) var isUnsupported = false

    /// Decoded image, when the file is a previewable picture. Shown instead of
    /// the text view rather than being reported as an unsupported binary.
    private(set) var image: NSImage?
    var isImage: Bool { image != nil }

    /// True when the file is played rather than read. Unlike every other
    /// document, none of its bytes are loaded: AVFoundation streams them off
    /// disk itself, which is the only reason a two-gigabyte video can open.
    private(set) var isMedia = false
    /// Video gets the whole pane; audio gets a controls bar.
    private(set) var isVideoMedia = false

    /// True when the file is a book the reader pane opens. Like media, none of
    /// it is loaded here: the reader maps the archive and inflates one chapter
    /// at a time.
    private(set) var isEPUB = false
    /// PDFKit owns rendering; the text storage only holds the file caption.
    private(set) var isPDF = false

    /// True when a preview view owns the pane — the picture, the player — and
    /// the buffer holds a caption rather than the file. Everything that reads
    /// the buffer as source (definitions, blame, folding) has to skip these.
    var isPreviewOnly: Bool { isImage || isMedia || isEPUB || isPDF }

    /// Image formats AppKit can decode and we're happy to preview.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
        "heic", "heif", "webp", "ico", "icns",
    ]
    /// Media AVFoundation decodes on its own. Deliberately narrow: mkv, avi,
    /// webm and ogg would mean bundling ffmpeg or VLCKit — tens of megabytes
    /// into an app that ships at four — so they stay on the "unsupported
    /// binary" path instead of opening a player that fails.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac",
    ]
    static let mediaExtensions: Set<String> = videoExtensions.union(audioExtensions)
    /// EPUB is the one book format that is an open container of XHTML. Kindle's
    /// .mobi/.azw3 are a different, proprietary format and stay unsupported.
    static let bookExtensions: Set<String> = ["epub"]
    /// TextKit materialises several representations of a buffer. Refuse files
    /// large enough to turn one accidental click on a generated log into a
    /// hundreds-of-megabytes allocation spike.
    static let maxTextFileBytes = 16 * 1024 * 1024
    /// Compressed pictures need a little more input headroom; their decoded
    /// dimensions are bounded separately by `decodePreviewImage`.
    static let maxImageFileBytes = 32 * 1024 * 1024

    /// A generated, read-only buffer (a git diff) rather than a file on disk.
    /// Never saved, and coloured by the diff painter instead of tree-sitter.
    private(set) var isVirtual = false
    /// Images, generated diffs and unreadable/unsupported files must never be
    /// written back from their display-only placeholder.
    var isReadOnly: Bool { isUnsupported || isVirtual || isPreviewOnly }
    /// Preserve the encoding that was decoded instead of silently converting a
    /// Latin-1 source file to UTF-8 on its first save.
    private var textEncoding: String.Encoding = .utf8
    /// Wall-clock ordering for last-write-wins synchronization. File-system
    /// modification dates are compared with the latest local text edit.
    private(set) var lastLocalEditAt: Date?
    private var lastKnownDiskModificationDate: Date?
    private(set) var isApplyingExternalChange = false
    /// Line starts, rebuilt lazily after an edit. Anything that needs to turn
    /// an offset into a line number goes through this.
    var lineIndex: LineIndex {
        if let cached = cachedLineIndex, cached.length == storage.length { return cached }
        let built = LineIndex(storage.string)
        cachedLineIndex = built
        return built
    }
    private var cachedLineIndex: LineIndex?

    /// Called wherever the text changes wholesale. The length check above is a
    /// backstop: an edit that keeps the length can still move a newline.
    func invalidateLineIndex() { cachedLineIndex = nil }

    /// Fold one edit into the cached index. Called from the storage's own
    /// `didProcessEditing`, so the next reader — usually the gutter, on the
    /// very next draw — does not pay for a rebuild.
    func lineIndexApply(editedRange: NSRange, delta: Int) {
        guard cachedLineIndex != nil else { return }
        cachedLineIndex?.apply(editedRange: editedRange, delta: delta,
                               text: storage.mutableString)
    }

    /// Every edit to the buffer, wherever it came from — typing, a paste, a
    /// refreshed diff — reaches the index through here.
    private func observeStorageEdits() {
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: .main) { [weak self] notification in
            guard let self,
                  let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self.lineIndexApply(editedRange: storage.editedRange,
                                delta: storage.changeInLength)
        }
    }
    private var storageObserver: NSObjectProtocol?

    /// Full-width line tints for a diff buffer (empty for normal files).
    var diffBands: [(range: NSRange, color: NSColor)] = []
    /// Per-line file line numbers for a diff buffer, so the gutter numbers the
    /// change as it sits in the file rather than counting the diff from 1.
    var diffLineNumbers: [Int?] = []
    /// Foldable blocks derived from the current source.
    private(set) var codeBlocks: [CodeBlock] = []
    /// JSX tag pairs extracted from the same TSX parse used for highlighting.
    /// Stored on the document so split panes share syntax metadata while each
    /// pane independently decides which pair its caret activates.
    private(set) var jsxTagMatches: [JSXTagMatch] = []
    /// Markdown syntax characters retained in storage but collapsed by each
    /// pane's layout manager when their line is not being edited.
    private(set) var markdownSyntaxRanges: [NSRange] = []
    private(set) var markdownCollapsedLineRanges: [NSRange] = []
    private(set) var markdownCodeBlocks: [MarkdownCodeBlockDecoration] = []
    private(set) var markdownTables: [MarkdownTableDecoration] = []
    private(set) var markdownTasks: [MarkdownTaskDecoration] = []
    private(set) var markdownLineMarkers: [MarkdownLineMarkerDecoration] = []
    private(set) var markdownRules: [MarkdownRuleDecoration] = []
    private(set) var markdownImages: [MarkdownImageDecoration] = []
    private(set) var markdownGlyphReplacements: [MarkdownGlyphReplacement] = []

    /// Tab label override (diffs show "file.swift (diff)" / "… @ abc1234").
    private(set) var displayName: String?

    /// Build an in-memory document (used for git diffs).
    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    init(virtualURL: URL, text: String, displayName: String? = nil) {
        defer { observeStorageEdits() }
        self.url = virtualURL
        self.languageSpec = nil
        self.isVirtual = true
        self.displayName = displayName
        storage = NSTextStorage(string: text)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
    }

    init(url: URL) {
        defer { observeStorageEdits() }
        self.url = url
        self.languageSpec = SyntaxHighlighter.spec(for: url)
        self.lastKnownDiskModificationDate = Self.modificationDate(for: url)

        let ext = url.pathExtension.lowercased()

        // Media is claimed ahead of the size gate on purpose. The limits below
        // bound what is read into a buffer, and a media file is never read: the
        // player is handed the URL and streams it. A successful size lookup
        // doubles as the existence check, so a missing file still falls through
        // to the unreadable-file message rather than to a player that fails.
        if Self.mediaExtensions.contains(ext),
           let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            isMedia = true
            isVideoMedia = Self.videoExtensions.contains(ext)
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(fileSize), countStyle: .file)
            storage = NSTextStorage(string: "\(url.lastPathComponent)  ·  \(bytes)")
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }

        // Books take the media path for the same reason: the reader maps the
        // archive and inflates single chapters, so the whole-file limits below
        // would only stop a large book from opening at all.
        if Self.bookExtensions.contains(ext) || ext == "pdf",
           let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            isEPUB = Self.bookExtensions.contains(ext)
            isPDF = ext == "pdf"
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(fileSize), countStyle: .file)
            storage = NSTextStorage(string: "\(url.lastPathComponent)  ·  \(bytes)")
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }

        let hasImageExtension = Self.imageExtensions.contains(ext)
        let byteLimit = hasImageExtension ? Self.maxImageFileBytes : Self.maxTextFileBytes
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize, fileSize > byteLimit {
            isUnsupported = true
            storage = NSTextStorage(string: Self.largeFileMessage(
                for: url, byteCount: fileSize, limit: byteLimit))
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            isUnsupported = true
            storage = NSTextStorage(string: Self.unreadableMessage(for: url, error: error))
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }
        // The file may have grown between the metadata lookup and the read.
        guard data.count <= byteLimit else {
            isUnsupported = true
            storage = NSTextStorage(string: Self.largeFileMessage(
                for: url, byteCount: data.count, limit: byteLimit))
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }

        // Pictures preview as images, not as "unsupported binary". A corrupt
        // image must remain read-only instead of falling through to the very
        // permissive Latin-1 text decoder.
        if hasImageExtension {
            if let (decoded, pixelWidth, pixelHeight) = Self.decodePreviewImage(data),
               decoded.size.width > 0 {
                image = decoded
                let px = "\(pixelWidth) × \(pixelHeight)"
                let bytes = ByteCountFormatter.string(
                    fromByteCount: Int64(data.count), countStyle: .file)
                storage = NSTextStorage(string: "\(url.lastPathComponent)  ·  \(px)  ·  \(bytes)")
                storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                      range: NSRange(location: 0, length: storage.length))
                return
            }
            isUnsupported = true
            storage = NSTextStorage(string: Self.unsupportedMessage(for: url, byteCount: data.count))
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                  range: NSRange(location: 0, length: storage.length))
            return
        }

        var text: String
        if let utf8 = String(data: data, encoding: .utf8), !Self.looksBinary(data) {
            text = utf8
        } else if let latin = String(data: data, encoding: .isoLatin1), !Self.looksBinary(data) {
            text = latin
            textEncoding = .isoLatin1
        } else {
            isUnsupported = true
            text = Self.unsupportedMessage(for: url, byteCount: data.count)
        }
        // Minified JSON is unreadable for the same reason a browser refuses to
        // show it raw, so it is laid out before it reaches the buffer. This is
        // display only: `isModified` stays false, so nothing is written back
        // until the user edits the file themselves.
        let longestLine: Int
        if languageSpec?.name == "json", !isUnsupported,
           Self.longestLineLength(in: data) > JSONFormatter.readableLineLength,
           data.count <= JSONFormatter.maxFormattedBytes,
           let formatted = JSONFormatter.pretty(text), formatted != text,
           JSONFormatter.worthFormatting(source: text, formatted: formatted) {
            text = formatted
            isDisplayFormatted = true
            // Measured again on the laid-out text: no amount of indenting
            // breaks a string, so one enormous value stays one enormous line.
            // A line TextKit can still lay out promptly is kept — that is the
            // whole point of formatting the file — and anything past that goes
            // back on the bounded preview path.
            let residual = Self.longestLineLength(inUTF8: text.utf8)
            longestLine = residual > JSONFormatter.maxFormattedLineLength ? residual : 0
        } else {
            longestLine = Self.longestLineLength(in: data)
        }
        // One enormous line — a source map, a minified bundle — is laid out by
        // TextKit as a single unit: 2.5 seconds of frozen main thread for a 5 MB
        // map, measured. Show a bounded prefix instead, read-only so the rest of
        // the file can never be lost by saving what is on screen.
        if longestLine > Self.maxDisplayLineLength, data.count > Self.minifiedPreviewLength {
            isUnsupported = true
            isMinifiedPreview = true
            let prefix = String(text.prefix(Self.minifiedPreviewLength))
            storage = NSTextStorage(string: Self.minifiedMessage(
                for: url, byteCount: data.count, longestLine: longestLine) + prefix)
        } else {
            storage = NSTextStorage(string: text)
        }
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
    }

    /// Past this, a single line stops being something TextKit can lay out
    /// interactively.
    static let maxDisplayLineLength = 20_000
    /// How much of such a file is worth showing.
    static let minifiedPreviewLength = 200_000
    /// True when only a prefix is on screen.
    private(set) var isMinifiedPreview = false
    /// True when the buffer holds a re-indented copy of the file rather than
    /// its bytes. The gutter's Git baseline is put through the same formatter,
    /// or every line of a minified file would be marked as changed.
    private(set) var isDisplayFormatted = false

    /// Longest run between newlines, straight off the bytes: a newline byte
    /// cannot appear inside a UTF-8 sequence, so this needs no decoding and
    /// costs a few milliseconds on a file that takes half a second to bridge.
    static func longestLineLength(in data: Data) -> Int {
        data.withUnsafeBytes { longestLineLength(inUTF8: $0) }
    }

    static func longestLineLength<Bytes: Sequence>(inUTF8 bytes: Bytes) -> Int
        where Bytes.Element == UInt8 {
        var longest = 0
        var current = 0
        for byte in bytes {
            if byte == 0x0A {
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(longest, current)
    }

    private static func minifiedMessage(for url: URL, byteCount: Int,
                                        longestLine: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let lines = NumberFormatter.localizedString(
            from: NSNumber(value: longestLine), number: .decimal)
        return """
            \(url.lastPathComponent) · \(size) · longest line \(lines) characters

            This file is minified: laying it out in full would freeze the editor,
            so the first \(Self.minifiedPreviewLength / 1000) KB is shown and the
            buffer is read-only. The file on disk is untouched.

            """
    }

    /// A NUL byte in the first 8 KB is the classic "this is binary" signal —
    /// it's what git and grep use, and no valid source file contains one.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// Decode pictures at a bounded resolution. `NSImage(data:)` can keep a
    /// full-resolution decoded bitmap alive; one 8K photo is hundreds of MB.
    /// The editor is a preview, so dimensions above 4096 px are downsampled
    /// while the caption still reports the original size.
    private static func decodePreviewImage(_ data: Data) -> (NSImage, Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (rawProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (rawProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return NSImage(data: data).map {
                ($0, Int($0.size.width.rounded()), Int($0.size.height.rounded()))
            }
        }

        // Always materialise one bounded frame. `NSImage(data:)` can retain all
        // frames/representations of a GIF or ICNS even when its dimensions are
        // small, defeating the pixel cap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return (NSImage(cgImage: thumbnail, size: .zero), width, height)
    }

    private static func unsupportedMessage(for url: URL, byteCount: Int) -> String {
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return """
        Unsupported file type

        \(url.lastPathComponent)
        \(ext.isEmpty ? "No extension" : ext) · \(size)

        This file isn't text, so it can't be shown in the editor.
        """
    }

    private static func unreadableMessage(for url: URL, error: Error) -> String {
        """
        Unable to read file

        \(url.lastPathComponent)
        \(error.localizedDescription)

        This file is read-only in Puzzle to protect its existing contents.
        """
    }

    private static func largeFileMessage(for url: URL, byteCount: Int, limit: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return """
        Large file not loaded

        \(url.lastPathComponent)
        \(size) · Puzzle's in-memory editor limit is \(maximum)

        Open this file with a streaming or large-file editor to avoid excessive memory use.
        """
    }

    var name: String { url.lastPathComponent }
    var text: String { storage.string }

    /// Refresh a generated diff without allocating a second document while an
    /// existing layout manager still owns the old one.
    func replaceVirtualContent(_ text: String, displayName: String?) {
        guard isVirtual else { return }
        self.displayName = displayName
        storage.setAttributedString(NSAttributedString(string: text))
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
        invalidateLineIndex()
        diffBands.removeAll(keepingCapacity: false)
        diffLineNumbers.removeAll(keepingCapacity: false)
        codeBlocks.removeAll(keepingCapacity: false)
        jsxTagMatches.removeAll(keepingCapacity: false)
    }

    func refreshCodeBlocks() {
        let refreshed: [CodeBlock]
        if isVirtual || isUnsupported || isPreviewOnly {
            refreshed = []
        } else {
            refreshed = CodeBlockAnalyzer.analyze(
                text, language: languageSpec?.name)
        }
        guard refreshed != codeBlocks else { return }
        codeBlocks = refreshed
        NotificationCenter.default.post(
            name: Self.structureDidChange, object: self)
    }

    func updateJSXTagMatches(_ matches: [JSXTagMatch]) {
        guard matches != jsxTagMatches else { return }
        jsxTagMatches = matches
        NotificationCenter.default.post(
            name: Self.structureDidChange, object: self)
    }

    func updateMarkdownPresentation(_ presentation: MarkdownPresentation) {
        guard presentation.hiddenSyntaxRanges != markdownSyntaxRanges
                || presentation.collapsedLineRanges != markdownCollapsedLineRanges
                || presentation.codeBlocks != markdownCodeBlocks
                || presentation.tables != markdownTables
                || presentation.tasks != markdownTasks
                || presentation.lineMarkers != markdownLineMarkers
                || presentation.rules != markdownRules
                || presentation.images != markdownImages
                || presentation.glyphReplacements != markdownGlyphReplacements else { return }
        markdownSyntaxRanges = presentation.hiddenSyntaxRanges
        markdownCollapsedLineRanges = presentation.collapsedLineRanges
        markdownCodeBlocks = presentation.codeBlocks
        markdownTables = presentation.tables
        markdownTasks = presentation.tasks
        markdownLineMarkers = presentation.lineMarkers
        markdownRules = presentation.rules
        markdownImages = presentation.images
        markdownGlyphReplacements = presentation.glyphReplacements
        NotificationCenter.default.post(
            name: Self.structureDidChange, object: self)
    }

    /// Approximate retained bytes used by this document. Attributed text costs
    /// more than its UTF-16 characters because syntax runs retain attributes.
    var estimatedMemoryCost: Int {
        let textCost = storage.length.multipliedReportingOverflow(by: 6)
        var total = textCost.overflow ? Int.max : textCost.partialValue
        if let rep = image?.representations.first {
            let pixels = rep.pixelsWide.multipliedReportingOverflow(by: rep.pixelsHigh)
            let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
            if pixels.overflow || bytes.overflow { return Int.max }
            total = total.addingReportingOverflow(bytes.partialValue).partialValue
        }
        return max(total, 1024)
    }

    /// True when the file changed underneath an edited buffer. Puzzle keeps the
    /// buffer (the edits exist nowhere else) and asks at save time.
    private(set) var hasDiskConflict = false

    /// The file changed on disk while this buffer had unsaved edits.
    static let didDetectDiskConflict = Notification.Name("PuzzleDocumentDiskConflict")

    /// Whoever is about to save has told the user and got an answer.
    func resolveDiskConflict() { hasDiskConflict = false }

    /// Throw the buffer away and take what is on disk. Only ever called after
    /// the user has been asked, since it destroys their unsaved edits.
    @discardableResult
    func discardEditsAndReloadFromDisk() -> Bool {
        isModified = false
        lastLocalEditAt = nil
        hasDiskConflict = false
        lastKnownDiskModificationDate = nil
        return reloadFromDiskIfLatest()
    }

    /// Has the file changed since this buffer last read or wrote it? Checked at
    /// save time so a write cannot silently discard someone else's newer file.
    var diskChangedSinceLastSync: Bool {
        guard url.isFileURL, !isVirtual else { return false }
        guard let diskDate = Self.modificationDate(for: url) else { return false }
        guard let known = lastKnownDiskModificationDate else { return false }
        return diskDate > known
    }

    func save() throws {
        guard !isReadOnly else { throw SaveError.readOnly }
        // Keep the source encoding whenever the edited text can represent it.
        // If an edit introduces a character outside that encoding, UTF-8 is a
        // lossless fallback and becomes the document's encoding for later saves.
        let data: Data
        let savedEncoding: String.Encoding
        if let encoded = text.data(using: textEncoding) {
            data = encoded
            savedEncoding = textEncoding
        } else {
            guard let utf8 = text.data(using: .utf8) else {
                throw SaveError.encodingFailure
            }
            data = utf8
            savedEncoding = .utf8
        }
        try data.write(to: url, options: .atomic)
        textEncoding = savedEncoding
        lastKnownDiskModificationDate = Self.modificationDate(for: url)
        lastLocalEditAt = nil
        isModified = false
        hasDiskConflict = false
    }

    func markLocalEdit(at date: Date = Date()) {
        invalidateLineIndex()
        guard !isApplyingExternalChange else { return }
        if lastLocalEditAt.map({ date > $0 }) ?? true { lastLocalEditAt = date }
        isModified = true
    }

    /// Replace the buffer when the disk write is newer than the latest local
    /// edit. No conflict UI is involved: whichever side has the later write
    /// time is authoritative.
    @discardableResult
    func reloadFromDiskIfLatest(observedAt: Date = Date()) -> Bool {
        guard url.isFileURL, !isReadOnly else { return false }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maxTextFileBytes,
              !Self.looksBinary(data),
              let decoded = Self.decodeText(data) else { return false }

        let diskDate = Self.modificationDate(for: url) ?? observedAt
        // A display-formatted buffer never equals the bytes on disk, so the
        // incoming text is put through the same formatter before anything is
        // compared or replaced. Without this, every external-change check would
        // report a difference and paste the minified file back on screen.
        let incoming = isDisplayFormatted
            ? (JSONFormatter.pretty(decoded.text) ?? decoded.text) : decoded.text
        if incoming == text {
            let stateChanged = isModified || lastLocalEditAt != nil
            lastKnownDiskModificationDate = diskDate
            lastLocalEditAt = nil
            isModified = false
            textEncoding = decoded.encoding
            return stateChanged
        }

        // Unsaved edits are the only copy that exists, so an external write
        // never replaces them. Record the conflict instead: the buffer keeps
        // what the user typed, and saving asks before overwriting the newer
        // file on disk.
        if isModified {
            hasDiskConflict = true
            lastKnownDiskModificationDate = diskDate
            NotificationCenter.default.post(name: Document.didDetectDiskConflict, object: self)
            return false
        }
        if let localEdit = lastLocalEditAt, diskDate < localEdit {
            // The local buffer is newer. Remember that this older disk version
            // has been observed; a subsequent external write gets a new date.
            lastKnownDiskModificationDate = diskDate
            return false
        }
        if let known = lastKnownDiskModificationDate,
           diskDate < known {
            return false
        }

        isApplyingExternalChange = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: incoming)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        isApplyingExternalChange = false
        invalidateLineIndex()
        textEncoding = decoded.encoding
        lastKnownDiskModificationDate = diskDate
        lastLocalEditAt = nil
        isModified = false
        hasDiskConflict = false
        return true
    }

    private static func decodeText(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
    }
}

/// Registry of open documents, keyed by URL.
final class DocumentStore {
    static let shared = DocumentStore()
    private var docs: [URL: Document] = [:]
    /// Pane identities currently holding each URL as an open tab. This is
    /// process-wide, unlike a window's local pane list.
    private var owners: [URL: Set<ObjectIdentifier>] = [:]
    /// Least-recently-used first.
    private var order: [URL] = []

    static let diffScheme = "puzzle-diff"

    /// How many file buffers to keep in memory at once.
    ///
    /// Buffers cost roughly twice their text size and, once allocated, macOS's
    /// allocator never hands the pages back — phys_footprint is a high-water
    /// mark. Leaving every file ever opened in memory meant a long session only
    /// grew. Tabs stay open; their text is re-read from disk on return, which
    /// is far cheaper than the memory it saves.
    var maxCachedDocuments = 12
    /// Count alone is not enough: decoded images and large attributed buffers
    /// can make twelve documents enormous.
    var maxCachedBytes = 24 * 1024 * 1024

    /// Whether a buffer is currently held (tests / diagnostics).
    func documentIsCached(_ url: URL) -> Bool { docs[url] != nil }
    func cachedDocument(for url: URL) -> Document? { docs[url] }

    var cachedBytes: Int { docs.values.reduce(0) { $0 + $1.estimatedMemoryCost } }

    /// Immutable copies of current unsaved text inside a project. Project
    /// search runs off the main thread, so its worker must not read directly
    /// from `NSTextStorage`. Clean files need no copy because disk is current.
    func modifiedTextSnapshots(in directory: URL) -> [(url: URL, text: String)] {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return docs.values.compactMap { doc in
            guard doc.isModified, !doc.isReadOnly, doc.url.isFileURL,
                  doc.url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
            return (doc.url, doc.text)
        }
    }

    /// Reconcile cached documents touched by a coalesced FSEvents batch. An
    /// atomic writer often reports a temporary sibling plus a directory event,
    /// so files sharing that directory are considered candidates as well.
    @discardableResult
    func reloadExternalChanges(at changedURLs: [URL], observedAt: Date = Date()) -> [URL] {
        guard !changedURLs.isEmpty else { return [] }
        let changes = changedURLs.map { $0.standardizedFileURL }
        var reloaded: [URL] = []
        for document in docs.values {
            let file = document.url.standardizedFileURL
            let parent = file.deletingLastPathComponent()
            let affected = changes.contains { change in
                change == file || change == parent
                    || change.deletingLastPathComponent() == parent
                    || file.path.hasPrefix(change.path.hasSuffix("/")
                        ? change.path : change.path + "/")
            }
            guard affected, document.reloadFromDiskIfLatest(observedAt: observedAt) else {
                continue
            }
            HighlightService.shared.highlight(document)
            NotificationCenter.default.post(name: Document.didReloadFromDisk,
                                            object: document)
            reloaded.append(document.url)
        }
        return reloaded
    }

    func registerOpen(_ url: URL, owner: AnyObject) {
        owners[url, default: []].insert(ObjectIdentifier(owner))
    }

    func unregisterOpen(_ url: URL, owner: AnyObject) {
        let identifier = ObjectIdentifier(owner)
        owners[url]?.remove(identifier)
        if owners[url]?.isEmpty == true { owners.removeValue(forKey: url) }
        guard owners[url] == nil else { return }
        releaseUnowned(url)
    }

    func document(for url: URL) -> Document {
        if let existing = docs[url] { touch(url); return existing }
        // A diff tab whose buffer was released must not be read from disk —
        // its URL is synthetic. Hand back an empty virtual doc instead.
        if url.scheme == Self.diffScheme {
            return setVirtualDocument(url: url, text: "No diff available.\n",
                                      displayName: url.lastPathComponent + " (diff)")
        }
        let doc = Document(url: url)
        docs[url] = doc
        touch(url)
        HighlightService.shared.highlight(doc)
        // The caller has not attached its layout manager yet, so explicitly
        // protect the document it is about to display from evicting itself.
        evictIfNeeded(excluding: url)
        return doc
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    /// Drop the least-recently-used buffers once over the cap.
    ///
    /// Three things are never evicted, and each would be a bug if it were:
    ///   * modified documents — the edits exist only in the buffer;
    ///   * virtual documents (git diffs) — synthetic URLs, nothing to re-read;
    ///   * documents whose storage is attached to a layout manager, i.e. the
    ///     buffer a pane is displaying right now.
    private func evictIfNeeded(excluding protectedURL: URL? = nil) {
        guard docs.count > maxCachedDocuments || cachedBytes > maxCachedBytes else { return }
        for url in order {
            guard docs.count > maxCachedDocuments || cachedBytes > maxCachedBytes else { break }
            guard url != protectedURL else { continue }
            guard let doc = docs[url] else { continue }
            guard !doc.isModified, !doc.isVirtual else { continue }
            guard doc.storage.layoutManagers.isEmpty else { continue }
            HighlightService.shared.cancelPending(for: url)
            docs.removeValue(forKey: url)
        }
        order = order.filter { docs[$0] != nil }
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }

    /// Register (or replace) an in-memory document, e.g. a git diff. Replacing
    /// matters because re-clicking a file should show its *current* diff.
    @discardableResult
    func setVirtualDocument(url: URL, text: String, displayName: String? = nil) -> Document {
        if let existing = docs[url], existing.isVirtual {
            existing.replaceVirtualContent(text, displayName: displayName)
            touch(url)
            HighlightService.shared.highlight(existing)
            return existing
        }
        let doc = Document(virtualURL: url, text: text, displayName: displayName)
        docs[url] = doc
        touch(url)
        HighlightService.shared.highlight(doc)
        return doc
    }

    /// Drop a document once no pane has it open, and release any grammar that
    /// no remaining document needs (parser tables + compiled queries are large).
    func release(_ url: URL, stillOpen: Bool) {
        guard !stillOpen else { return }
        guard owners[url] == nil else { return }
        releaseUnowned(url)
    }

    private func releaseUnowned(_ url: URL) {
        guard docs[url]?.storage.layoutManagers.isEmpty ?? true else { return }
        HighlightService.shared.cancelPending(for: url)
        docs.removeValue(forKey: url)
        order.removeAll { $0 == url }
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }

    /// Re-apply font / line-height settings to every open buffer.
    func reapplyDisplaySettings() {
        for doc in docs.values { HighlightService.shared.highlight(doc) }
    }

    /// Discard every clean, non-virtual buffer not currently displayed. Tabs
    /// retain their URLs and transparently reload these documents when selected.
    func releaseTransientMemory() {
        for (url, doc) in docs {
            guard !doc.isModified, !doc.isVirtual,
                  doc.storage.layoutManagers.isEmpty else { continue }
            HighlightService.shared.cancelPending(for: url)
            docs.removeValue(forKey: url)
        }
        order = order.filter { docs[$0] != nil }
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }
}

/// Applies tree-sitter highlighting to a document's storage, reusing one
/// highlighter (and parser) per language.
final class HighlightService {
    static let shared = HighlightService()
    private var cache: [String: SyntaxHighlighter] = [:]
    private var pending: [URL: DispatchWorkItem] = [:]
    private let maxBytes = 500_000

    private func highlighter(for lang: LanguageDefinition) -> SyntaxHighlighter? {
        if let hit = cache[lang.name] { return hit }
        guard let hl = SyntaxHighlighter(definition: lang), hl.isUsable else { return nil }
        cache[lang.name] = hl
        return hl
    }

    func highlight(_ doc: Document) {
        let storage = doc.storage
        doc.refreshCodeBlocks()
        // Generated diff buffers get the diff painter, not tree-sitter.
        if doc.isVirtual {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            doc.diffBands = DiffHighlighter.apply(to: storage)
            doc.diffLineNumbers = DiffHighlighter.lineNumbers(in: storage.string)
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)

        // Check size and skip-conditions BEFORE materialising the grammar, so a
        // huge (or unsupported) file never pages in parser tables it won't use.
        guard let spec = doc.languageSpec, !doc.isUnsupported else {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        let text = storage.string
        guard text.utf8.count <= maxBytes else {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        let tags: [JSXTagMatch]
        if let lang = SyntaxHighlighter.definition(for: spec),
           let hl = highlighter(for: lang) {
            tags = hl.highlight(text: text, storage: storage, fullRange: full)
        } else {
            tags = []
        }
        if spec.name == "markdown" {
            doc.updateMarkdownPresentation(
                MarkdownLiveStyler.apply(text: text, to: storage,
                                         documentURL: doc.url))
        } else {
            doc.updateMarkdownPresentation(MarkdownPresentation())
        }
        doc.updateJSXTagMatches(tags)
    }

    /// Release parsers/queries for languages nothing has open any more. Each
    /// cached `SyntaxHighlighter` holds a TSParser plus compiled TSQuery objects.
    func evictUnused(keeping languages: Set<String>) {
        for key in cache.keys where !languages.contains(key) { cache.removeValue(forKey: key) }
        SyntaxHighlighter.unloadDefinitions(keeping: languages)
    }

    /// Cancel any queued re-highlight for a document that's going away.
    func cancelPending(for url: URL) {
        pending[url]?.cancel()
        pending.removeValue(forKey: url)
    }

    /// Debounced re-highlight after edits.
    func scheduleHighlight(_ doc: Document) {
        pending[doc.url]?.cancel()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.highlight(doc)
            self.pending[doc.url] = nil
        }
        pending[doc.url] = work
        // Markdown is formatted in-place, so publish its visual syntax on the
        // next run-loop turn. Other grammars retain the typing debounce because
        // their full tree-sitter parse has no visible read/edit mode transition.
        let delay = doc.languageSpec?.name == "markdown" ? 0 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
