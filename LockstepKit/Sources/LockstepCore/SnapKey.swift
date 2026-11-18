// Holding Command turns snapping the other way for as long as it is held: off when it is on, on when it
// is off. The setting `editing.snapping` itself never changes, and the snapping button keeps showing it.
// Every place that snaps (moving clips, trimming an edge, marking a stretch, the playhead in the ruler and
// the edges of the song) asks this one answer, at every movement:
//
//     let snaps = settings.snappingHolds(commandHeld: NSEvent.modifierFlags.contains(.command))
//
// Command, because it is free during a drag: Option makes a copy of a dragged clip, Shift keeps a moved
// clip's time, and a Control-click is a right-click on a Mac. Ableton Live uses Command on a Mac too.

/// The key that turns snapping the other way while it is held.
public enum SnapKey {
    /// Whether snapping holds right now.
    ///
    /// - Parameters:
    ///   - isOn: the setting `editing.snapping`.
    ///   - commandHeld: whether Command is held at this moment.
    public static func snappingHolds(isOn: Bool, commandHeld: Bool) -> Bool {
        isOn != commandHeld
    }
}

extension AppSettings {
    /// Whether snapping holds right now: the setting `snapping`, turned the other way while Command is held.
    /// Only read: the setting stays as it is.
    public func snappingHolds(commandHeld: Bool) -> Bool {
        SnapKey.snappingHolds(isOn: self[.snapping], commandHeld: commandHeld)
    }
}
