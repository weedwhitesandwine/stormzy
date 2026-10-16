import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."

// The bar icon. One glyph, theme-coloured, that toggles the radar window;
// the tooltip carries the place and how fresh the newest scan is.
Ui.BarWidget {
  id: root
  moduleName: StormzyState.pluginId

  readonly property bool showIcon: {
    var v = setting("showIcon", true)
    return !(v === false || v === "false" || v === 0 || v === "0")
  }

  readonly property string tooltip: {
    var parts = ["Stormzy"]
    if (StormzyState.place) parts.push(StormzyState.place.name + (StormzyState.place.country ? ", " + StormzyState.place.country : ""))
    else parts.push("choose a place")
    parts.push(StormzyState.ageText())
    // Omarchy renders tooltips as AutoText, so markup is stripped from a
    // place name that came off disk.
    return parts.join(" · ").replace(/[<>]/g, "")
  }

  implicitWidth: showIcon ? button.implicitWidth : 0
  implicitHeight: showIcon ? button.implicitHeight : 0

  Ui.WidgetButton {
    id: button
    visible: root.showIcon
    anchors.fill: parent
    bar: root.bar
    // Material Design "radar" from the Nerd Font: a glyph takes
    // the theme's bar foreground like every other icon up there.
    text: "󰐷"
    tooltipText: root.tooltip
    active: StormzyState.framesError !== "" && !!StormzyState.place
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar || b !== Qt.LeftButton) return
      root.bar.run("omarchy-shell shell toggle " + StormzyState.pluginId)
    }
  }
}
