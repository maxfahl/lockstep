import SwiftUI

/// What the calibrate sheet and the delay readout tell their owner. The owner
/// answers by changing `MainLayoutContent.calibration`, which is what the
/// sheet shows, and by taking it away to close the sheet:
///
///     var calibration = CalibrationActions()
///     calibration.readoutPressed = { model.openCalibrateSheet() }
///     calibration.startPressed = { model.startCalibration() }
///     calibration.closed = { model.closeCalibrateSheet() }
///     actions.calibration = calibration
///
/// The layout itself measures nothing and keeps nothing. Without these the
/// delay readout is not a button and no sheet is opened, as in the design lab.
public struct CalibrationActions {
    /// The delay readout in the panel on the right was pressed.
    public var readoutPressed: (@MainActor () -> Void)?

    /// Start, Try Again or Measure Again was pressed in the sheet.
    public var startPressed: (@MainActor () -> Void)?

    /// Close or Done was pressed in the sheet, or the sheet was closed with
    /// the Escape key.
    public var closed: (@MainActor () -> Void)?

    public init() {}
}
