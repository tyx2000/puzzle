import AppKit
import ImageIO

/// An open file's buffer. Shared between editor panes so the same file opened in
/// two panes edits one buffer (Zed behavior) while each pane keeps its own tabs.
/// The two pictures an SVG diff is about: what Git has, and what the working
/// tree has. Either can be missing — a new file has no before, a deleted one
/// has no after.
struct SVGDiffSides: Equatable {
    let before: Data?
    let after: Data?
}

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

    /// Image metadata, when the file is a previewable picture. Shown instead of
    /// the text view rather than being reported as an unsupported binary.
    private(set) var previewImage: PreviewImageSource?
    var isImage: Bool { previewImage != nil }

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
    /// SVG is source that is also a picture: the buffer is the file, and the
    /// pane draws what it describes above it.
    var isSVG: Bool {
        !isVirtual && Self.vectorImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// True when a preview view owns the pane — the picture, the player — and
    /// the buffer holds a caption rather than the file. Everything that reads
    /// the buffer as source (definitions, blame, folding) has to skip these.
    var isPreviewOnly: Bool { isImage || isMedia || isEPUB || isPDF }

    /// Image formats AppKit can decode and we're happy to preview.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
        "heic", "heif", "webp", "ico", "icns",
    ]
    /// SVG is a picture *and* its own source. It opens as text, with the
    /// picture drawn above it, so it is deliberately not an image extension.
    static let vectorImageExtensions: Set<String> = ["svg"]
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
    /// dimensions are bounded separately by `PreviewImageSource`.
    static let maxImageFileBytes = 32 * 1024 * 1024

    /// A generated, read-only buffer (a git diff) rather than a file on disk.
    /// Never saved, and coloured by the diff painter instead of tree-sitter.
    private(set) var isVirtual = false
    /// The two sides of an SVG diff, when this buffer is one: the picture as
    /// Git has it and the picture as the working tree has it. The diff text
    /// itself is what the buffer holds.
    var svgDiffSides: SVGDiffSides?

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
    private(set) var markdownLinks: [MarkdownLinkDecoration] = []

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
            if let source = PreviewImageSource(url: url, data: data) {
                previewImage = source
                let size = "\(Int(source.pixelSize.width)) × \(Int(source.pixelSize.height))"
                let bytes = ByteCountFormatter.string(
                    fromByteCount: Int64(data.count), countStyle: .file)
                storage = NSTextStorage(
                    string: "\(url.lastPathComponent)  ·  \(size)  ·  \(bytes)")
                storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                                      range: NSRange(location: 0, length: storage.length))
                return
            }
            isUnsupported = true
            storage = NSTextStorage(
                string: Self.unsupportedMessage(for: url, byteCount: data.count))
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
        let presentation = Self.presentation(of: data, text: text, url: url,
                                             spec: languageSpec,
                                             isUnsupported: isUnsupported)
        isDisplayFormatted = presentation.isDisplayFormatted
        if presentation.isMinifiedPreview {
            isUnsupported = true
            isMinifiedPreview = true
        }
        storage = NSTextStorage(string: presentation.text)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
    }

    /// What a file's bytes become on screen: the text for the buffer, plus the
    /// two flags that say the buffer is not simply the file.
    ///
    /// Opening a file and reloading one after an external write share this, and
    /// used not to. The reload checked the total size and nothing else, so a
    /// background build, a formatter or a code generator could rewrite a file
    /// that had opened as a bounded read-only preview and hand back a fully
    /// editable buffer holding the megabyte-long line the preview exists to
    /// keep out of TextKit.
    struct Presentation {
        let text: String
        let isDisplayFormatted: Bool
        let isMinifiedPreview: Bool
    }

    static func presentation(of data: Data, text decoded: String, url: URL,
                             spec: SyntaxHighlighter.LanguageSpec?,
                             isUnsupported: Bool) -> Presentation {
        // Minified JSON is unreadable for the same reason a browser refuses to
        // show it raw, so it is laid out before it reaches the buffer. This is
        // display only: `isModified` stays false, so nothing is written back
        // until the user edits the file themselves.
        var text = decoded
        var isDisplayFormatted = false
        let longestLine: Int
        if spec?.name == "json", !isUnsupported,
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
            let prefix = String(text.prefix(Self.minifiedPreviewLength))
            return Presentation(
                text: Self.minifiedMessage(for: url, byteCount: data.count,
                                           longestLine: longestLine) + prefix,
                isDisplayFormatted: isDisplayFormatted, isMinifiedPreview: true)
        }
        return Presentation(text: text, isDisplayFormatted: isDisplayFormatted,
                            isMinifiedPreview: false)
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
    /// Counts the times this buffer's content has been swapped out from under
    /// it, so a rebuild that started earlier can tell it is no longer wanted.
    private(set) var contentReplacements = 0

    func replaceVirtualContent(_ text: String, displayName: String?) {
        guard isVirtual else { return }
        contentReplacements += 1
        // An edited diff is the user's work, not a cached render. Re-opening
        // the same file must not throw it away behind their back; saving is
        // what turns it back into a plain rendered diff.
        guard !isModified else { return }
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
                || presentation.glyphReplacements != markdownGlyphReplacements
                || presentation.links != markdownLinks else { return }
        markdownSyntaxRanges = presentation.hiddenSyntaxRanges
        markdownCollapsedLineRanges = presentation.collapsedLineRanges
        markdownCodeBlocks = presentation.codeBlocks
        markdownTables = presentation.tables
        markdownTasks = presentation.tasks
        markdownLineMarkers = presentation.lineMarkers
        markdownRules = presentation.rules
        markdownImages = presentation.images
        markdownGlyphReplacements = presentation.glyphReplacements
        markdownLinks = presentation.links
        NotificationCenter.default.post(
            name: Self.structureDidChange, object: self)
    }

    /// Approximate retained bytes used by this document. Attributed text costs
    /// more than its UTF-16 characters because syntax runs retain attributes.
    var estimatedMemoryCost: Int {
        let textCost = storage.length.multipliedReportingOverflow(by: 6)
        return max(textCost.overflow ? Int.max : textCost.partialValue, 1024)
    }

    /// True when the disk changed underneath an edited buffer. Background saves
    /// defer this conflict; an explicit Save writes the current buffer.
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

    /// Refresh clean buffers from disk while preserving unsaved local edits.
    @discardableResult
    func reloadFromDiskIfLatest(observedAt: Date = Date()) -> Bool {
        // A bounded preview is read-only, but it still tracks its file: the
        // build that minified it may well un-minify it again.
        guard url.isFileURL, !isReadOnly || isMinifiedPreview else { return false }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maxTextFileBytes,
              !Self.looksBinary(data),
              let decoded = Self.decodeText(data) else { return false }

        let diskDate = Self.modificationDate(for: url) ?? observedAt
        // Put through the same decision the file would get if it were opened
        // now: a display-formatted buffer never equals the bytes on disk, and a
        // line too long to lay out is still too long to lay out when it arrives
        // from a background write rather than from the first read.
        let presentation = Self.presentation(of: data, text: decoded.text, url: url,
                                             spec: languageSpec, isUnsupported: false)
        let incoming = presentation.text
        if incoming == text {
            let stateChanged = isModified || lastLocalEditAt != nil
            lastKnownDiskModificationDate = diskDate
            lastLocalEditAt = nil
            isModified = false
            hasDiskConflict = false
            textEncoding = decoded.encoding
            return stateChanged
        }

        // Unsaved edits are the only copy that exists, so an external write
        // never replaces them. Record the conflict instead: the buffer keeps
        // what the user typed until an explicit save or reload.
        if isModified {
            // FSEvents also reports parent-directory changes and delayed events
            // from our own saves. Different buffer text alone is just an edit,
            // not evidence that the file on disk changed since the last sync.
            guard diskDate != lastKnownDiskModificationDate else { return false }
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
        isDisplayFormatted = presentation.isDisplayFormatted
        isMinifiedPreview = presentation.isMinifiedPreview
        isUnsupported = presentation.isMinifiedPreview
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

    static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
    }
}
