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

    // Metadata overlay (Pi SVG) — placement normalized to image size.
    // Drag moves; the corner handle scales; placementChanged fires on release.
    property string metaSource: ""
    property real metaX: 0.04
    property real metaY: 0.78
    property real metaW: 0.25
    property bool metaVisible: true
    signal placementChanged(real x, real y, real w)

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

            // ── metadata block — part of the print: lives in IMAGE
            //    coordinates, so it always scales with the image. Drag and
            //    the corner handle write gesture offsets (gx/gy/gw, image
            //    px) layered over the bindings — zoom tracking can never
            //    break, during or after a gesture.
            Image {
                id: meta
                property real gx: 0
                property real gy: 0
                property real gw: 0
                visible: view.metaVisible && view.metaSource !== ""
                source: view.metaSource !== ""
                        ? "file:///" + view.metaSource.replace(/^\//, "") : ""
                x: (view.metaX * view.imgW + gx) * view.zoom
                y: (view.metaY * view.imgH + gy) * view.zoom
                width: Math.max(8, (view.metaW * view.imgW + gw) * view.zoom)
                height: status === Image.Ready && implicitWidth > 0
                        ? width * implicitHeight / implicitWidth : width * 0.35
                // re-rasterize the vector at (quantized) display width so
                // the typography stays crisp at any zoom — it's the art
                sourceSize.width: Math.min(4096, Math.max(256, Math.ceil(width / 256) * 256))
                fillMode: Image.PreserveAspectFit
                asynchronous: true

                function commit() {
                    view.placementChanged(view.metaX + gx / view.imgW,
                                          view.metaY + gy / view.imgH,
                                          view.metaW + gw / view.imgW)
                    gx = 0; gy = 0; gw = 0
                }

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: metaDrag.containsMouse || metaDrag.pressed
                                  || handleArea.containsMouse || handleArea.pressed ? 1 : 0
                    border.color: "#1A1A1A"
                }

                MouseArea {
                    id: metaDrag
                    anchors.fill: parent
                    // tiny block stays draggable: grow the hit area to at
                    // least 28 px so the pan gesture can't steal it
                    anchors.margins: -Math.max(0,
                        (28 - Math.min(meta.width, meta.height)) / 2)
                    preventStealing: true   // the Flickable must NEVER take
                                            // over a drag that began here
                    hoverEnabled: true
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real px: 0
                    property real py: 0
                    onPressed: (m) => { px = m.x; py = m.y }
                    onPositionChanged: (m) => {
                        if (!pressed) return
                        meta.gx += (m.x - px) / view.zoom
                        meta.gy += (m.y - py) / view.zoom
                    }
                    onReleased: meta.commit()
                }

                // scale handle — visible while the block is big enough on
                // screen for the handle not to swallow it; for a tiny block,
                // zoom in and the handle returns at a workable size
                Rectangle {
                    width: 12
                    height: 12
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    visible: meta.width > 32
                    color: handleArea.pressed ? "#1A1A1A" : "#B3FFFFFF"
                    border.width: 1
                    border.color: "#1A1A1A"
                    MouseArea {
                        id: handleArea
                        anchors.fill: parent
                        anchors.margins: -10
                        preventStealing: true
                        hoverEnabled: true
                        cursorShape: Qt.SizeFDiagCursor
                        property real px: 0
                        onPressed: (m) => px = m.x
                        onPositionChanged: (m) => {
                            if (!pressed) return
                            meta.gw += (m.x - px) / view.zoom
                        }
                        onReleased: meta.commit()
                    }
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
