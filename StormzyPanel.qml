import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import "."

// The radar window. One surface for everything: the map, the timeline, and a
// settings view where the place and the radar source are chosen.
// Toggled by the bar icon or by `omarchy-shell shell toggle <id>`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool settingsOpen: false
  property bool stayOnTop: false

  readonly property string pluginId: StormzyState.pluginId
  readonly property string pluginDir: StormzyState.pluginDir

  property color background: Color.popups.background
  property color foreground: Color.popups.text
  property color border: Color.popups.border
  property color accent: Color.accent
  property color muted: Color.muted
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  // Comfortable reading sizes: never below 14 px.
  readonly property int fontBody: Math.max(14, Style.font.body)
  readonly property int fontSmall: Math.max(13, Style.font.bodySmall)
  readonly property int fontTitle: Math.max(16, Style.font.title)
  readonly property int pad: Style.spacing.panelPadding

  function open(payloadJson) {
    root.opened = true
    root.stayOnTop = false
    root.settingsOpen = !StormzyState.place
    StormzyState.refreshFrames()
    root.placeMap()
    Qt.callLater(function() { root.focusView() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function focusView() {
    if (root.settingsOpen) searchField.forceActiveFocus()
    else mapKeys.forceActiveFocus()
  }

  function openSettings() {
    root.settingsOpen = true
    Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
  }

  function closeSettings() {
    root.settingsOpen = false
    Qt.callLater(function() { mapKeys.forceActiveFocus() })
  }

  onOpenedChanged: {
    if (root.opened) StormzyState.retain()
    else StormzyState.release()
  }
  Component.onDestruction: { if (root.opened) StormzyState.release() }

  // ---------------------------------------------------------------- map view

  property string placedFor: ""

  function placeKey(p) { return p ? (p.name + "|" + p.lat + "|" + p.lon) : "" }

  // The map opens on the chosen place at the remembered zoom; a change of
  // place moves it there. Panning never rewrites the place.
  function placeMap() {
    var p = StormzyState.place
    if (!p) return
    if (root.placedFor === placeKey(p)) return
    root.placedFor = placeKey(p)
    map.setView(p.lat, p.lon, StormzyState.zoom)
  }

  function goHome() {
    var p = StormzyState.place
    if (!p) { root.openSettings(); return }
    map.setView(p.lat, p.lon, map.zoom)
  }

  Connections {
    target: StormzyState
    function onPlaceChanged() { root.placeMap() }
    function onSearchReady(msg) { root.onSearch(msg) }
  }

  // ------------------------------------------------------------------ search

  property int searchReq: -1
  readonly property int resultCount: resultsModel.count
  ListModel { id: resultsModel }

  Timer {
    id: searchTimer
    interval: 160
    repeat: false
    onTriggered: {
      var q = searchField.text.trim()
      if (q.length < 2) { resultsModel.clear(); root.searchReq = -1; return }
      root.searchReq = StormzyState.search(q)
    }
  }

  function onSearch(msg) {
    if (msg.id !== root.searchReq) return
    var list = Array.isArray(msg.results) ? msg.results : []
    resultsModel.clear()
    for (var i = 0; i < list.length && resultsModel.count < 12; i++) {
      var p = StormzyState.cleanPlace(list[i])
      if (!p || !p.name) continue
      resultsModel.append({ name: p.name, cc: p.cc, country: p.country, admin: p.admin, lat: p.lat, lon: p.lon,
                            pop: typeof list[i].pop === "number" ? list[i].pop : 0 })
    }
  }

  function resultAt(i) {
    var r = resultsModel.get(i)
    return { name: r.name, cc: r.cc, country: r.country, admin: r.admin, lat: r.lat, lon: r.lon }
  }

  function choose(p) {
    StormzyState.choosePlace(p)
    searchField.text = ""
    resultsModel.clear()
    root.closeSettings()
  }

  function placeLine(p) {
    if (!p) return ""
    var parts = [p.name]
    if (p.admin && p.admin !== p.name) parts.push(p.admin)
    if (p.country) parts.push(p.country)
    return parts.join(", ")
  }

  // ----------------------------------------------------------------- legend

  readonly property var jmaLegend: [
    ["0–1", "#f2f2ff"], ["1–5", "#a0d2ff"], ["5–10", "#218cff"], ["10–20", "#0041ff"],
    ["20–30", "#faf500"], ["30–50", "#ff9900"], ["50–80", "#ff2800"], ["80+", "#b40068"]
  ]
  readonly property var schemes: [[2, "Universal blue"], [4, "Weather Channel"], [6, "NEXRAD"], [8, "Dark Sky"]]

  // ------------------------------------------------------------------ window

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontBody
    elide: Text.ElideRight
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool on: false
    property bool enabledChip: true
    signal clicked()
    implicitWidth: chipText.implicitWidth + 22
    implicitHeight: chipText.implicitHeight + 12
    radius: Math.max(4, Style.cornerRadius / 2)
    color: chip.on ? root.accent : "transparent"
    border.width: 1
    border.color: chip.on ? root.accent : root.muted
    opacity: chip.enabledChip ? 1 : 0.5
    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.on ? root.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontBody
    }
    MouseArea {
      anchors.fill: parent
      enabled: chip.enabledChip
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  component IconButton: Rectangle {
    id: ib
    property string glyph: ""
    property string tip: ""
    property bool on: false
    signal clicked()
    width: 34; height: 34
    radius: Math.max(4, Style.cornerRadius / 2)
    color: ibMouse.containsMouse || ib.on ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25) : "transparent"
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ib.glyph
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontTitle + 2
    }
    MouseArea {
      id: ibMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.clicked()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    implicitWidth: Math.min(1160, Math.round((panel.screen ? panel.screen.width : 1600) * 0.76))
    implicitHeight: Math.min(820, Math.round((panel.screen ? panel.screen.height : 900) * 0.84))
    color: "transparent"
    WlrLayershell.namespace: "stormzy"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.stayOnTop ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
      windows: [panel]
      active: root.opened && !root.stayOnTop
      onCleared: root.dismiss()
    }

    Rectangle {
      id: card
      anchors.fill: parent
      color: root.background
      radius: Style.cornerRadius
      border.width: Math.max(1, Style.space(2))
      border.color: root.border

      // ------------------------------------------------------------ header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.pad
        height: 36

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: 10
          Label { text: "󰐷"; font.pixelSize: root.fontTitle + 4; anchors.verticalCenter: parent.verticalCenter }
          Label { text: "STORMZY"; font.bold: true; font.letterSpacing: 2; font.pixelSize: root.fontTitle; anchors.verticalCenter: parent.verticalCenter }
          Label {
            anchors.verticalCenter: parent.verticalCenter
            text: StormzyState.place ? root.placeLine(StormzyState.place) : "no place chosen"
            opacity: 0.85
            width: Math.min(implicitWidth, header.width - 420)
          }
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!StormzyState.place
            implicitWidth: badge.implicitWidth + 14
            implicitHeight: badge.implicitHeight + 6
            radius: 4
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
            border.width: 1
            border.color: root.accent
            Label { id: badge; anchors.centerIn: parent; text: StormzyState.providerLabel; font.pixelSize: root.fontSmall; font.bold: true; color: root.accent }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          Label {
            anchors.verticalCenter: parent.verticalCenter
            text: StormzyState.ageText()
            color: StormzyState.framesError ? root.urgent : root.foreground
            opacity: StormzyState.framesError ? 1 : 0.75
            font.pixelSize: root.fontSmall
          }
          Item { width: 8; height: 1 }
          IconButton { glyph: "󰍎"; tip: "Back to my place"; onClicked: root.goHome() }
          IconButton { glyph: "󰒓"; tip: "Settings"; on: root.settingsOpen; onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings() }
          IconButton { glyph: "󰅖"; tip: "Close"; onClicked: root.dismiss() }
        }
      }

      // --------------------------------------------------------------- map
      Item {
        id: body
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.leftMargin: root.pad
        anchors.rightMargin: root.pad
        anchors.topMargin: 6
        anchors.bottomMargin: 6

        Rectangle {
          anchors.fill: parent
          radius: Math.max(4, Style.cornerRadius / 2)
          color: "transparent"
          border.width: 1
          border.color: Qt.rgba(root.muted.r, root.muted.g, root.muted.b, 0.5)
          clip: true

          RadarMap {
            id: map
            anchors.fill: parent
            anchors.margins: 1
            visible: !root.settingsOpen
            provider: StormzyState.effectiveProvider
            frameId: StormzyState.currentFrame ? StormzyState.currentFrame.id : ""
            nativeZoom: StormzyState.nativeZoom
            scheme: StormzyState.scheme
            foreground: root.foreground
            background: root.background
            accent: root.accent
            muted: root.muted
            fontFamily: root.fontFamily
            fontSize: root.fontSmall
            marker: StormzyState.place
            onUserMoved: StormzyState.zoom = map.zoom
          }

          // Keyboard driving of the map.
          Item {
            id: mapKeys
            anchors.fill: parent
            focus: !root.settingsOpen
            Keys.onPressed: function(event) {
              var step = 80
              switch (event.key) {
              case Qt.Key_Escape: root.dismiss(); break
              case Qt.Key_Space: StormzyState.togglePlay(); break
              case Qt.Key_BracketLeft: StormzyState.step(-1); break
              case Qt.Key_BracketRight: StormzyState.step(1); break
              case Qt.Key_Home: StormzyState.jumpOldest(); break
              case Qt.Key_End: StormzyState.jumpNewest(); break
              case Qt.Key_H: case Qt.Key_Left: map.pan(step, 0); break
              case Qt.Key_L: case Qt.Key_Right: map.pan(-step, 0); break
              case Qt.Key_K: case Qt.Key_Up: map.pan(0, step); break
              case Qt.Key_J: case Qt.Key_Down: map.pan(0, -step); break
              case Qt.Key_Plus: case Qt.Key_Equal: map.zoomBy(0.5); StormzyState.zoom = map.zoom; break
              case Qt.Key_Minus: map.zoomBy(-0.5); StormzyState.zoom = map.zoom; break
              case Qt.Key_0: root.goHome(); break
              case Qt.Key_S: case Qt.Key_Slash: root.openSettings(); break
              case Qt.Key_F: StormzyState.showForecast = !StormzyState.showForecast; break
              default: event.accepted = false; return
              }
              event.accepted = true
            }
          }

          Label {
            anchors.centerIn: parent
            visible: !root.settingsOpen && !StormzyState.place
            text: "Choose a place in settings (s)"
            opacity: 0.7
          }

          Label {
            anchors.centerIn: parent
            visible: !root.settingsOpen && !!StormzyState.place && !StormzyState.haveFrames
            text: StormzyState.framesError ? "Radar unreachable: " + StormzyState.framesError : "Loading radar…"
            color: StormzyState.framesError ? root.urgent : root.foreground
          }
        }

        // ---------------------------------------------------------- settings
        Flickable {
          id: settingsView
          anchors.fill: parent
          visible: root.settingsOpen
          contentHeight: settingsColumn.implicitHeight + 20
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: settingsColumn
            width: parent.width - 20
            x: 10
            y: 10
            spacing: 12

            Label { text: "PLACE"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Label {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Type a city, or a city and a country. A country on its own lists its biggest cities. Nothing is ever guessed from your connection."
              opacity: 0.75
              font.pixelSize: root.fontSmall
            }

            Rectangle {
              width: parent.width
              height: searchField.implicitHeight + 16
              radius: Math.max(4, Style.cornerRadius / 2)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              border.width: 1
              border.color: searchField.activeFocus ? root.accent : root.muted
              Label { text: "󰍉"; anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; opacity: 0.7 }
              TextInput {
                id: searchField
                anchors.fill: parent
                anchors.leftMargin: 36
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                selectByMouse: true
                selectionColor: root.accent
                clip: true
                maximumLength: 80
                onTextChanged: searchTimer.restart()
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.closeSettings(); event.accepted = true; return }
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (resultsModel.count > 0) root.choose(root.resultAt(0))
                    event.accepted = true
                  }
                }
                Label {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  visible: !searchField.text && !searchField.activeFocus
                  text: "City, or city, country — e.g. Osaka or London, UK"
                  opacity: 0.45
                }
              }
            }

            Column {
              width: parent.width
              spacing: 2
              Repeater {
                model: resultsModel
                delegate: Rectangle {
                  required property int index
                  required property string name
                  required property string admin
                  required property string country
                  required property int pop
                  width: settingsColumn.width
                  height: 34
                  radius: 4
                  color: rowMouse.containsMouse || index === 0 ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, index === 0 ? 0.18 : 0.12) : "transparent"
                  Label {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: popLabel.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: name + (admin && admin !== name ? ", " + admin : "") + (country ? ", " + country : "")
                  }
                  Label {
                    id: popLabel
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: pop >= 1000000 ? (pop / 1000000).toFixed(1) + " M" : (pop >= 1000 ? Math.round(pop / 1000) + " k" : "")
                    opacity: 0.55
                    font.pixelSize: root.fontSmall
                  }
                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.choose(root.resultAt(index))
                  }
                }
              }
            }

            Label { visible: StormzyState.recents.length > 0; text: "RECENT"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Flow {
              width: parent.width
              spacing: 8
              Repeater {
                model: StormzyState.recents
                delegate: Chip {
                  required property var modelData
                  label: modelData.name + (modelData.cc ? " · " + modelData.cc : "")
                  on: StormzyState.place && StormzyState.place.name === modelData.name && StormzyState.place.cc === modelData.cc
                  onClicked: root.choose(modelData)
                }
              }
            }

            Label { text: "RADAR SOURCE"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Flow {
              width: parent.width
              spacing: 8
              Chip { label: "Auto"; on: StormzyState.provider === "auto"; onClicked: StormzyState.provider = "auto" }
              Chip { label: "JMA (Japan, 5-minute, with forecast)"; on: StormzyState.provider === "jma"; onClicked: StormzyState.provider = "jma" }
              Chip { label: "RainViewer (worldwide, 10-minute)"; on: StormzyState.provider === "rainviewer"; onClicked: StormzyState.provider = "rainviewer" }
            }
            Label {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Auto uses the Japan Meteorological Agency for a place in Japan and RainViewer's composite of national radars everywhere else."
              opacity: 0.75
              font.pixelSize: root.fontSmall
            }

            Label { text: "RAINVIEWER COLOURS"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Flow {
              width: parent.width
              spacing: 8
              Repeater {
                model: root.schemes
                delegate: Chip {
                  required property var modelData
                  label: modelData[1]
                  on: StormzyState.scheme === modelData[0]
                  onClicked: StormzyState.scheme = modelData[0]
                }
              }
            }

            Label { text: "BEHAVIOUR"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Flow {
              width: parent.width
              spacing: 8
              Chip { label: (StormzyState.showForecast ? "✓ " : "") + "Show forecast frames (JMA)"; on: StormzyState.showForecast; onClicked: { StormzyState.showForecast = !StormzyState.showForecast } }
              Chip { label: (StormzyState.pollWhenClosed ? "✓ " : "") + "Refresh the frame list while closed (every 10 min)"; on: StormzyState.pollWhenClosed; onClicked: StormzyState.pollWhenClosed = !StormzyState.pollWhenClosed }
            }

            Label { text: "ABOUT"; font.bold: true; font.letterSpacing: 1.5; font.pixelSize: root.fontSmall; opacity: 0.7 }
            Label {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Radar: Japan Meteorological Agency (JMA) and RainViewer. Basemap: Natural Earth, bundled. Places: GeoNames, bundled. Tiles are cached under ~/.cache/stormzy."
              opacity: 0.75
              font.pixelSize: root.fontSmall
            }

            Chip { label: "Back to the map  (Esc)"; onClicked: root.closeSettings() }
          }
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.pad
        height: 92

        // Transport and timeline.
        Row {
          id: transport
          anchors.top: parent.top
          anchors.left: parent.left
          spacing: 2
          IconButton { glyph: "󰒮"; onClicked: StormzyState.jumpOldest() }
          IconButton { glyph: StormzyState.playing ? "󰏤" : "󰐊"; on: StormzyState.playing; onClicked: StormzyState.togglePlay() }
          IconButton { glyph: "󰒭"; onClicked: StormzyState.jumpNewest() }
        }

        Item {
          id: timeline
          anchors.left: transport.right
          anchors.leftMargin: 10
          anchors.right: stamp.left
          anchors.rightMargin: 12
          anchors.verticalCenter: transport.verticalCenter
          height: 24
          readonly property int count: StormzyState.frameModel.count
          readonly property real slot: count > 0 ? Math.min(18, width / count) : 0
          readonly property color tickColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
          readonly property color tickBorder: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.5)
          Repeater {
            model: StormzyState.frameModel
            delegate: Rectangle {
              required property string kind
              required property int index
              x: index * timeline.slot
              width: Math.max(2, timeline.slot - 2)
              height: index === StormzyState.frameIndex ? 22 : (kind === "forecast" ? 10 : 14)
              anchors.verticalCenter: parent.verticalCenter
              radius: 2
              color: index === StormzyState.frameIndex ? root.accent : (kind === "forecast" ? "transparent" : timeline.tickColor)
              border.width: kind === "forecast" ? 1 : 0
              border.color: timeline.tickBorder
              MouseArea { anchors.fill: parent; anchors.margins: -1; cursorShape: Qt.PointingHandCursor; onClicked: StormzyState.selectFrame(index) }
            }
          }
        }

        Label {
          id: stamp
          anchors.right: parent.right
          anchors.verticalCenter: transport.verticalCenter
          text: StormzyState.stampText(StormzyState.currentFrame)
          font.bold: true
        }

        // Legend and attribution.
        Row {
          id: legend
          anchors.left: parent.left
          anchors.top: transport.bottom
          anchors.topMargin: 8
          spacing: 6
          visible: StormzyState.effectiveProvider === "jma"
          Label { text: "mm/h"; opacity: 0.7; font.pixelSize: root.fontSmall; anchors.verticalCenter: parent.verticalCenter }
          Repeater {
            model: root.jmaLegend
            delegate: Row {
              required property var modelData
              spacing: 3
              Rectangle { width: 14; height: 14; radius: 2; color: modelData[1]; anchors.verticalCenter: parent.verticalCenter }
              Label { text: modelData[0]; font.pixelSize: root.fontSmall; opacity: 0.85; anchors.verticalCenter: parent.verticalCenter }
            }
          }
        }
        Label {
          anchors.left: parent.left
          anchors.top: transport.bottom
          anchors.topMargin: 8
          visible: StormzyState.effectiveProvider !== "jma"
          text: "Colour is radar reflectivity: blue light, yellow and red heavy."
          opacity: 0.7
          font.pixelSize: root.fontSmall
        }
        Label {
          anchors.right: parent.right
          anchors.top: transport.bottom
          anchors.topMargin: 8
          text: (StormzyState.effectiveProvider === "jma" ? "Radar © Japan Meteorological Agency" : "Radar © RainViewer") + "  ·  Map: Natural Earth"
          opacity: 0.55
          font.pixelSize: root.fontSmall
        }

        Label {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          text: "space play  ·  [ ] step  ·  home/end  ·  drag or scroll  ·  hjkl pan  ·  + − zoom  ·  0 my place  ·  s search  ·  f forecast  ·  esc close"
          opacity: 0.45
          font.pixelSize: root.fontSmall
        }
      }
    }
  }
}
