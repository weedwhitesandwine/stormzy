import QtQuick
import "."
import "Geo.js" as Geo

// The map: a bundled Natural Earth basemap drawn in theme colours, radar
// tiles for one frame over it, and the place marker. Tiles come from the
// helper as files on disk; this item never fetches anything itself.
Item {
  id: map

  property real centerLat: 35.68
  property real centerLon: 139.69
  property real zoom: 7
  property string provider: ""
  property string frameId: ""
  property int nativeZoom: 8
  property int scheme: 2
  property color foreground: "#cccccc"
  property color background: "#101315"
  property color accent: "#7aa2f7"
  property color muted: "#707880"
  property string fontFamily: "sans-serif"
  property int fontSize: 12
  property var marker: null          // {lat, lon}
  onMarkerChanged: overlay.requestPaint()
  property bool interactive: true

  signal userMoved()

  readonly property real minZoom: 3
  readonly property real maxZoom: 11
  // Tiles are fetched at an integer zoom no finer than the provider's native
  // one and scaled to the real zoom, so zooming past native just enlarges.
  readonly property int tz: Math.max(2, Math.min(map.nativeZoom, Math.round(map.zoom)))
  readonly property real scale: Math.pow(2, map.zoom - map.tz)
  readonly property real worldSize: Geo.worldSize(map.tz)
  readonly property real worldCx: Geo.lon2x(map.centerLon, map.tz)
  readonly property real worldCy: Geo.lat2y(map.centerLat, map.tz)
  readonly property int tileCount: 1 << map.tz

  readonly property int maxTilesOnScreen: 96

  // ------------------------------------------------------------ geometry

  function screenToLonLat(sx, sy) {
    var wx = map.worldCx + (sx - map.width / 2) / map.scale
    var wy = map.worldCy + (sy - map.height / 2) / map.scale
    return { lon: Geo.x2lon(wx, map.tz), lat: Geo.y2lat(wy, map.tz) }
  }

  function lonLatToScreen(lon, lat) {
    return {
      x: (Geo.lon2x(lon, map.tz) - map.worldCx) * map.scale + map.width / 2,
      y: (Geo.lat2y(lat, map.tz) - map.worldCy) * map.scale + map.height / 2
    }
  }

  function viewBbox() {
    var a = screenToLonLat(0, map.height)
    var b = screenToLonLat(map.width, 0)
    return [a.lon, a.lat, b.lon, b.lat]
  }

  function pan(dx, dy) {
    var cx = map.worldCx - dx / map.scale
    var cy = map.worldCy - dy / map.scale
    map.centerLon = Geo.wrapLon(Geo.x2lon(cx, map.tz))
    map.centerLat = Geo.clampLat(Geo.y2lat(cy, map.tz))
  }

  function zoomBy(delta, sx, sy) {
    var next = Math.max(map.minZoom, Math.min(map.maxZoom, map.zoom + delta))
    if (next === map.zoom) return
    if (sx === undefined) { sx = map.width / 2; sy = map.height / 2 }
    var before = screenToLonLat(sx, sy)
    map.zoom = next
    var after = lonLatToScreen(before.lon, before.lat)
    pan(sx - after.x, sy - after.y)
  }

  function setView(lat, lon, z) {
    map.centerLat = Geo.clampLat(lat)
    map.centerLon = Geo.wrapLon(lon)
    if (z !== undefined) map.zoom = Math.max(map.minZoom, Math.min(map.maxZoom, z))
  }

  // ---------------------------------------------------------------- tiles
  //
  // Two layers. The front one is what is on screen; a frame change fills the
  // back one and swaps when its tiles are in (or soon enough), so playback
  // steps without the map going blank between frames. A pan or zoom on the
  // same frame edits the front layer in place.

  property var tilePaths: ({})
  property int tilePathCount: 0
  property bool frontIsA: true
  property string frontFrame: ""
  property int frontZ: -1
  property string backFrame: ""
  property int backZ: -1
  property bool backLoading: false

  ListModel { id: modelA }
  ListModel { id: modelB }

  function frontModel() { return map.frontIsA ? modelA : modelB }
  function backModel() { return map.frontIsA ? modelB : modelA }

  function tileKey(frame, z, x, y) {
    return map.provider + "/" + frame + "/" + map.scheme + "/" + z + "/" + x + "/" + y
  }

  function wantedTiles() {
    var halfW = map.width / 2 / map.scale
    var halfH = map.height / 2 / map.scale
    var x0 = Math.floor((map.worldCx - halfW) / 256)
    var x1 = Math.floor((map.worldCx + halfW) / 256)
    var y0 = Math.max(0, Math.floor((map.worldCy - halfH) / 256))
    var y1 = Math.min(map.tileCount - 1, Math.floor((map.worldCy + halfH) / 256))
    var out = []
    for (var y = y0; y <= y1; y++)
      for (var x = x0; x <= x1; x++) {
        if (x < 0 || x >= map.tileCount) continue
        out.push([x, y])
        if (out.length >= map.maxTilesOnScreen) return out
      }
    return out
  }

  function fillModel(model, frame, z, wanted) {
    model.clear()
    var missing = []
    for (var i = 0; i < wanted.length; i++) {
      var key = tileKey(frame, z, wanted[i][0], wanted[i][1])
      var path = map.tilePaths[key] || ""
      model.append({ tx: wanted[i][0], ty: wanted[i][1], key: key, path: path })
      if (!path) missing.push(wanted[i])
    }
    return missing
  }

  function updateModelInPlace(model, frame, z, wanted) {
    var want = {}
    for (var i = 0; i < wanted.length; i++) want[tileKey(frame, z, wanted[i][0], wanted[i][1])] = wanted[i]
    for (var r = model.count - 1; r >= 0; r--) {
      var row = model.get(r)
      if (want[row.key]) delete want[row.key]
      else model.remove(r)
    }
    var missing = []
    for (var key in want) {
      var path = map.tilePaths[key] || ""
      model.append({ tx: want[key][0], ty: want[key][1], key: key, path: path })
      if (!path) missing.push(want[key])
    }
    return missing
  }

  function rebuild() {
    if (!map.provider || !map.frameId || map.width <= 0 || map.height <= 0) {
      modelA.clear(); modelB.clear()
      map.frontFrame = ""; map.backFrame = ""; map.backLoading = false
      return
    }
    var wanted = wantedTiles()
    if (map.frameId === map.frontFrame && map.tz === map.frontZ) {
      var missing = updateModelInPlace(frontModel(), map.frontFrame, map.frontZ, wanted)
      if (missing.length) StormzyState.requestTiles(map.provider, map.frontFrame, map.frontZ, missing)
      if (map.backLoading) {
        // The view moved under a pending swap: refill the back layer too.
        var m2 = updateModelInPlace(backModel(), map.backFrame, map.backZ, wanted)
        if (m2.length) StormzyState.requestTiles(map.provider, map.backFrame, map.backZ, m2)
      }
      return
    }
    // A new frame (or tile zoom): stage it behind the current picture.
    map.backFrame = map.frameId
    map.backZ = map.tz
    var miss = fillModel(backModel(), map.backFrame, map.backZ, wanted)
    if (miss.length === 0) { swap(); return }
    map.backLoading = true
    swapTimeout.restart()
    StormzyState.requestTiles(map.provider, map.backFrame, map.backZ, miss)
  }

  function swap() {
    swapTimeout.stop()
    map.backLoading = false
    map.frontIsA = !map.frontIsA
    map.frontFrame = map.backFrame
    map.frontZ = map.backZ
    map.backFrame = ""
    map.backZ = -1
    backModel().clear()
  }

  function backComplete() {
    var model = backModel()
    for (var i = 0; i < model.count; i++) if (!model.get(i).path) return false
    return true
  }

  // Waiting forever on a tile that never comes would freeze playback; after
  // this the back layer is shown as it is and late tiles fill in.
  Timer {
    id: swapTimeout
    interval: 700
    repeat: false
    onTriggered: if (map.backLoading) map.swap()
  }

  function onTile(msg) {
    if (msg.provider !== map.provider || typeof msg.frame !== "string") return
    if (typeof msg.file !== "string" || msg.file.length === 0 || msg.file.length > 512) return
    if (msg.scheme !== map.scheme) return
    var key = tileKey(msg.frame, msg.z, msg.x, msg.y)
    if (map.tilePathCount > 4000) { map.tilePaths = ({}); map.tilePathCount = 0 }
    if (!map.tilePaths[key]) map.tilePathCount += 1
    map.tilePaths[key] = msg.file
    setPath(modelA, key, msg.file)
    setPath(modelB, key, msg.file)
    if (map.backLoading && backComplete()) swap()
  }

  function setPath(model, key, path) {
    for (var i = 0; i < model.count; i++)
      if (model.get(i).key === key) { model.setProperty(i, "path", path); return }
  }

  Connections {
    target: StormzyState
    function onTileReady(msg) { map.onTile(msg) }
    function onBasemapReady(msg) { map.onBasemap(msg) }
  }

  Timer {
    id: rebuildTimer
    interval: 30
    repeat: false
    onTriggered: map.rebuild()
  }

  function viewChanged() {
    rebuildTimer.restart()
    basemapTimer.restart()
    canvas.requestPaint()
    overlay.requestPaint()
  }

  onCenterLatChanged: viewChanged()
  onCenterLonChanged: viewChanged()
  onZoomChanged: viewChanged()
  onWidthChanged: viewChanged()
  onHeightChanged: viewChanged()
  onFrameIdChanged: rebuildTimer.restart()
  onProviderChanged: { map.tilePaths = ({}); map.tilePathCount = 0; rebuildTimer.restart() }
  onSchemeChanged: rebuildTimer.restart()

  // -------------------------------------------------------------- basemap

  property var basemap: null
  property int basemapReq: -1
  property var basemapReqBbox: null
  property int basemapReqZoom: -1

  Timer {
    id: basemapTimer
    interval: 120
    repeat: false
    onTriggered: map.maybeRequestBasemap()
  }

  function inside(inner, outer) {
    return inner[0] >= outer[0] && inner[1] >= outer[1] && inner[2] <= outer[2] && inner[3] <= outer[3]
  }

  function maybeRequestBasemap() {
    if (map.width <= 0 || map.height <= 0) return
    var vb = viewBbox()
    var zf = Math.floor(map.zoom)
    if (map.basemap && map.basemap.zoomFloor === zf && inside(vb, map.basemap.bbox)) return
    if (map.basemapReq >= 0 && map.basemapReqZoom === zf && map.basemapReqBbox && inside(vb, map.basemapReqBbox)) return
    var padX = (vb[2] - vb[0]) * 0.6, padY = (vb[3] - vb[1]) * 0.6
    var bbox = [Math.max(-180, vb[0] - padX), Math.max(-85, vb[1] - padY),
                Math.min(180, vb[2] + padX), Math.min(85, vb[3] + padY)]
    map.basemapReqBbox = bbox
    map.basemapReqZoom = zf
    map.basemapReq = StormzyState.requestBasemap(zf, bbox)
  }

  function onBasemap(msg) {
    if (msg.req !== map.basemapReq) return
    map.basemapReq = -1
    var lines = {}
    var raw = (msg.lines && typeof msg.lines === "object") ? msg.lines : {}
    var layers = ["lake", "state", "border", "coast"]
    for (var l = 0; l < layers.length; l++) {
      var src = Array.isArray(raw[layers[l]]) ? raw[layers[l]] : []
      var out = []
      for (var i = 0; i < src.length; i++) {
        var flat = src[i]
        if (!Array.isArray(flat) || flat.length < 4) continue
        var n = flat.length >> 1
        var u = new Float32Array(n), v = new Float32Array(n)
        var u0 = 2, v0 = 2, u1 = -1, v1 = -1
        for (var k = 0; k < n; k++) {
          var lon = Number(flat[2 * k]), lat = Number(flat[2 * k + 1])
          if (!isFinite(lon) || !isFinite(lat)) { lon = 0; lat = 0 }
          var uu = Geo.lon2u(lon), vv = Geo.lat2v(Geo.clampLat(lat))
          u[k] = uu; v[k] = vv
          if (uu < u0) u0 = uu; if (uu > u1) u1 = uu
          if (vv < v0) v0 = vv; if (vv > v1) v1 = vv
        }
        out.push({ u: u, v: v, n: n, b: [u0, v0, u1, v1] })
      }
      lines[layers[l]] = out
    }
    var places = []
    var rawPlaces = Array.isArray(msg.places) ? msg.places : []
    for (var p = 0; p < rawPlaces.length && p < 120; p++) {
      var row = rawPlaces[p]
      if (!Array.isArray(row) || row.length < 5 || typeof row[0] !== "string") continue
      var plat = Number(row[1]), plon = Number(row[2])
      if (!isFinite(plat) || !isFinite(plon)) continue
      places.push({ name: row[0].slice(0, 40), u: Geo.lon2u(plon), v: Geo.lat2v(Geo.clampLat(plat)),
                    minZoom: Number(row[3]) || 10, capital: row[4] === 1 })
    }
    map.basemap = { lines: lines, places: places, zoomFloor: map.basemapReqZoom, bbox: map.basemapReqBbox }
    canvas.requestPaint()
    overlay.requestPaint()
  }

  // --------------------------------------------------------------- drawing

  Rectangle {
    anchors.fill: parent
    color: map.background
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    function rgba(c, a) {
      return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
    }

    function strokeLayer(ctx, lines, W, ox, oy, u0, v0, u1, v1) {
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        var b = line.b
        if (b[2] < u0 || b[0] > u1 || b[3] < v0 || b[1] > v1) continue
        ctx.beginPath()
        var lastX = -1e9, lastY = -1e9
        for (var k = 0; k < line.n; k++) {
          var px = line.u[k] * W + ox, py = line.v[k] * W + oy
          if (k === 0) { ctx.moveTo(px, py); lastX = px; lastY = py; continue }
          if (Math.abs(px - lastX) + Math.abs(py - lastY) < 0.8 && k !== line.n - 1) continue
          ctx.lineTo(px, py); lastX = px; lastY = py
        }
        ctx.stroke()
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var W = map.worldSize * map.scale
      var ox = width / 2 - map.worldCx * map.scale
      var oy = height / 2 - map.worldCy * map.scale
      var u0 = (0 - ox) / W, u1 = (width - ox) / W
      var v0 = (0 - oy) / W, v1 = (height - oy) / W
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      var bm = map.basemap
      if (bm) {
        ctx.lineWidth = 1
        ctx.strokeStyle = rgba(map.accent, 0.45)
        strokeLayer(ctx, bm.lines.lake, W, ox, oy, u0, v0, u1, v1)
        ctx.strokeStyle = rgba(map.muted, 0.45)
        strokeLayer(ctx, bm.lines.state, W, ox, oy, u0, v0, u1, v1)
        ctx.lineWidth = 1.2
        ctx.strokeStyle = rgba(map.muted, 0.95)
        strokeLayer(ctx, bm.lines.border, W, ox, oy, u0, v0, u1, v1)
        ctx.lineWidth = 1.1
        ctx.strokeStyle = rgba(map.foreground, 0.8)
        strokeLayer(ctx, bm.lines.coast, W, ox, oy, u0, v0, u1, v1)

      }
    }
  }

  Item {
    id: tilesA
    anchors.fill: parent
    visible: map.frontIsA
    Repeater {
      model: modelA
      delegate: Image {
        required property int tx
        required property int ty
        required property string path
        x: (tx * 256 - map.worldCx) * map.scale + map.width / 2
        y: (ty * 256 - map.worldCy) * map.scale + map.height / 2
        width: 256 * map.scale + 0.5
        height: 256 * map.scale + 0.5
        source: path ? "file://" + path : ""
        asynchronous: true
        cache: true
        smooth: map.scale <= 1.5
        opacity: 0.9
      }
    }
  }

  Item {
    id: tilesB
    anchors.fill: parent
    visible: !map.frontIsA
    Repeater {
      model: modelB
      delegate: Image {
        required property int tx
        required property int ty
        required property string path
        x: (tx * 256 - map.worldCx) * map.scale + map.width / 2
        y: (ty * 256 - map.worldCy) * map.scale + map.height / 2
        width: 256 * map.scale + 0.5
        height: 256 * map.scale + 0.5
        source: path ? "file://" + path : ""
        asynchronous: true
        cache: true
        smooth: map.scale <= 1.5
        opacity: 0.9
      }
    }
  }

  // Labels, the place marker and the scale bar sit above the radar so a
  // city name is never hidden under a cell.
  Canvas {
    id: overlay
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    function rgba(c, a) {
      return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var W = map.worldSize * map.scale
      var ox = width / 2 - map.worldCx * map.scale
      var oy = height / 2 - map.worldCy * map.scale
      var bm = map.basemap
      if (bm) {
        // Labels, densest first by Natural Earth's own zoom ranking, and
        // never on top of each other.
        var drawn = []
        var size = map.fontSize
        ctx.textBaseline = "middle"
        for (var p = 0; p < bm.places.length; p++) {
          var pl = bm.places[p]
          if (pl.minZoom > map.zoom + 1) continue
          var px = pl.u * W + ox, py = pl.v * W + oy
          if (px < -40 || px > width + 40 || py < -20 || py > height + 20) continue
          ctx.font = (pl.capital ? "bold " : "") + size + "px " + map.fontFamily
          var tw = ctx.measureText(pl.name).width
          var rect = [px + 5, py - size * 0.7, px + 9 + tw, py + size * 0.7]
          var clash = false
          for (var d = 0; d < drawn.length; d++) {
            var r = drawn[d]
            if (rect[0] < r[2] + 4 && rect[2] > r[0] - 4 && rect[1] < r[3] + 2 && rect[3] > r[1] - 2) { clash = true; break }
          }
          if (clash) continue
          drawn.push(rect)
          ctx.fillStyle = rgba(map.foreground, 0.95)
          ctx.beginPath()
          ctx.arc(px, py, pl.capital ? 3.2 : 2.3, 0, Math.PI * 2)
          ctx.fill()
          ctx.fillStyle = rgba(map.background, 0.85)
          ctx.fillText(pl.name, px + 8, py + 1)
          ctx.fillText(pl.name, px + 6, py - 1)
          ctx.fillStyle = rgba(map.foreground, 0.95)
          ctx.fillText(pl.name, px + 7, py)
        }
      }

      if (map.marker) {
        var m = map.lonLatToScreen(map.marker.lon, map.marker.lat)
        ctx.lineWidth = 2
        ctx.strokeStyle = rgba(map.accent, 1)
        ctx.beginPath(); ctx.arc(m.x, m.y, 7, 0, Math.PI * 2); ctx.stroke()
        ctx.fillStyle = rgba(map.accent, 1)
        ctx.beginPath(); ctx.arc(m.x, m.y, 2.2, 0, Math.PI * 2); ctx.fill()
      }

      // Scale bar, bottom left.
      var bar = Geo.scaleBar(map.centerLat, map.zoom, 140)
      var bx = 14, by = height - 16
      ctx.lineWidth = 2
      ctx.strokeStyle = rgba(map.foreground, 0.9)
      ctx.beginPath()
      ctx.moveTo(bx, by - 5); ctx.lineTo(bx, by); ctx.lineTo(bx + bar.px, by); ctx.lineTo(bx + bar.px, by - 5)
      ctx.stroke()
      ctx.font = map.fontSize + "px " + map.fontFamily
      ctx.textBaseline = "bottom"
      ctx.fillStyle = rgba(map.foreground, 0.9)
      ctx.fillText(bar.label, bx + 4, by - 3)
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: map.interactive
    acceptedButtons: Qt.LeftButton
    property real lastX: 0
    property real lastY: 0
    property bool dragging: false
    onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y; dragging = true }
    onReleased: function(mouse) { if (dragging) { dragging = false; map.userMoved() } }
    onPositionChanged: function(mouse) {
      if (!dragging) return
      map.pan(mouse.x - lastX, mouse.y - lastY)
      lastX = mouse.x; lastY = mouse.y
    }
    onWheel: function(wheel) {
      var steps = wheel.angleDelta.y / 120
      if (steps === 0) return
      map.zoomBy(steps > 0 ? 0.5 : -0.5, wheel.x, wheel.y)
      map.userMoved()
    }
    onDoubleClicked: function(mouse) { map.zoomBy(1, mouse.x, mouse.y); map.userMoved() }
  }

  Component.onCompleted: viewChanged()
}
