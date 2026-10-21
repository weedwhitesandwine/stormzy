pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The single owner of the helper process and of everything it reports.
//
// A bar widget is instantiated once per monitor, so anything started from a
// widget would run once per screen. This singleton exists so there is exactly
// one helper however many bars there are, one settings writer, and one frame
// list that every surface reads.
QtObject {
  id: root

  readonly property string pluginId: "io.github.weedwhitesandwine.stormzy"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return (xdg && xdg.length > 0) ? xdg : (root.homeDir + "/.local/state")
  }
  readonly property string pluginDir: root.homeDir + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string stateDir: root.stateHome + "/omarchy/stormzy"
  readonly property string settingsPath: root.stateDir + "/settings.json"

  // -------------------------------------------------------------- settings
  //
  // The place is chosen by the user and nothing else: no IP lookup, no GPS.
  property var place: null            // {name, cc, country, admin, lat, lon}
  property real zoom: 7
  property string layer: "rain"       // rain | temp | wind | air | clouds
  property string provider: "auto"    // rain source: auto | jma | rainviewer
  property int scheme: 2              // RainViewer colour scheme (0-8)
  property bool showForecast: true
  property bool pollWhenClosed: true
  property var recents: []
  property bool settingsLoaded: false

  readonly property var layers: ["rain", "temp", "wind", "air", "clouds"]
  readonly property var layerNames: ({ rain: "Rain", temp: "Temp", wind: "Wind", air: "Air", clouds: "Clouds" })

  // ---------------------------------------------------------- what to show
  //
  // Each layer resolves to a tile source, a point-data mode, or neither.
  // Japan gets JMA's tiles and stations; elsewhere Open-Meteo points stand
  // in for the layers no one publishes keyless tiles for.
  readonly property bool inJapan: !!root.place && root.place.cc === "JP"
  // Himawari's full disc, roughly 60E to 140W.
  readonly property bool inHimawari: !!root.place && Math.abs(root.place.lat) <= 70
    && (root.place.lon >= 60 || root.place.lon <= -140)
  property bool waqiFailed: false

  readonly property string rainSource: {
    if (root.provider === "jma" || root.provider === "rainviewer") return root.provider
    return root.inJapan ? "jma" : "rainviewer"
  }

  // The tile source for the current layer, or "" when it has none.
  readonly property string source: {
    switch (root.layer) {
    case "rain": return root.rainSource
    case "temp": return root.inJapan ? "jma_temp" : ""
    case "air": return root.waqiFailed ? "" : "waqi"
    case "clouds": return root.inHimawari ? "himawari" : ""
    }
    return ""
  }

  // What the map draws as points: grid-weather, grid-air, stations, or "".
  readonly property string dataMode: {
    switch (root.layer) {
    case "temp": return root.inJapan ? "" : "grid-weather"
    case "wind": return root.inJapan ? "stations" : "grid-weather"
    case "air": return root.waqiFailed ? "grid-air" : ""
    }
    return ""
  }

  readonly property string unavailable: {
    if (root.layer === "clouds" && !root.inHimawari)
      return "Cloud imagery is published for Japan and the Asia-Pacific disc only."
    return ""
  }

  readonly property var sourceNames: ({
    jma: "JMA", rainviewer: "RainViewer", jma_temp: "JMA", himawari: "Himawari", waqi: "WAQI",
    "grid-weather": "Open-Meteo", "grid-air": "Open-Meteo", stations: "AMeDAS"
  })
  readonly property string sourceLabel: root.source ? (root.sourceNames[root.source] || "")
    : (root.sourceNames[root.dataMode] || "")

  readonly property real tileOpacity: {
    switch (root.source) {
    case "himawari": return 0.7
    case "jma_temp": return 0.6
    case "waqi": return 1.0
    }
    return 0.9
  }

  // ---------------------------------------------------------------- frames
  property var frames: []             // [{id, time, kind}], oldest first
  // The same list as a model, edited by difference so the timeline's ticks
  // survive a refresh instead of being rebuilt every minute.
  property ListModel frameModel: ListModel {}
  property int nativeZoom: 8
  property string framesError: ""
  property real framesFetchedAt: 0
  property int frameIndex: -1
  property bool playing: false
  // When the layer is points rather than tiles, the map reports the data's
  // own time stamp here.
  property string dataTime: ""
  property string dataError: ""

  readonly property var currentFrame: (root.frameIndex >= 0 && root.frameIndex < root.frames.length)
    ? root.frames[root.frameIndex] : null
  readonly property int newestPastIndex: {
    var idx = -1
    for (var i = 0; i < root.frames.length; i++) if (root.frames[i].kind === "past") idx = i
    return idx
  }
  readonly property real newestPastTime: root.newestPastIndex >= 0 ? root.frames[root.newestPastIndex].time : 0
  readonly property bool haveFrames: root.frames.length > 0
  property real now: Date.now()

  // ----------------------------------------------------------------- limits
  readonly property int lineCeiling: 4 * 1024 * 1024
  readonly property int settingsCeiling: 64 * 1024
  readonly property int maxFrames: 80
  readonly property int maxRecents: 8

  property int openPanels: 0
  function retain() { root.openPanels = root.openPanels + 1 }
  function release() { root.openPanels = Math.max(0, root.openPanels - 1) }

  signal tileReady(var msg)
  signal basemapReady(var msg)
  signal searchReady(var msg)
  signal gridReady(var msg)
  signal stationsReady(var msg)

  // ------------------------------------------------------------- the helper

  property int restartDelay: 1000
  property int nextReq: 1
  property bool helperReady: false

  property Process helper: Process {
    // setpriv --pdeathsig means the helper cannot outlive the shell even if
    // the shell dies without cleaning up: the kernel signals it directly.
    command: ["setpriv", "--pdeathsig", "TERM", "python3", "-I", root.pluginDir + "/stormzyd.py"]
    stdinEnabled: true
    running: false
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.ingest(line) }
    }
    // Collected and discarded deliberately: an unread stderr pipe fills and
    // then blocks the writer, which would stop the helper dead.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {}
    }
    onStarted: { root.restartDelay = 1000 }
    onExited: function(code, status) { root.helperStopped() }
  }

  property Timer restartTimer: Timer {
    repeat: false
    interval: root.restartDelay
    onTriggered: root.startHelper()
  }

  function startHelper() {
    if (root.helper.running) return
    root.helperReady = false
    root.helper.running = true
  }

  function helperStopped() {
    root.helperReady = false
    root.restartDelay = Math.min(60000, Math.max(1000, root.restartDelay * 2))
    root.restartTimer.interval = root.restartDelay
    root.restartTimer.restart()
  }

  function request(obj) {
    if (!root.helper.running) { root.startHelper(); return }
    root.helper.write(JSON.stringify(obj) + "\n")
  }

  function ingest(line) {
    if (typeof line !== "string" || line.length === 0) return
    if (line.length > root.lineCeiling) return
    var msg = null
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) return
    switch (msg.op) {
    case "hello":
      root.helperReady = true
      root.restartDelay = 1000
      root.refreshFrames()
      break
    case "frames": root.applyFrames(msg); break
    case "tile": root.tileReady(msg); break
    case "basemap": root.basemapReady(msg); break
    case "search": root.searchReady(msg); break
    case "grid": root.gridReady(msg); break
    case "stations": root.stationsReady(msg); break
    }
  }

  // ------------------------------------------------------------ frame list

  property Timer pollTimer: Timer {
    repeat: true
    running: root.helperReady && (root.openPanels > 0 || root.pollWhenClosed)
    interval: root.openPanels > 0 ? 60000 : 600000
    onTriggered: root.refreshFrames()
  }

  property Timer clockTimer: Timer {
    repeat: true
    running: root.openPanels > 0
    interval: 15000
    onTriggered: root.now = Date.now()
  }

  property int refreshCount: 0

  function refreshFrames() {
    if (!root.helperReady) return
    if (root.source) root.request({ op: "frames", source: root.source })
    root.refreshCount += 1
    if (root.refreshCount % 10 === 1) root.request({ op: "cleanup" })
  }

  function resetFrames() {
    root.frames = []
    root.frameModel.clear()
    root.frameIndex = -1
    root.playing = false
    root.framesError = ""
    root.dataTime = ""
    root.dataError = ""
  }

  onSourceChanged: { root.resetFrames(); root.refreshFrames() }
  onDataModeChanged: { root.dataTime = ""; root.dataError = "" }
  onLayerChanged: { root.waqiFailed = false; root.scheduleSettingsSave() }
  onShowForecastChanged: { root.scheduleSettingsSave(); root.refreshFrames() }

  function applyFrames(msg) {
    if (msg.source !== root.source) return
    var list = Array.isArray(msg.frames) ? msg.frames.slice(0, root.maxFrames) : []
    var clean = []
    for (var i = 0; i < list.length; i++) {
      var f = list[i]
      if (!f || typeof f !== "object") continue
      if (typeof f.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(f.id)) continue
      if (typeof f.time !== "number" || !isFinite(f.time)) continue
      var kind = f.kind === "forecast" ? "forecast" : "past"
      if (kind === "forecast" && !root.showForecast) continue
      clean.push({ id: f.id, time: f.time, kind: kind })
    }
    if (typeof msg.native === "number" && msg.native >= 2 && msg.native <= 12) root.nativeZoom = msg.native
    root.framesError = typeof msg.error === "string" ? msg.error.slice(0, 80) : ""
    root.now = Date.now()
    if (clean.length === 0) {
      // Keep what we had on a failed refresh; the age readout says it is old.
      root.framesFetchedAt = root.framesFetchedAt || Date.now()
      // The air-quality tiles have no index to fail gracefully; a refused
      // probe hands the layer to Open-Meteo's points instead.
      if (msg.source === "waqi" && root.framesError) root.waqiFailed = true
      return
    }
    // Keep the user's position: by frame id if it still exists, and "newest
    // observation" stays newest when a fresh one arrives.
    var wasNewest = root.frameIndex < 0 || root.frameIndex === root.newestPastIndex
    var oldId = root.currentFrame ? root.currentFrame.id : ""
    root.frames = clean
    root.syncFrameModel(clean)
    root.framesFetchedAt = Date.now()
    var newest = root.newestPastIndex
    if (wasNewest && !root.playing) { root.frameIndex = newest >= 0 ? newest : clean.length - 1; return }
    for (var j = 0; j < clean.length; j++) if (clean[j].id === oldId) { root.frameIndex = j; return }
    root.frameIndex = newest >= 0 ? newest : clean.length - 1
  }

  function syncFrameModel(list) {
    var want = {}
    for (var i = 0; i < list.length; i++) want[list[i].id] = true
    for (var r = root.frameModel.count - 1; r >= 0; r--)
      if (!want[root.frameModel.get(r).id]) root.frameModel.remove(r)
    for (var j = 0; j < list.length; j++) {
      var have = j < root.frameModel.count ? root.frameModel.get(j).id : ""
      if (have === list[j].id) continue
      root.frameModel.insert(j, { id: list[j].id, time: list[j].time, kind: list[j].kind })
    }
    while (root.frameModel.count > list.length) root.frameModel.remove(root.frameModel.count - 1)
  }

  // -------------------------------------------------------------- playback

  property Timer playTimer: Timer {
    repeat: true
    running: root.playing && root.frames.length > 1
    interval: 400
    onTriggered: root.stepPlay()
  }

  function stepPlay() {
    if (root.frames.length < 2) { root.playing = false; return }
    var next = root.frameIndex + 1
    if (next >= root.frames.length) next = 0
    root.frameIndex = next
    root.playTimer.interval = (next === root.frames.length - 1) ? 1400 : 400
  }

  function togglePlay() {
    if (root.frames.length < 2) return
    root.playing = !root.playing
    root.playTimer.interval = 400
  }

  function step(delta) {
    if (root.frames.length === 0) return
    root.playing = false
    var i = root.frameIndex + delta
    if (i < 0) i = 0
    if (i >= root.frames.length) i = root.frames.length - 1
    root.frameIndex = i
  }

  function jumpOldest() { root.playing = false; if (root.frames.length) root.frameIndex = 0 }
  function jumpNewest() { root.playing = false; if (root.frames.length) root.frameIndex = root.newestPastIndex >= 0 ? root.newestPastIndex : root.frames.length - 1 }
  function selectFrame(i) {
    if (i < 0 || i >= root.frames.length) return
    root.playing = false
    root.frameIndex = i
  }

  function setLayer(name) {
    if (root.layers.indexOf(name) < 0 || name === root.layer) return
    root.layer = name
  }

  // ---------------------------------------------------------------- places

  function choosePlace(p) {
    var clean = root.cleanPlace(p)
    if (!clean) return
    root.place = clean
    var next = [clean]
    for (var i = 0; i < root.recents.length && next.length < root.maxRecents; i++) {
      var r = root.recents[i]
      if (r.name === clean.name && r.cc === clean.cc && Math.abs(r.lat - clean.lat) < 0.01) continue
      next.push(r)
    }
    root.recents = next
    root.waqiFailed = false
    root.scheduleSettingsSave()
  }

  function search(q) {
    var id = root.nextReq++
    root.request({ op: "search", id: id, q: String(q).slice(0, 80) })
    return id
  }

  function requestTiles(source, frame, z, tiles) {
    var id = root.nextReq++
    root.request({ op: "tiles", req: id, source: source, frame: frame, z: z,
                   scheme: root.scheme, tiles: tiles })
    return id
  }

  function requestBasemap(zoom, bbox) {
    var id = root.nextReq++
    root.request({ op: "basemap", req: id, zoom: zoom, bbox: bbox })
    return id
  }

  function requestGrid(kind, lats, lons) {
    var id = root.nextReq++
    root.request({ op: "grid", req: id, kind: kind, lats: lats, lons: lons })
    return id
  }

  function requestStations(bbox) {
    var id = root.nextReq++
    root.request({ op: "stations", req: id, bbox: bbox })
    return id
  }

  // ----------------------------------------------------------------- text

  function stampText(frame) {
    if (!frame) return root.dataTime ? root.dataTime : ""
    var d = new Date(frame.time * 1000)
    var text = Qt.formatDateTime(d, "ddd d MMM HH:mm")
    if (frame.kind === "forecast") {
      var ahead = Math.round((frame.time * 1000 - root.now) / 60000)
      var label = ahead >= 90 ? "+" + Math.round(ahead / 60) + " h" : "+" + ahead + " min"
      return text + "  ·  forecast " + (ahead >= 0 ? label : "")
    }
    return text
  }

  function ageText() {
    if (!root.source) {
      if (root.dataError) return "data unreachable (" + root.dataError + ")"
      return root.dataTime ? "observed " + root.dataTime : (root.unavailable ? "" : "fetching…")
    }
    if (!root.newestPastTime) return root.framesError ? "unreachable (" + root.framesError + ")" : "fetching…"
    var mins = Math.round((root.now - root.newestPastTime * 1000) / 60000)
    var age = mins < 1 ? "just now" : (mins >= 120 ? Math.round(mins / 60) + " h ago" : mins + " min ago")
    if (root.framesError) return "newest " + age + " · refresh failed: " + root.framesError
    return "newest " + age
  }

  // -------------------------------------------------------------- settings

  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("\n")

  property Process ensureStateDir: Process {
    command: ["mkdir", "-p", "-m", "700", root.stateDir]
  }

  property Process settingsReader: Process {
    command: ["python3", "-I", "-c", root.safeRead, root.settingsPath, String(root.settingsCeiling)]
    stdout: StdioCollector {
      id: settingsOut
      waitForEnd: true
      onStreamFinished: if (settingsOut.text !== "") root.applySettings(settingsOut.text)
    }
    onExited: function(code, status) {
      // 2 is "no file yet": the defaults are the truth and saving is safe.
      // 0 means it was read. 1 is a refusal, and the gate stays shut.
      if (root.settingsLoaded) return
      if (code === 2) root.settingsLoaded = true
    }
  }

  // Qt 6.12 hands an array across a `var` signal or property as a sequence
  // wrapper: it indexes and slices like an array, but Array.isArray rejects
  // it. Everything the *Ready signals carry has crossed that boundary.
  function isList(v) {
    return Array.isArray(v) || (v !== null && typeof v === "object" && typeof v.length === "number")
  }

  function cleanPlace(p) {
    if (!p || typeof p !== "object" || root.isList(p)) return null
    if (typeof p.lat !== "number" || typeof p.lon !== "number" || !isFinite(p.lat) || !isFinite(p.lon)) return null
    if (Math.abs(p.lat) > 85 || Math.abs(p.lon) > 180) return null
    return {
      name: typeof p.name === "string" ? p.name.slice(0, 80) : "",
      cc: typeof p.cc === "string" ? p.cc.slice(0, 2).toUpperCase() : "",
      country: typeof p.country === "string" ? p.country.slice(0, 60) : "",
      admin: typeof p.admin === "string" ? p.admin.slice(0, 60) : "",
      lat: p.lat, lon: p.lon
    }
  }

  function applySettings(text) {
    var parsed = null
    try { parsed = JSON.parse(text) } catch (error) { parsed = null }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      var place = root.cleanPlace(parsed.place)
      if (place) root.place = place
      if (typeof parsed.zoom === "number" && isFinite(parsed.zoom)) root.zoom = Math.max(3, Math.min(11, parsed.zoom))
      if (root.layers.indexOf(parsed.layer) >= 0) root.layer = parsed.layer
      if (["auto", "jma", "rainviewer"].indexOf(parsed.provider) >= 0) root.provider = parsed.provider
      if (typeof parsed.scheme === "number" && parsed.scheme >= 0 && parsed.scheme <= 8) root.scheme = Math.round(parsed.scheme)
      if (typeof parsed.showForecast === "boolean") root.showForecast = parsed.showForecast
      if (typeof parsed.pollWhenClosed === "boolean") root.pollWhenClosed = parsed.pollWhenClosed
      if (Array.isArray(parsed.recents)) {
        var rec = []
        for (var i = 0; i < parsed.recents.length && rec.length < root.maxRecents; i++) {
          var r = root.cleanPlace(parsed.recents[i])
          if (r) rec.push(r)
        }
        root.recents = rec
      }
    }
    root.settingsLoaded = true
  }

  property bool savingNow: false

  property Timer settingsSaveTimer: Timer {
    repeat: false
    interval: 300
    onTriggered: root.flushSettings()
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) root.settingsSaveTimer.restart()
  }

  function flushSettings() {
    root.savingNow = true
    root.settingsFile.setText(JSON.stringify({
      place: root.place,
      zoom: Math.round(root.zoom * 100) / 100,
      layer: root.layer,
      provider: root.provider,
      scheme: root.scheme,
      showForecast: root.showForecast,
      pollWhenClosed: root.pollWhenClosed,
      recents: root.recents
    }, null, 2) + "\n")
  }

  // The writer only. Reads go through safeRead above, because FileView cannot
  // stop short of the end of a file.
  property FileView settingsFile: FileView {
    path: root.settingsPath
    atomicWrites: true
    blockAllReads: true
    preload: false
    printErrors: false
    watchChanges: true
    onFileChanged: {
      if (root.savingNow) { root.savingNow = false; return }
      root.settingsReader.running = false
      root.settingsReader.running = true
    }
  }

  onZoomChanged: root.scheduleSettingsSave()
  onProviderChanged: root.scheduleSettingsSave()
  onSchemeChanged: root.scheduleSettingsSave()
  onPollWhenClosedChanged: root.scheduleSettingsSave()

  Component.onCompleted: {
    root.ensureStateDir.running = true
    root.settingsReader.running = true
    root.startHelper()
  }
}
