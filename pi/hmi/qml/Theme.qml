pragma Singleton
// Theme.qml — colour and typography tokens.
// Direct port of include/ui/theme.h
//
// Usage (any QML file):
//   import XylosomeHMI 1.0
//   color: Theme.accent
//   font.pixelSize: Theme.fontH1

import QtQuick

QtObject {

    // ── Surfaces ──────────────────────────────────────────────────────────────
    readonly property color bg:         "#050505"
    readonly property color panel:      "#0E0E0E"
    readonly property color border:     "#262626"
    readonly property color borderDim: "#1A1A1A"

    // ── Text greyscale ────────────────────────────────────────────────────────
    readonly property color colorText:       "#ECECEC"   // primary
    readonly property color colorTextDim:   "#888888"   // secondary
    readonly property color colorTextFaint: "#4A4A4A"   // tertiary

    // ── Reserved meaningful colours ───────────────────────────────────────────
    readonly property color accent:     "#4ADE80"   // active / live / OK
    readonly property color accentDim: "#1F6E3A"
    readonly property color danger:     "#F87171"   // offline / error / warning

    // ── Font sizes (pixel) ────────────────────────────────────────────────────
    // Maps 1-to-1 with the LVGL font sizes:
    //   fontMonoS  = lv_font_montserrat_12
    //   fontMonoM  = lv_font_montserrat_16
    //   fontLabel  = lv_font_montserrat_14
    //   fontBody   = lv_font_montserrat_16
    //   fontH2     = lv_font_montserrat_24
    //   fontH1     = lv_font_montserrat_28
    readonly property int fontMonoS: 14
    readonly property int fontMonoM: 18
    readonly property int fontLabel: 16
    readonly property int fontBody:  18
    readonly property int fontH2:    27
    readonly property int fontH1:    32

    // ── Font families ─────────────────────────────────────────────────────────
    // Install Montserrat on Pi:  sudo apt install fonts-montserrat
    // Falls back to Roboto or Liberation Sans if Montserrat is absent.
    readonly property string fontFamily:     "Courier New, Courier, DejaVu Sans Mono, Liberation Mono, monospace"
    readonly property string fontFamilyMono: "Courier New, Courier, DejaVu Sans Mono, Liberation Mono, monospace"

    // ── Layout grid ─────────────────────────────────────────────────────────────
    // Single source of truth for screen geometry so every page lines up.
    readonly property int marginX:      18     // standard left/right content margin
    readonly property int contentW:    924     // 960 - 2*marginX
    readonly property int titleY:       25     // screen title baseline-ish
    readonly property int hairlineTopY: 63     // header divider
    readonly property int contentTop:   72     // first list row y (no header rule)
    readonly property int rowStride:    52     // vertical distance between list rows
    readonly property int rowHeight:    44     // row visual / touch height
    readonly property int bottomBarY:  462     // bottom-bar divider
    readonly property int bottomBtnW:  130     // standard [back]/action button width
    readonly property int bottomBtnH:   45

    // ── Focus visuals ───────────────────────────────────────────────────────────
    readonly property int  focusBarW:    3      // left accent bar on focused rows
    readonly property real focusFillOpacity: 0.12
}
