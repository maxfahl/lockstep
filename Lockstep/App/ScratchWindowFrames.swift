import AppKit
import ObjectiveC

/// Keeps every window's place out of Max's settings while Lockstep runs in a scratch folder.
///
/// macOS saves a window's place in the app's standard settings (the key "NSWindow Frame
/// <name>") as soon as the window is given a name to save it under, and reads the saved
/// place at that same moment. SwiftUI gives the main window that name while creating it,
/// before any of Lockstep's views can step in. For a scratch run, the four window methods
/// that set, read and save such a place are made to do nothing, before any window exists.
/// Lockstep's own frame memory keeps the scratch window's place in the scratch folder.
enum ScratchWindowFrames {
    /// Call once at start, before the first window is created, and only for a scratch run.
    @MainActor static func keepOutOfMaxSettings() {
        replace(#selector(NSWindow.setFrameAutosaveName(_:)), with: acceptNameButKeepNone())
        replace(#selector(NSWindow.setFrameUsingName(_:)), with: readNothing())
        replace(#selector(NSWindow.setFrameUsingName(_:force:)), with: readNothingForced())
        replace(#selector(NSWindow.saveFrame(usingName:)), with: saveNothing())
    }

    private static func replace(_ selector: Selector, with block: Any) {
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // The blocks below hold no state and touch nothing, so it does not matter on which
    // thread AppKit calls them.

    /// Says yes, so SwiftUI goes on as usual, but keeps no name: macOS then neither reads
    /// a saved place now nor saves one when the window moves.
    nonisolated private static func acceptNameButKeepNone() -> Any {
        let block: @convention(block) @Sendable (AnyObject, NSString) -> ObjCBool = { _, _ in
            true
        }
        return block
    }

    /// Answers that nothing was saved under that name.
    nonisolated private static func readNothing() -> Any {
        let block: @convention(block) @Sendable (AnyObject, NSString) -> ObjCBool = { _, _ in
            false
        }
        return block
    }

    nonisolated private static func readNothingForced() -> Any {
        let block: @convention(block) @Sendable (AnyObject, NSString, ObjCBool) -> ObjCBool = {
            _, _, _ in false
        }
        return block
    }

    nonisolated private static func saveNothing() -> Any {
        let block: @convention(block) @Sendable (AnyObject, NSString) -> Void = { _, _ in }
        return block
    }
}
