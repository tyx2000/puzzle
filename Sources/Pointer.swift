import AppKit

/// The pointer as read between events: where it is, and which buttons are
/// held. Views that light what is under them ask this rather than AppKit,
/// because AppKit answers with the real mouse whether or not the window is on
/// screen — and in a test run the real mouse is wherever the person running
/// it has left it. A history list laid out under a resting pointer lit that
/// row, and the keys then counted from it.
///
/// `pinnedForTesting` replaces the answer. The regression suite pins it
/// somewhere no window is, and a test that needs the pointer over something
/// puts it there.
enum Pointer {
    struct Pin {
        var location: NSPoint
        var pressedButtons = 0
    }
    static var pinnedForTesting: Pin?

    /// Where the pointer is, in screen coordinates.
    static var location: NSPoint {
        pinnedForTesting?.location ?? NSEvent.mouseLocation
    }
    /// The mouse buttons held down, as a bit mask; 0 when none is.
    static var pressedButtons: Int {
        pinnedForTesting?.pressedButtons ?? NSEvent.pressedMouseButtons
    }
}

extension NSWindow {
    /// Where the pointer is, in this window's coordinates — whether or not
    /// an event has said so.
    var pointerLocation: NSPoint {
        guard let pin = Pointer.pinnedForTesting else { return mouseLocationOutsideOfEventStream }
        return convertPoint(fromScreen: pin.location)
    }
}
