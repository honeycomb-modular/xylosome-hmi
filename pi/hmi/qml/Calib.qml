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

import QtCore
import QtQuick

QtObject {
    id: calib

    // The doorframe measurement, as a plain constant. It was briefly backed by a
    // Settings object whose alias pointed back at this very property — a
    // circular binding that froze the HMI the moment a page touched Calib.
    readonly property real measuredLinesPerDeg: 150.65

    // ── TDI sync override (settings ▸ calibration ▸ tdi.sync) ──────────────────
    // TDI is only sharp when the subject image advances one pixel per trigger,
    // and the stage count multiplies any error: at 48 stages it must be right to
    // ~2%. The right value depends on the subject's distance from the axis, so
    // one constant cannot serve every scene — the modes had already drifted
    // apart (this file 150.65, curve scan 175.3 via C = 9310, timed 150).
    // When enabled, EVERY mode uses syncLinesPerDeg; disabled, each keeps its
    // own number exactly as before. Found by sweeping it on a constant-speed
    // scan and scoring sharpness.
    //
    // Settings is held privately and only ever READ by the bindings below and
    // WRITTEN by the setters — no alias, so no path back into itself.
    property Settings _store: Settings {
        category: "calib"
        property bool syncEnabled: false
        property real syncLinesPerDeg: 175.3
    }
    readonly property bool syncEnabled:     calib._store.syncEnabled
    readonly property real syncLinesPerDeg: calib._store.syncLinesPerDeg
    function setSyncEnabled(on)    { calib._store.syncEnabled = on }
    function setSyncLinesPerDeg(v) { calib._store.syncLinesPerDeg = v }

    // A mode's own lines-per-degree, unless the sync override is on.
    function linesPerDegOr(own) {
        return calib._store.syncEnabled ? calib._store.syncLinesPerDeg : own
    }

    readonly property real linesPerDeg: calib._store.syncEnabled
                                        ? calib._store.syncLinesPerDeg
                                        : calib.measuredLinesPerDeg

    // The geometrically correct line count for a sweep of `arcDeg`.
    function linesForArc(arcDeg) {
        return Math.max(1, Math.round(calib.linesPerDeg * Math.abs(arcDeg)))
    }
    // The trigger rate that sweep runs at — independent of the arc.
    function rateForSpeed(degPerSec) {
        return calib.linesPerDeg * degPerSec
    }
    // Fixed time the sweep loses at the start of every pass. The trigger is paced
    // off COMMANDED motion, so it begins clocking while the axis is still
    // accelerating, and the catch-up costs a constant interval — which becomes a
    // different ANGLE at each speed. Measured 2026-08-09 from a 3-bracket hdr set,
    // locating a doorframe edge in each frame:
    //
    //   220 -> 110 deg/s : 447.1 lines shift  ->  t = 26.98 ms
    //   220 ->  55 deg/s : 675.4 lines shift  ->  t = 27.17 ms
    //
    // Two brackets agreeing to 0.7%, so it is a constant rather than a fit. Modes
    // that ran passes at DIFFERENT speeds had to offset each pass by lead*velocity
    // or the frames did not register; same-speed modes shared the error.
    //
    // 2026-09-13: xylod now delays the trigger itself by this measured lag
    // (`line_lag_ms = 27.1` in xylod.conf), so the offset is gone at the source —
    // and so is the TDI smear the same lag caused on speed curves, which a
    // head-start here could never fix. Hence 0: adding a lead on top would now
    // shift the brackets the other way. If line_lag_ms is ever set back to 0,
    // put 0.0271 back here.
    readonly property real triggerLeadSec: 0.0

    // Angular head-start a sweep at this speed needs to line up with the others.
    function leadDeg(degPerSec) { return calib.triggerLeadSec * degPerSec }

    // Field width that yields a square image against the 8192 px sensor axis.
    readonly property real squareArcDeg: 8192 / calib.linesPerDeg
}
