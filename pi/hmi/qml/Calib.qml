pragma Singleton
// Calib.qml — the geometric calibration, in one place.
//
// TDI only works when the subject advances exactly ONE PIXEL per line trigger.
// That ratio is fixed by the optics and the subject's radius from the axis; it
// is NOT a free parameter. Ask for more lines over an arc than the optics
// deliver and three things go wrong at once:
//   · the image stretches along the scan axis
//   · TDI smears, because each stage integrates a different subject line
//   · the frame cannot fill inside its pass, so the capture agent's grab stays
//     open into the NEXT pass and one file ends up holding two exposures
//
// Every mode used to default to lines: 22200 regardless of arc, which can only
// be right at one field width. Measured 2026-08-09 against a scan confirmed
// correct by eye: 26726 lines over 177.4 deg (arc -76.0 -> 101.4).
//
//     26726 / 177.4 = 150.65 lines per degree
//
// A useful consequence: baseHz = lines * maxVel / arc, and lines =
// linesPerDeg * arc, so the arc CANCELS —
//
//     baseHz = linesPerDeg * maxVel
//
// The trigger rate depends only on sweep speed, never on how wide the field is.
// That is what bounds exposure bracketing: the camera will not sync below
// 3500 Hz, so the room to slow a pass down comes from the base speed alone.
//
// Re-measure by scanning something round: lines scale linearly, so if it comes
// out 1.4x too tall, multiply this by 1.4.

import QtQuick

QtObject {
    id: calib

    // Deliberately a plain constant, NOT persisted. It was briefly backed by a
    // Settings object whose alias pointed back at this very property — a
    // circular binding that froze the HMI the moment a page touched Calib.
    // A calibration measured once a year does not justify that risk; re-measure
    // by editing this number.
    readonly property real linesPerDeg: 150.65

    // The geometrically correct line count for a sweep of `arcDeg`.
    function linesForArc(arcDeg) {
        return Math.max(1, Math.round(calib.linesPerDeg * Math.abs(arcDeg)))
    }
    // The trigger rate that sweep runs at — independent of the arc.
    function rateForSpeed(degPerSec) {
        return calib.linesPerDeg * degPerSec
    }
    // Field width that yields a square image against the 8192 px sensor axis.
    readonly property real squareArcDeg: 8192 / calib.linesPerDeg
}
