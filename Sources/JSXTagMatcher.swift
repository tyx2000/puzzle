import Foundation

/// Cached UTF-16 ranges for one JSX element. Tree-sitter owns pairing and
/// nesting; views only use these immutable ranges to decide what to paint.
struct JSXTagMatch: Equatable {
    enum Kind: Equatable {
        case paired
        case selfClosing
    }

    let kind: Kind
    let openingTagRange: NSRange
    let closingTagRange: NSRange?
    let openingAngleRange: NSRange
    /// `<Button`, `<UI.Button`, or the complete `<>` fragment opener.
    let openingHeadRange: NSRange
    let openingTerminatorRange: NSRange
    let closingTerminatorRange: NSRange

    var activationRanges: [NSRange] {
        switch kind {
        case .paired:
            return [openingTagRange] + (closingTagRange.map { [$0] } ?? [])
        case .selfClosing:
            return [openingTagRange]
        }
    }
}

/// Extracts paired and self-closing JSX tags from the TSX syntax tree that was
/// already produced for highlighting. No second parse is performed.
enum JSXTagMatcher {
    static func matches(in root: TSNode, bytes: UnsafeBufferPointer<UInt8>,
                        mapper: ByteMapper) -> [JSXTagMatch] {
        var result: [JSXTagMatch] = []

        func visit(_ node: TSNode) {
            switch String(cString: ts_node_type(node)) {
            case "jsx_element":
                if let match = pairedMatch(node, bytes: bytes, mapper: mapper) {
                    result.append(match)
                }
            case "jsx_self_closing_element":
                if let match = selfClosingMatch(node, bytes: bytes, mapper: mapper) {
                    result.append(match)
                }
            default:
                break
            }

            for index in 0..<ts_node_named_child_count(node) {
                visit(ts_node_named_child(node, index))
            }
        }

        visit(root)
        return result
    }

    private static func pairedMatch(_ element: TSNode,
                                    bytes: UnsafeBufferPointer<UInt8>,
                                    mapper: ByteMapper) -> JSXTagMatch? {
        guard let opening = child(element, field: "open_tag"),
              let closing = child(element, field: "close_tag"),
              !ts_node_has_error(opening), !ts_node_has_error(closing),
              namesMatch(opening: opening, closing: closing, bytes: bytes),
              let openingTag = range(of: opening, mapper: mapper),
              let closingTag = range(of: closing, mapper: mapper),
              let openingStart = delimiterRange(atByte: Int(ts_node_start_byte(opening)),
                                                expected: 0x3C,
                                                bytes: bytes, mapper: mapper),
              let openingHead = openingHeadRange(of: opening, mapper: mapper),
              let openingEnd = endingDelimiterRange(of: opening, bytes: bytes,
                                                     mapper: mapper),
              let closingEnd = endingDelimiterRange(of: closing, bytes: bytes,
                                                     mapper: mapper) else { return nil }

        return JSXTagMatch(kind: .paired,
                           openingTagRange: openingTag,
                           closingTagRange: closingTag,
                           openingAngleRange: openingStart,
                           openingHeadRange: openingHead,
                           openingTerminatorRange: openingEnd,
                           closingTerminatorRange: closingEnd)
    }

    private static func selfClosingMatch(_ element: TSNode,
                                         bytes: UnsafeBufferPointer<UInt8>,
                                         mapper: ByteMapper) -> JSXTagMatch? {
        guard !ts_node_has_error(element),
              let whole = range(of: element, mapper: mapper) else { return nil }
        let start = Int(ts_node_start_byte(element))
        let end = Int(ts_node_end_byte(element))
        guard start >= 0, end >= start + 3, end <= bytes.count,
              bytes[start] == 0x3C, bytes[end - 2] == 0x2F, bytes[end - 1] == 0x3E,
              let opening = delimiterRange(atByte: start, expected: 0x3C,
                                           bytes: bytes, mapper: mapper),
              let closing = delimiterRange(atByte: end - 1, expected: 0x3E,
                                           bytes: bytes, mapper: mapper) else { return nil }

        return JSXTagMatch(kind: .selfClosing,
                           openingTagRange: whole,
                           closingTagRange: nil,
                           openingAngleRange: opening,
                           openingHeadRange: opening,
                           openingTerminatorRange: closing,
                           closingTerminatorRange: closing)
    }

    private static func namesMatch(opening: TSNode, closing: TSNode,
                                   bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let openingName = child(opening, field: "name")
        let closingName = child(closing, field: "name")
        switch (openingName, closingName) {
        case (nil, nil):
            return true // React fragment: <>...</>
        case let (lhs?, rhs?):
            let lhsStart = Int(ts_node_start_byte(lhs))
            let lhsEnd = Int(ts_node_end_byte(lhs))
            let rhsStart = Int(ts_node_start_byte(rhs))
            let rhsEnd = Int(ts_node_end_byte(rhs))
            guard lhsStart >= 0, rhsStart >= 0,
                  lhsEnd <= bytes.count, rhsEnd <= bytes.count,
                  lhsStart <= lhsEnd, rhsStart <= rhsEnd,
                  lhsEnd - lhsStart == rhsEnd - rhsStart else { return false }
            return bytes[lhsStart..<lhsEnd].elementsEqual(bytes[rhsStart..<rhsEnd])
        default:
            return false
        }
    }

    private static func child(_ node: TSNode, field: String) -> TSNode? {
        let found = field.withCString {
            ts_node_child_by_field_name(node, $0, UInt32(strlen($0)))
        }
        return ts_node_is_null(found) ? nil : found
    }

    private static func range(of node: TSNode, mapper: ByteMapper) -> NSRange? {
        range(fromByte: Int(ts_node_start_byte(node)),
              toByte: Int(ts_node_end_byte(node)), mapper: mapper)
    }

    private static func openingHeadRange(of opening: TSNode,
                                         mapper: ByteMapper) -> NSRange? {
        let start = Int(ts_node_start_byte(opening))
        if let name = child(opening, field: "name") {
            return range(fromByte: start, toByte: Int(ts_node_end_byte(name)),
                         mapper: mapper)
        }
        // A fragment has no name, so its complete `<>` token is the head.
        return range(of: opening, mapper: mapper)
    }

    private static func range(fromByte start: Int, toByte end: Int,
                              mapper: ByteMapper) -> NSRange? {
        guard let lower = mapper.utf16(forByte: start),
              let upper = mapper.utf16(forByte: end), upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func endingDelimiterRange(of node: TSNode,
                                             bytes: UnsafeBufferPointer<UInt8>,
                                             mapper: ByteMapper) -> NSRange? {
        let end = Int(ts_node_end_byte(node))
        guard end > 0 else { return nil }
        return delimiterRange(atByte: end - 1, expected: 0x3E,
                              bytes: bytes, mapper: mapper)
    }

    private static func delimiterRange(atByte byte: Int, expected: UInt8,
                                       bytes: UnsafeBufferPointer<UInt8>,
                                       mapper: ByteMapper) -> NSRange? {
        guard bytes.indices.contains(byte), bytes[byte] == expected,
              let lower = mapper.utf16(forByte: byte),
              let upper = mapper.utf16(forByte: byte + 1) else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}
