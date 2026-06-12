// ZoomView — deep-zoom viewer over a vips dz tile pyramid.
//
// Streams only the tiles in view at the level matching the current zoom —
// a >1 GB scan pans and zooms with nothing but small JPEG reads
// (plan → Proxy pipeline). zoom = display px per original px; 1.0 = 1:1.
//
// Input: tileBase (".../pass_0" → tiles at pass_0_files/<level>/<x>_<y>.jpg),
// imgW/imgH (original pixels). Wheel zooms about the cursor, drag pans,
// double-click toggles fit ⇄ 1:1.

import QtQuick

Item {
    id: view
    clip: true   // tiles must never paint over the chrome around the field

    property string tileBase: ""
    property int imgW: 0
    property int imgH: 0

    readonly property real fitZoom: (imgW > 0 && imgH > 0 && width > 0 && height > 0)
        ? Math.min(width / imgW, height / imgH) : 1
    property real zoom: fitZoom
    readonly property bool atFit: Math.abs(zoom - fitZoom) < 1e-9

    readonly property int tileSize: 256
    readonly property int maxLevel: (imgW > 0 && imgH > 0)
        ? Math.ceil(Math.log2(Math.max(imgW, imgH))) : 0

    // level whose scale (2^(level-maxLevel)) is the smallest ≥ zoom
    readonly property int level: {
        if (imgW <= 0) return 0
        let l = maxLevel + Math.ceil(Math.log2(Math.max(zoom, 1e-6)))
        return Math.max(0, Math.min(maxLevel, l))
    }
    readonly property real levelScale: Math.pow(2, level - maxLevel)

    property var tiles: []

    onTileBaseChanged: { zoom = Qt.binding(() => fitZoom); rebuild() }
    onZoomChanged: rebuild()
    onWidthChanged: rebuild()
    onHeightChanged: rebuild()

    function clampPan() {
        const cw = imgW * zoom, ch = imgH * zoom
        flick.contentX = cw <= width ? (cw - width) / 2
                       : Math.max(0, Math.min(flick.contentX, cw - width))
        flick.contentY = ch <= height ? (ch - height) / 2
                       : Math.max(0, Math.min(flick.contentY, ch - height))
    }

    function rebuild() {
        if (tileBase === "" || imgW <= 0) { tiles = []; return }
        if (atFit) clampPan()   // center when smaller than the viewport
        const lw = Math.ceil(imgW * levelScale)
        const lh = Math.ceil(imgH * levelScale)
        const disp = zoom / levelScale            // display px per level px
        const x0 = Math.max(0, Math.floor(flick.contentX / (tileSize * disp)))
        const y0 = Math.max(0, Math.floor(flick.contentY / (tileSize * disp)))
        const x1 = Math.min(Math.ceil(lw / tileSize) - 1,
                            Math.floor((flick.contentX + width) / (tileSize * disp)))
        const y1 = Math.min(Math.ceil(lh / tileSize) - 1,
                            Math.floor((flick.contentY + height) / (tileSize * disp)))
        const out = []
        for (let ty = y0; ty <= y1; ty++)
            for (let tx = x0; tx <= x1; tx++) {
                const w = Math.min(tileSize, lw - tx * tileSize)
                const h = Math.min(tileSize, lh - ty * tileSize)
                out.push({
                    url: "file:///" + (tileBase + "_files/" + level + "/"
                                       + tx + "_" + ty + ".jpg").replace(/^\//, ""),
                    x: tx * tileSize * disp,
                    y: ty * tileSize * disp,
                    w: w * disp,
                    h: h * disp
                })
            }
        tiles = out
    }

    function zoomTo(z, cx, cy) {
        // keep the content point under (cx, cy) stationary
        // 1600 % ceiling: pixel-level inspection; floor never below fit
        z = Math.max(Math.min(fitZoom, 1), Math.min(z, Math.max(16, fitZoom)))
        const px = (flick.contentX + cx) / zoom
        const py = (flick.contentY + cy) / zoom
        zoom = z
        flick.contentX = px * zoom - cx
        flick.contentY = py * zoom - cy
        clampPan()
        rebuild()
    }

    function toggleFit(cx, cy) {
        if (atFit) zoomTo(1, cx === undefined ? width / 2 : cx,
                             cy === undefined ? height / 2 : cy)
        else { zoom = Qt.binding(() => fitZoom); clampPan(); rebuild() }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: view.imgW * view.zoom
        contentHeight: view.imgH * view.zoom
        boundsBehavior: Flickable.StopAtBounds
        onContentXChanged: view.rebuild()
        onContentYChanged: view.rebuild()
        interactive: !view.atFit

        Item {
            width: flick.contentWidth
            height: flick.contentHeight
            Repeater {
                model: view.tiles
                Image {
                    required property var modelData
                    x: modelData.x
                    y: modelData.y
                    width: modelData.w
                    height: modelData.h
                    source: modelData.url
                    asynchronous: true
                    smooth: view.zoom < 1.5   // crisp pixels past 1:1
                }
            }
        }
    }

    WheelHandler {
        target: null
        onWheel: (ev) => {
            const factor = Math.pow(1.0015, ev.angleDelta.y)
            view.zoomTo(view.zoom * factor, ev.x, ev.y)
        }
    }

    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onDoubleTapped: (ev) => view.toggleFit(ev.position.x, ev.position.y)
    }

    PinchHandler {
        target: null
        property real startZoom: 1
        onActiveChanged: if (active) startZoom = view.zoom
        onScaleChanged: view.zoomTo(startZoom * activeScale,
                                    centroid.position.x, centroid.position.y)
    }
}
