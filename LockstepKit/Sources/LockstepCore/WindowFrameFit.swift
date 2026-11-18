/// A rectangle in AppKit's screen coordinates: the origin is the bottom-left
/// corner and y grows upwards.
public struct FrameRect: Equatable, Sendable, Codable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum WindowFrameFit {
    /// The frame to give the window, or nil when there is no screen to fit it into.
    ///
    /// `screens` holds each screen's usable area. A saved frame that lies completely
    /// inside one of them comes back unchanged. Otherwise the answer is the frame,
    /// on any screen, that changes the saved one least: size first, then distance.
    public static func fit(_ saved: FrameRect, into screens: [FrameRect],
                           minimumWidth: Double, minimumHeight: Double) -> FrameRect? {
        if screens.contains(where: { contains(saved, in: $0) }) {
            return saved
        }

        var best: (frame: FrameRect, sizeChange: Double, distance: Double)?
        for screen in screens {
            let frame = candidate(for: saved, on: screen,
                                  minimumWidth: minimumWidth, minimumHeight: minimumHeight)
            let sizeChange = abs(frame.width - saved.width) + abs(frame.height - saved.height)
            let distance = abs(frame.x - saved.x) + abs(frame.y - saved.y)
            // Strictly smaller only, so the earlier screen keeps a tie.
            if let current = best,
               (current.sizeChange, current.distance) <= (sizeChange, distance) {
                continue
            }
            best = (frame, sizeChange, distance)
        }
        return best?.frame
    }

    private static func contains(_ frame: FrameRect, in screen: FrameRect) -> Bool {
        frame.x >= screen.x
            && frame.y >= screen.y
            && frame.x + frame.width <= screen.x + screen.width
            && frame.y + frame.height <= screen.y + screen.height
    }

    private static func candidate(for saved: FrameRect, on screen: FrameRect,
                                  minimumWidth: Double, minimumHeight: Double) -> FrameRect {
        let width = max(min(saved.width, screen.width), minimumWidth)
        let height = max(min(saved.height, screen.height), minimumHeight)

        // Wider than the screen can only happen because of the minimum: keep the left edge on it.
        let x = width > screen.width
            ? screen.x
            : min(max(saved.x, screen.x), screen.x + screen.width - width)
        // Taller than the screen: keep the top edge on it, so the title bar stays reachable.
        let y = height > screen.height
            ? screen.y + screen.height - height
            : min(max(saved.y, screen.y), screen.y + screen.height - height)

        return FrameRect(x: x, y: y, width: width, height: height)
    }
}
