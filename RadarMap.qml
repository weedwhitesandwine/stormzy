import QtQuick
import "."
import "Geo.js" as Geo

// The map: a bundled Natural Earth basemap drawn in theme colours, one frame
// of tiles over it, point data (temperatures, wind arrows, air quality) when
// the layer has no tiles, and the place marker. Tiles come from the helper as
// files on disk; this item never fetches anything itself.
Item {
  id: map

  property real centerLat: 35.68
  property real centerLon: 139.69
  property real zoom: 7
  property string source: ""         // tile source id, "" for none
  property string frameId: ""
  property int nativeZoom: 8
  property int scheme: 2
  property real tileOpacity: 0.9
  // Point data: "" | grid-weather | grid-air | stations, and which field of
  // it to draw: temp | wind | air.
  property string dataMode: ""
  property string dataField: ""
  property color foreground: "#cccccc"
  property color background: "#101315"
  property color accent: "#7aa2f7"
  property color muted: "#707880"
  property string fontFamily: "sans-serif"
  property int fontSize: 12
  property var marker: null          // {lat, lon}
  property bool interactive: true

  signal userMoved()
  signal dataArrived(string stamp, string error)

  readonly property real minZoom: 3
  readonly property real maxZoom: 11
  // Tiles are fetched at an integer zoom no finer than the source's native
  // one and scaled to the real zoom, so zooming past native just enlarges.
  readonly property int tz: Math.max(2, Math.min(map.nativeZoom, Math.round(map.zoom)))
  readonly property real scale: Math.pow(2, map.zoom - map.tz)
  readonly property real worldSize: Geo.worldSize(map.tz)
  readonly property real worldCx: Geo.lon2x(map.centerLon, map.tz)
  readonly property real worldCy: Geo.lat2y(map.centerLat, map.tz)
  readonly property int tileCount: 1 << map.tz

  readonly property int maxTilesOnScreen: 96

  // JMA's temperature palette, reused for the point field so the two look
  // alike: 5 °C bands from below -30 to 35 and above.
  readonly property var tempColors: ["#d8d6e4", "#a8a3c5", "#776fa4", "#4d4471", "#002080", "#0041ff", "#0096ff",
                                     "#b9ebff", "#fffff0", "#ffff96", "#faf500", "#ff9900", "#ff2800", "#b40068", "#50002e"]
  function tempColor(t) {
    var i = Math.floor((t + 30) / 5) + 1
    if (i < 0) i = 0
    if (i >= map.tempColors.length) i = map.tempColors.length - 1
    return map.tempColors[i]
  }
  // The same palette as a continuous gradient, for the heat map.
  function tempColorSmooth(t) {
    var pos = (t + 30) / 5 + 0.5      // band centres sit at -32.5, -27.5, ...
    if (pos < 0) pos = 0
    var n = map.tempColors.length
    if (pos >= n - 1) return map.tempColors[n - 1]
    var i = Math.floor(pos), f = pos - i
    var a = map.tempColors[i], b = map.tempColors[i + 1]
    var r = Math.round(parseInt(a.substr(1, 2), 16) * (1 - f) + parseInt(b.substr(1, 2), 16) * f)
    var g = Math.round(parseInt(a.substr(3, 2), 16) * (1 - f) + parseInt(b.substr(3, 2), 16) * f)
    var bl = Math.round(parseInt(a.substr(5, 2), 16) * (1 - f) + parseInt(b.substr(5, 2), 16) * f)
    return "rgb(" + r + "," + g + "," + bl + ")"
  }
  // US AQI bands.
  function aqiColor(a) {
    if (a <= 50) return "#00e400"
    if (a <= 100) return "#ffff00"
    if (a <= 150) return "#ff7e00"
    if (a <= 200) return "#ff0000"
    if (a <= 300) return "#8f3f97"
    return "#7e0023"
  }

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
    return map.source + "/" + frame + "/" + map.scheme + "/" + z + "/" + x + "/" + y
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
    if (!map.source || !map.frameId || map.width <= 0 || map.height <= 0) {
      modelA.clear(); modelB.clear()
      map.frontFrame = ""; map.backFrame = ""; map.backLoading = false
      return
    }
    var wanted = wantedTiles()
    if (map.frameId === map.frontFrame && map.tz === map.frontZ) {
      var missing = updateModelInPlace(frontModel(), map.frontFrame, map.frontZ, wanted)
      if (missing.length) StormzyState.requestTiles(map.source, map.frontFrame, map.frontZ, missing)
      if (map.backLoading) {
        var m2 = updateModelInPlace(backModel(), map.backFrame, map.backZ, wanted)
        if (m2.length) StormzyState.requestTiles(map.source, map.backFrame, map.backZ, m2)
      }
      return
    }
    map.backFrame = map.frameId
    map.backZ = map.tz
    var miss = fillModel(backModel(), map.backFrame, map.backZ, wanted)
    if (miss.length === 0) { swap(); return }
    map.backLoading = true
    swapTimeout.restart()
    StormzyState.requestTiles(map.source, map.backFrame, map.backZ, miss)
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
    if (msg.source !== map.source || typeof msg.frame !== "string") return
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
    function onGridReady(msg) { map.onPoints(msg, "grid") }
    function onStationsReady(msg) { map.onPoints(msg, "stations") }
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
    dataTimer.restart()
    canvas.requestPaint()
    overlay.requestPaint()
    dataCanvas.requestPaint()
  }

  onCenterLatChanged: viewChanged()
  onCenterLonChanged: viewChanged()
  onZoomChanged: viewChanged()
  onWidthChanged: viewChanged()
  onHeightChanged: viewChanged()
  onFrameIdChanged: rebuildTimer.restart()
  onSourceChanged: { map.tilePaths = ({}); map.tilePathCount = 0; rebuildTimer.restart() }
  onSchemeChanged: rebuildTimer.restart()
  onMarkerChanged: overlay.requestPaint()
  onDataModeChanged: { map.points = []; map.pointsKey = ""; dataCanvas.requestPaint(); dataTimer.restart() }
  onDataFieldChanged: dataCanvas.requestPaint()

  // ----------------------------------------------------------- point data
  //
  // A grid of Open-Meteo points over the view, or the AMeDAS stations in it.
  // Requested after the view settles; the helper answers from its own cache
  // for ten minutes, so panning back and forth costs nothing.

  property var points: []
  property string pointsKey: ""
  property int pointsReq: -1

  Timer {
    id: dataTimer
    interval: 450
    repeat: false
    onTriggered: map.maybeRequestData()
  }

  Timer {
    id: dataRefresh
    interval: 600000
    repeat: true
    running: map.dataMode !== "" && map.visible
    onTriggered: { map.pointsKey = ""; map.maybeRequestData() }
  }

  function maybeRequestData() {
    if (!map.dataMode || map.width <= 0 || map.height <= 0) return
    var vb = viewBbox()
    if (map.dataMode === "stations") {
      var key = "s|" + vb.map(function(v) { return v.toFixed(2) }).join(",")
      if (key === map.pointsKey) return
      map.pointsKey = key
      map.pointsReq = StormzyState.requestStations(vb)
      return
    }
    // Grid cells about 100 px apart, at most 96 points.
    var cols = Math.max(3, Math.min(12, Math.round(map.width / 100)))
    var rows = Math.max(2, Math.min(8, Math.round(map.height / 100)))
    var lats = [], lons = []
    for (var r = 0; r < rows; r++)
      for (var c = 0; c < cols; c++) {
        var p = screenToLonLat((c + 0.5) * map.width / cols, (r + 0.5) * map.height / rows)
        lats.push(Math.round(p.lat * 100) / 100)
        lons.push(Math.round(p.lon * 100) / 100)
      }
    var gkey = map.dataMode + "|" + lats.join(",") + "|" + lons.join(",")
    if (gkey === map.pointsKey) return
    map.pointsKey = gkey
    map.pointsReq = StormzyState.requestGrid(map.dataMode === "grid-air" ? "air" : "weather", lats, lons)
  }

  function onPoints(msg, kind) {
    if (msg.req !== map.pointsReq) return
    var error = typeof msg.error === "string" ? msg.error.slice(0, 80) : ""
    var raw = StormzyState.isList(msg.points) ? msg.points : []
    var clean = []
    for (var i = 0; i < raw.length && clean.length < 400; i++) {
      var p = raw[i]
      if (!p || typeof p !== "object") continue
      if (typeof p.lat !== "number" || typeof p.lon !== "number") continue
      clean.push({
        u: Geo.lon2u(p.lon), v: Geo.lat2v(Geo.clampLat(p.lat)),
        name: typeof p.name === "string" ? p.name.slice(0, 40) : "",
        t: typeof p.t === "number" ? p.t : null,
        ws: typeof p.ws === "number" ? p.ws : null,
        wd: typeof p.wd === "number" ? p.wd : null,
        aqi: typeof p.aqi === "number" ? p.aqi : null,
        pm25: typeof p.pm25 === "number" ? p.pm25 : null
      })
    }
    if (clean.length || !map.points.length) map.points = clean
    if (error) map.pointsKey = ""   // try again on the next nudge
    var stamp = typeof msg.time === "string" ? msg.time.slice(0, 16).replace("T", " ") : ""
    map.dataArrived(stamp, error)
    dataCanvas.requestPaint()
  }

  // --------------------------------------------------------------- drawing

  Rectangle {
    anchors.fill: parent
    color: map.background
  }

  function rgba(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

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
        ctx.strokeStyle = map.rgba(map.accent, 0.45)
        strokeLayer(ctx, bm.lines.lake, W, ox, oy, u0, v0, u1, v1)
        ctx.strokeStyle = map.rgba(map.muted, 0.45)
        strokeLayer(ctx, bm.lines.state, W, ox, oy, u0, v0, u1, v1)
        ctx.lineWidth = 1.2
        ctx.strokeStyle = map.rgba(map.muted, 0.95)
        strokeLayer(ctx, bm.lines.border, W, ox, oy, u0, v0, u1, v1)
        ctx.lineWidth = 1.1
        ctx.strokeStyle = map.rgba(map.foreground, 0.8)
        strokeLayer(ctx, bm.lines.coast, W, ox, oy, u0, v0, u1, v1)
      }
    }
  }

  Item {
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
        opacity: map.tileOpacity
      }
    }
  }

  Item {
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
        opacity: map.tileOpacity
      }
    }
  }

  // Point data above the tiles, below the labels.
  Canvas {
    id: dataCanvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    visible: map.dataMode !== ""
    opacity: (map.dataField === "temp" && map.dataMode === "grid-weather") ? 0.62 : 1

    // A temperature field: the grid points interpolated (inverse distance)
    // onto a coarse raster and painted in JMA's 5 degree bands, with a few
    // of the values written on top.
    function heatmap(ctx, W, ox, oy, size) {
      var pts = []
      for (var i = 0; i < map.points.length; i++) {
        var p = map.points[i]
        if (p.t === null) continue
        pts.push({ x: p.u * W + ox, y: p.v * W + oy, t: p.t })
      }
      if (pts.length < 3) return
      var step = 7
      // Points sit about one grid cell apart; weight falls off over two.
      var reach = 0
      for (var a = 1; a < pts.length; a++) reach += Math.abs(pts[a].x - pts[a - 1].x) + Math.abs(pts[a].y - pts[a - 1].y)
      reach = Math.max(40, reach / Math.max(1, pts.length - 1))
      var eps = reach * reach * 0.05
      var last = null
      for (var y = 0; y < height; y += step) {
        for (var x = 0; x < width; x += step) {
          var num = 0, den = 0
          for (var k = 0; k < pts.length; k++) {
            var dx = pts[k].x - x, dy = pts[k].y - y
            var w = 1 / (dx * dx + dy * dy + eps)
            num += w * pts[k].t; den += w
          }
          var c = map.tempColorSmooth(num / den)
          if (c !== last) { ctx.fillStyle = c; last = c }
          ctx.fillRect(x, y, step + 0.5, step + 0.5)
        }
      }
      ctx.font = "bold " + size + "px " + map.fontFamily
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      for (var j = 0; j < pts.length; j += 2) {
        var q = pts[j]
        if (q.x < 0 || q.x > width || q.y < 0 || q.y > height) continue
        label(ctx, Math.round(q.t) + "°", q.x, q.y, "#ffffff")
      }
    }

    function label(ctx, text, x, y, fill) {
      ctx.fillStyle = map.rgba(map.background, 0.9)
      ctx.fillText(text, x + 1, y + 1)
      ctx.fillText(text, x - 1, y - 1)
      ctx.fillStyle = fill
      ctx.fillText(text, x, y)
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      if (!map.dataMode || !map.points.length) return
      var W = map.worldSize * map.scale
      var ox = width / 2 - map.worldCx * map.scale
      var oy = height / 2 - map.worldCy * map.scale
      var size = map.fontSize + 1
      if (map.dataField === "temp" && map.dataMode === "grid-weather") {
        heatmap(ctx, W, ox, oy, size)
        return
      }
      ctx.font = "bold " + size + "px " + map.fontFamily
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.lineCap = "round"
      var fg = map.rgba(map.foreground, 0.95)
      // Stations are thinned to one per screen cell, strongest wind first,
      // so a zoomed-out view is not a thicket of arrows.
      var list = map.points
      var cells = {}
      if (map.dataMode === "stations") {
        list = map.points.slice().sort(function(a, b) { return (b.ws || 0) - (a.ws || 0) })
      }
      var cell = size * 5
      for (var i = 0; i < list.length; i++) {
        var p = list[i]
        var px = p.u * W + ox, py = p.v * W + oy
        if (px < -40 || px > width + 40 || py < -40 || py > height + 40) continue
        if (map.dataMode === "stations") {
          var ck = Math.floor(px / cell) + "," + Math.floor(py / cell)
          if (cells[ck]) continue
          cells[ck] = true
        }
        if (map.dataField === "temp") {
          if (p.t === null) continue
          var tc = map.tempColor(p.t)
          ctx.fillStyle = tc
          ctx.beginPath(); ctx.arc(px, py, size * 1.35, 0, Math.PI * 2); ctx.fill()
          ctx.lineWidth = 1
          ctx.strokeStyle = map.rgba(map.background, 0.8)
          ctx.stroke()
          ctx.fillStyle = (p.t >= 5 && p.t < 20) ? "#101010" : "#ffffff"
          ctx.fillText(Math.round(p.t) + "°", px, py)
        } else if (map.dataField === "wind") {
          if (p.ws === null) continue
          var len = 8 + Math.min(20, p.ws) * 1.4
          // Data colours are fixed, whatever the theme: orange from 10 m/s,
          // red from 17 (a gale).
          ctx.strokeStyle = p.ws >= 17 ? "#ff2800" : (p.ws >= 10 ? "#ff9900" : fg)
          ctx.fillStyle = ctx.strokeStyle
          if (p.wd !== null && p.ws >= 0.3) {
            // Direction is where the wind comes from; the arrow points downwind.
            var a = (p.wd + 180) * Math.PI / 180
            var dx = Math.sin(a), dy = -Math.cos(a)
            var x0 = px - dx * len / 2, y0 = py - dy * len / 2
            var x1 = px + dx * len / 2, y1 = py + dy * len / 2
            ctx.lineWidth = 2
            ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(x1, y1)
            ctx.lineTo(x1 - dx * 7 - dy * 4.5, y1 - dy * 7 + dx * 4.5)
            ctx.lineTo(x1 - dx * 7 + dy * 4.5, y1 - dy * 7 - dx * 4.5)
            ctx.closePath(); ctx.fill()
          } else {
            ctx.lineWidth = 1.5
            ctx.beginPath(); ctx.arc(px, py, 4, 0, Math.PI * 2); ctx.stroke()
          }
          ctx.font = size + "px " + map.fontFamily
          label(ctx, p.ws.toFixed(p.ws < 10 ? 1 : 0), px, py + len / 2 + size * 0.8, fg)
          ctx.font = "bold " + size + "px " + map.fontFamily
        } else if (map.dataField === "air") {
          if (p.aqi === null) continue
          ctx.fillStyle = map.aqiColor(p.aqi)
          ctx.beginPath(); ctx.arc(px, py, size * 1.35, 0, Math.PI * 2); ctx.fill()
          ctx.lineWidth = 1
          ctx.strokeStyle = map.rgba(map.background, 0.8)
          ctx.stroke()
          ctx.fillStyle = p.aqi <= 150 ? "#101010" : "#ffffff"
          ctx.fillText(String(Math.round(p.aqi)), px, py)
        }
      }
    }
  }

  // Labels, the place marker and the scale bar sit above everything so a
  // city name is never hidden under a cell.
  Canvas {
    id: overlay
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var W = map.worldSize * map.scale
      var ox = width / 2 - map.worldCx * map.scale
      var oy = height / 2 - map.worldCy * map.scale
      var bm = map.basemap
      if (bm) {
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
          ctx.fillStyle = map.rgba(map.foreground, 0.95)
          ctx.beginPath()
          ctx.arc(px, py, pl.capital ? 3.2 : 2.3, 0, Math.PI * 2)
          ctx.fill()
          ctx.fillStyle = map.rgba(map.background, 0.85)
          ctx.fillText(pl.name, px + 8, py + 1)
          ctx.fillText(pl.name, px + 6, py - 1)
          ctx.fillStyle = map.rgba(map.foreground, 0.95)
          ctx.fillText(pl.name, px + 7, py)
        }
      }

      if (map.marker) {
        var m = map.lonLatToScreen(map.marker.lon, map.marker.lat)
        ctx.lineWidth = 2
        ctx.strokeStyle = map.rgba(map.accent, 1)
        ctx.beginPath(); ctx.arc(m.x, m.y, 7, 0, Math.PI * 2); ctx.stroke()
        ctx.fillStyle = map.rgba(map.accent, 1)
        ctx.beginPath(); ctx.arc(m.x, m.y, 2.2, 0, Math.PI * 2); ctx.fill()
      }

      var bar = Geo.scaleBar(map.centerLat, map.zoom, 140)
      var bx = 14, by = height - 16
      ctx.lineWidth = 2
      ctx.strokeStyle = map.rgba(map.foreground, 0.9)
      ctx.beginPath()
      ctx.moveTo(bx, by - 5); ctx.lineTo(bx, by); ctx.lineTo(bx + bar.px, by); ctx.lineTo(bx + bar.px, by - 5)
      ctx.stroke()
      ctx.font = map.fontSize + "px " + map.fontFamily
      ctx.textBaseline = "bottom"
      ctx.fillStyle = map.rgba(map.foreground, 0.9)
      ctx.fillText(bar.label, bx + 4, by - 3)
    }
  }

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
      var src = StormzyState.isList(raw[layers[l]]) ? raw[layers[l]] : []
      var out = []
      for (var i = 0; i < src.length; i++) {
        var flat = src[i]
        if (!StormzyState.isList(flat) || flat.length < 4) continue
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
    var rawPlaces = StormzyState.isList(msg.places) ? msg.places : []
    for (var p = 0; p < rawPlaces.length && p < 120; p++) {
      var row = rawPlaces[p]
      if (!StormzyState.isList(row) || row.length < 5 || typeof row[0] !== "string") continue
      var plat = Number(row[1]), plon = Number(row[2])
      if (!isFinite(plat) || !isFinite(plon)) continue
      places.push({ name: row[0].slice(0, 40), u: Geo.lon2u(plon), v: Geo.lat2v(Geo.clampLat(plat)),
                    minZoom: Number(row[3]) || 10, capital: row[4] === 1 })
    }
    map.basemap = { lines: lines, places: places, zoomFloor: map.basemapReqZoom, bbox: map.basemapReqBbox }
    canvas.requestPaint()
    overlay.requestPaint()
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
