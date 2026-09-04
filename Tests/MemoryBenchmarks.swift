import AppKit
import AVKit
import PDFKit

/// Each scenario runs in a fresh process; generate fixtures separately so their
/// construction does not contaminate the measured memory footprint.
@main
enum MemoryBenchmarks {
    static let directory = URL(fileURLWithPath: "/tmp/puzzle-memory-fixtures", isDirectory: true)

    static func memory(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            print(String(format: "%@: footprint=%.2f MiB peak=%.2f MiB", label,
                         Double(info.phys_footprint) / 1_048_576,
                         Double(info.ledger_phys_footprint_peak) / 1_048_576))
        }
    }

    static func main() throws {
        _ = NSApplication.shared
        let scenario = CommandLine.arguments.dropFirst().first ?? "parser"
        if scenario == "fixtures" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = NSImage(size: NSSize(width: 4096, height: 4096), flipped: false) { rect in
                NSColor.systemOrange.setFill(); rect.fill(); return true
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .jpeg, properties: [:])!.write(
                to: directory.appendingPathComponent("image.jpg"))
            let pdf = PDFDocument()
            pdf.insert(PDFPage(image: NSImage(size: NSSize(width: 420, height: 594),
                flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true })!, at: 0)
            pdf.write(to: directory.appendingPathComponent("document.pdf"))
            // One second of silent 16-bit mono PCM, 8 kHz.
            var wav = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
            }
            append(UInt32(16036)); wav.append(Data("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
            append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16))
            wav.append(Data("data".utf8)); append(UInt32(16000)); wav.append(Data(count: 16000))
            try wav.write(to: directory.appendingPathComponent("audio.wav"))
            try Data("plain text".utf8).write(to: directory.appendingPathComponent("text.txt"))
            return
        }
        if scenario == "parser" {
            let definition = LanguageDefinition(name: "javascript", language: tree_sitter_tsx()!,
                querySources: ["(identifier) @variable (number) @number (string) @string"],
                extensions: ["js"], display: "JavaScript")
            let highlighter = SyntaxHighlighter(definition: definition)!
            let storage = NSTextStorage(string: (0..<2000).map {
                "const value\($0) = {name: 'hello', count: \($0)};"
            }.joined(separator: "\n"))
            var elapsed = 0.0
            for index in 0..<41 {
                autoreleasepool {
                    storage.replaceCharacters(in: NSRange(location: 0, length: index == 0 ? 0 : 1),
                                              with: index % 2 == 0 ? " " : "\n")
                    let start = CFAbsoluteTimeGetCurrent()
                    highlighter.highlight(text: storage.string, storage: storage,
                        fullRange: NSRange(location: 0, length: storage.length))
                    if index > 0 { elapsed += CFAbsoluteTimeGetCurrent() - start }
                }
            }
            print(String(format: "40 edits: %.2f ms/edit", elapsed * 1000 / 40))
            memory("parser")
            return
        }
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        func open(_ filename: String) {
            autoreleasepool {
                pane.open(url: directory.appendingPathComponent(filename))
                pane.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                pane.view.displayIfNeeded()
            }
        }
        if scenario == "audio" {
            open("audio.wav")
        } else if scenario == "image" {
            open("image.jpg")
        } else {
            for _ in 0..<5 {
                open("image.jpg"); open("audio.wav"); open("document.pdf"); open("text.txt")
            }
        }
        memory(scenario)
        print("retained preview views: \(pane.view.subviews.filter { $0 is ImagePreviewView || $0 is MediaPreviewView || $0 is PDFPreviewView }.count)")
        pane.prepareForClose()
        window.close()
    }
}
