import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Every fact comes from script/zmk-status on a timer. ARCHITECTURE.md
// explains why it polls instead of listening.
Panel {
  id: root
  moduleName: "ashmortar.zmk"
  ipcTarget: "ashmortar.zmk"
  // The Panel default handler has no refresh, reconnect, togglePercent, or
  // status, so IPC is wired up by hand below.
  manageIpc: false

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 10, 600)
  readonly property int lowThreshold: intSetting("lowThreshold", 15, 5, 50)
  readonly property string macAddress: String(setting("macAddress", "") || "")
  readonly property string usbId: String(setting("usbId", "") || "") || "1D50:615E"
  readonly property string deviceName: String(setting("deviceName", "") || "") || "ZMK keyboard"
  readonly property bool showPercent: setting("showPercent", false) === true
  readonly property string scriptPath: Qt.resolvedUrl("script/zmk-status").toString().replace("file://", "")

  property var status: null
  property bool failed: false
  property int lastExitCode: 0
  property string updatedAt: ""
  property bool wakeBusy: false
  property string actionError: ""

  readonly property bool found: status !== null && status.found === true
  readonly property bool connected: status !== null && status.connected === true
  readonly property bool bleUp: status !== null && status.ble === true
  readonly property bool cable: status !== null && status.cable === true
  readonly property bool hidBound: status !== null && status.hid === true
  readonly property bool wired: status !== null && status.type === "wired"
  readonly property bool wake: status !== null && status.wake === true
  readonly property var batteries: status && Array.isArray(status.batteries) ? status.batteries : []
  readonly property bool anyLow: batteries.some(function(b) {
    return b && b.value !== null && b.charging !== true && b.value <= root.lowThreshold
  })
  readonly property string address: status && status.address ? status.address : macAddress
  readonly property string displayName: status && status.name ? status.name : deviceName

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color trackColor: Style.selectedFillFor(foreground, Color.accent)
  // With percentages the button paints a text block wider than an icon, so
  // the open-panel mark takes the painted width instead of a slot fraction.
  readonly property real openPanelIndicatorWidth: showPercent && !button.vertical ? button.glyphPaintedWidth : 0

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (reader.running) return
    reader.running = true
    readerWatchdog.restart()
  }

  function connectBluetooth() {
    if (!found || bleUp) return
    if (!status || !status.path || connectProc.running) return
    connectProc.command = ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/busctl", "call", "org.bluez", status.path, "org.bluez.Device1", "Connect"]
    connectProc.running = true
  }

  function togglePercent() {
    root.settings = Object.assign({}, root.settings, { showPercent: !root.showPercent })
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function toggleWake() {
    if (!root.found) return
    if (!status || !status.path || wakeBusy) return
    wakeBusy = true
    wakeProc.command = ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/busctl", "set-property", "org.bluez", status.path, "org.bluez.Device1", "WakeAllowed", "b", wake ? "false" : "true"]
    wakeProc.running = true
  }

  function openStudio() {
    if (bar && hidBound) bar.run("/usr/bin/xdg-open https://zmk.studio")
  }

  function statusLabel() {
    if (failed) return "Error"
    if (!found) return "No keyboard"
    if (wired) return "Wired"
    if (connected) return "Bluetooth"
    return "Not connected"
  }

  function chargingNames() {
    return batteries.filter(function(b) {
      return b && b.charging === true && b.name
    }).map(function(b) {
      return b.name
    })
  }

  function heroMeta() {
    if (failed) return "Status script failed"
    if (status && status.error) return status.error
    if (!found) return "No ZMK keyboard found"
    var parts = [statusLabel()]
    var charging = chargingNames()
    var anyCharging = batteries.some(function(b) { return b && b.charging === true })
    if (charging.length > 0) parts.push(charging.join(", ") + " charging")
    else if (anyCharging) parts.push("Charging")
    else if (cable && !hidBound) parts.push("cable on a peripheral")
    return parts.join(" · ")
  }

  function heroDetail() {
    if (actionError) return actionError
    if (status && status.warning) return status.warning
    if (!found) return "Pair the keyboard over Bluetooth. Set macAddress only to pin one of several boards."
    if (!bleUp && status.lastseen) return "Last seen " + status.lastseen
    return updatedAt !== "" ? "Updated " + updatedAt : ""
  }

  function barText() {
    // A vertical bar has no room beside the glyph for digits.
    if (!showPercent || button.vertical || batteries.length === 0) return "󰌌"
    var parts = batteries.map(function(b) {
      if (!b || b.value === null) return "?"
      if (b.charging === true) return "󱐋"
      return String(b.value)
    })
    return "󰌌 " + parts.join(" ")
  }

  function tooltipText() {
    if (failed) return "ZMK status script failed (exit " + lastExitCode + ")"
    if (status === null) return "Reading ZMK keyboard status…"
    if (status.error) return "ZMK: " + status.error
    if (status.tooltip) return status.tooltip
    return "ZMK keyboard status unavailable"
  }

  function batteryLow(b) {
    return !!b && b.value !== null && b.value <= root.lowThreshold
  }

  function batteryColor(b) {
    if (b && b.charging === true) return Color.accent
    return batteryLow(b) ? root.urgent : root.foreground
  }

  function readoutText(b) {
    if (!b || b.value === null) return "?"
    if (b.charging === true) return "󱐋"
    return b.value + "%"
  }

  function noBatteriesText() {
    if (!found) return "Nothing to show until a ZMK board is paired"
    if (bleUp) return "Connected, no battery service reported yet"
    if (wired) return "Battery is only exposed over Bluetooth"
    return "Not connected"
  }

  function detailRows() {
    var rows = []
    if (!status) return rows
    if (!found) {
      rows.push(["USB id", usbId])
      rows.push(["MAC", macAddress !== "" ? macAddress : "auto"])
      return rows
    }
    if (status.devid) rows.push(["Device", status.devid])
    if (status.usbSerial) rows.push(["Serial", status.usbSerial])
    if (address) rows.push(["Address", address])
    return rows
  }

  function handleOutput(line) {
    var text = String(line || "").trim()
    if (text === "") return
    // The script bounds its own output, so a longer line means something
    // else is talking.
    if (text.length > 65536) {
      failed = true
      lastExitCode = 0
      return
    }
    try {
      status = JSON.parse(text)
      failed = false
      actionError = ""
      updatedAt = new Date().toLocaleTimeString(Qt.locale(), "HH:mm")
    } catch (e) {
      failed = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refresh()
    // The panel window is not yet mapped when opened flips, so focus has
    // to wait a tick.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function reconnect(): string { root.connectBluetooth(); return "ok" }
    function togglePercent(): string { root.togglePercent(); return "ok" }
    function status(): string { return root.status ? JSON.stringify(root.status) : "" }
  }

  Process {
    id: reader
    command: [root.scriptPath, root.macAddress, root.usbId, String(root.lowThreshold), String(root.refreshIntervalSec)]
    stdout: SplitParser {
      onRead: function(data) { root.handleOutput(data) }
    }
    onExited: function(exitCode) {
      readerWatchdog.stop()
      root.lastExitCode = exitCode
      if (exitCode !== 0) root.failed = true
    }
    // A process that never starts fires no onExited at all, so without
    // this the first poll would look like it was still loading forever.
    onRunningChanged: if (!running && root.status === null && !root.failed) { root.failed = true; root.lastExitCode = -1 }
  }

  Process {
    id: wakeProc
    onExited: function(code) {
      root.wakeBusy = false
      root.actionError = code === 0 ? "" : "Wake toggle failed (exit " + code + ")"
      root.refresh()
    }
    onRunningChanged: if (!running) root.wakeBusy = false
  }

  Process {
    id: connectProc
    onExited: function(code) {
      root.actionError = code === 0 ? "" : "Connect failed (exit " + code + ")"
      root.refresh()
    }
  }

  // A poll is skipped while the previous run is alive, so a hung run would
  // otherwise block every later refresh. The script's own timeouts keep it
  // well under this ceiling.
  Timer {
    id: readerWatchdog
    interval: 30000
    onTriggered: if (reader.running) reader.running = false
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText()
    // 0.8 is roughly the painted width of two digits and a space at the
    // bar font, one slot per battery instance shown.
    slotSize: Style.bar.iconSlot * (root.showPercent && !vertical && root.batteries.length > 0 ? 1 + 0.8 * root.batteries.length : 1)
    foreground: root.wired ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
    dimmed: !root.connected || root.failed
    active: root.anyLow
    tooltipText: root.tooltipText()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePercent()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.connectBluetooth()
        else if (key === "w") root.toggleWake()
        else if (key === "p") root.togglePercent()
        else if (key === "s") root.openStudio()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.xl

        PanelHero {
          width: parent.width
          // PanelHero renders the title itself, so it cannot be forced to
          // plain text here; the script strips angle brackets at the source.
          title: root.displayName
          meta: root.heroMeta()
          detail: root.heroDetail()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰌌"
              color: root.wired ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          id: batteryColumn
          width: parent.width
          spacing: Style.spacing.lg
          visible: root.batteries.length > 0

          property real readoutWidth: 0

          function recomputeReadoutWidth() {
            var widest = 0
            for (var i = 0; i < batteryRows.count; i++) {
              var item = batteryRows.itemAt(i)
              if (item && item.readoutImplicitWidth > widest) widest = item.readoutImplicitWidth
            }
            // New delegates report zero width until laid out; keep the
            // prior width until a real one arrives. Only an empty model
            // may zero it.
            if (widest > 0 || batteryRows.count === 0) readoutWidth = widest
          }

          Repeater {
            id: batteryRows
            model: root.batteries.length
            onItemRemoved: batteryColumn.recomputeReadoutWidth()
            onItemAdded: batteryColumn.recomputeReadoutWidth()

            delegate: Item {
              id: row
              required property int index
              readonly property var battery: root.batteries[index]
              readonly property real level: battery && battery.value !== null ? Math.max(0, Math.min(100, battery.value)) : 0
              readonly property real readoutImplicitWidth: readoutRow.implicitWidth
              onReadoutImplicitWidthChanged: batteryColumn.recomputeReadoutWidth()
              Component.onCompleted: batteryColumn.recomputeReadoutWidth()

              width: parent.width
              height: Style.space(22)

              Text {
                id: rowLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: row.battery && row.battery.name ? Style.space(84) : 0
                text: row.battery && row.battery.name ? row.battery.name : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideRight
              }

              Rectangle {
                anchors.left: rowLabel.right
                anchors.leftMargin: rowLabel.width > 0 ? Style.spacing.md : 0
                anchors.right: readout.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: height / 2
                color: root.trackColor

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: parent.width * row.level / 100
                  radius: parent.radius
                  color: root.batteryColor(row.battery)

                  Behavior on width {
                    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                  }
                }
              }

              // The column is as wide as the widest readout so every track
              // ends at the same point without a gap.
              Item {
                id: readout
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: batteryColumn.readoutWidth
                height: parent.height

                Row {
                  id: readoutRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.md

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.battery && row.battery.eta
                    text: row.battery && row.battery.eta ? "~" + row.battery.eta : ""
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.readoutText(row.battery)
                    textFormat: Text.PlainText
                    color: root.batteryColor(row.battery)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.batteries.length === 0
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: root.noBatteriesText()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.detailRows()

            delegate: Item {
              required property var modelData
              width: parent.width
              height: Style.space(14)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[0]
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[1]
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(24)
            visible: root.found

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Wake for input"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            ToggleSwitch {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.wake
              busy: root.wakeBusy
              foreground: root.foreground
              onToggled: root.toggleWake()
            }
          }
        }

        Button {
          visible: root.found && !root.bleUp && !!(root.status && root.status.path)
          width: parent.width
          text: "Connect Bluetooth"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.connectBluetooth()
        }

        Text {
          width: parent.width
          visible: root.found
          horizontalAlignment: Text.AlignHCenter
          text: root.hidBound ? "Open ZMK Studio" : "ZMK Studio needs the USB cable"
          color: root.hidBound ? root.foreground : root.dim
          opacity: root.hidBound ? (studioArea.containsMouse ? 1.0 : 0.75) : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.underline: root.hidBound

          MouseArea {
            id: studioArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.hidBound
            cursorShape: root.hidBound ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.openStudio()
          }
        }
      }
    }
  }
}
