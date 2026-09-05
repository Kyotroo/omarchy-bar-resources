import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Live CPU/memory/disk/temperature/network usage in the bar, each shown as
// an icon that fills up with usage (like the battery/wifi icons) plus an
// optional number. Click opens this widget's own settings panel — what to
// track, in what order, whether to show the percentage text — there is no
// other window behind it.
Panel {
  id: root
  moduleName: "kdm.resources"
  ipcTarget: "kdm.resources"
  manageIpc: false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var settingDefaults: ({
    showPercent: true, accentFill: true,
    trackCpu: true, trackMem: true, trackDisk: true, trackTemp: true, trackNet: false
  })
  readonly property var displayOptionRows: [
    { key: "showPercent", label: "Show percentage", description: "Show the exact % next to the CPU, memory, and disk icons." },
    { key: "accentFill", label: "Use accent color", description: "Color the filled portion of each icon with your theme's accent color instead of a plain highlight." }
  ]

  readonly property bool showPercent: setting("showPercent", settingDefaults.showPercent)
  readonly property bool accentFill: setting("accentFill", settingDefaults.accentFill)
  readonly property bool trackCpu: setting("trackCpu", settingDefaults.trackCpu)
  readonly property bool trackMem: setting("trackMem", settingDefaults.trackMem)
  readonly property bool trackDisk: setting("trackDisk", settingDefaults.trackDisk)
  readonly property bool trackTemp: setting("trackTemp", settingDefaults.trackTemp)
  readonly property bool trackNet: setting("trackNet", settingDefaults.trackNet)
  readonly property bool anyTracked: trackCpu || trackMem || trackDisk || trackTemp || trackNet

  // Bar display order, user-configurable via the settings panel's ▲▼
  // buttons. Sanitized against known keys so a stale/hand-edited setting
  // (or a future new metric not yet in someone's saved order) never hides
  // or duplicates an entry.
  readonly property var defaultOrder: ["cpu", "mem", "disk", "temp", "net"]
  readonly property var order: {
    var raw = setting("order", root.defaultOrder)
    if (!Array.isArray(raw)) return root.defaultOrder
    var seen = ({})
    var result = []
    for (var i = 0; i < raw.length; i++) {
      var k = String(raw[i])
      if (root.defaultOrder.indexOf(k) !== -1 && !seen[k]) { result.push(k); seen[k] = true }
    }
    for (var j = 0; j < root.defaultOrder.length; j++) if (!seen[root.defaultOrder[j]]) result.push(root.defaultOrder[j])
    return result
  }

  // Mobile Intel/AMD packages throttle around 100C; treat this band as the
  // icon's 0-100% fill range so the thermometer reads "getting warm" well
  // before anything is actually wrong.
  readonly property real tempFloor: 30
  readonly property real tempCeiling: 95

  property int selectedIndex: 0
  property bool cursorActive: false

  property var prevCpuSample: null
  property var prevNetSample: null
  property real prevNetSampleTime: 0
  property string tempSensorPath: ""
  property bool tempSensorResolved: false

  property int cpuPct: -1
  property int memPct: -1
  property real memTotalBytes: 0
  property real memUsedBytes: 0
  property int diskPct: -1
  property real diskTotalBytes: 0
  property real diskUsedBytes: 0
  property var tempC: null
  property real netDownBps: 0
  property real netUpBps: 0
  property bool netReady: false

  function refresh() {
    if (!sampleProc.running) sampleProc.running = true
  }

  // The sensor path is discovered once (it doesn't move between polls), so
  // every regular sample just cats the fixed path instead of re-globbing
  // /sys/class/hwmon each tick.
  function rebuildSampleCommand() {
    var tempCat = root.tempSensorPath !== "" ? ("cat " + Util.shellQuote(root.tempSensorPath) + " 2>/dev/null") : "true"
    var script = [
      "echo ===STAT===", "cat /proc/stat",
      "echo ===MEM===", "cat /proc/meminfo",
      "echo ===NET===", "cat /proc/net/dev",
      "echo ===TEMP===", tempCat,
      "echo ===DISK===", "df -B1 --output=size,used,avail,pcent /"
    ].join("\n")
    sampleProc.command = ["bash", "-c", script]
  }

  function applySample(text) {
    var now = Date.now()
    var s = Model.splitSections(text)

    var cpu = Model.parseCpuLine(s.STAT || "")
    if (cpu) {
      var pct = Model.cpuPercent(root.prevCpuSample, cpu)
      if (pct !== null) root.cpuPct = Math.max(0, Math.min(100, pct))
      root.prevCpuSample = cpu
    }

    var mem = Model.parseMem(s.MEM || "")
    if (mem) {
      root.memPct = mem.usedPct
      root.memTotalBytes = mem.totalKb * 1024
      root.memUsedBytes = (mem.totalKb - mem.availKb) * 1024
    }

    var net = Model.parseNetDev(s.NET || "")
    if (root.prevNetSample && root.prevNetSampleTime > 0) {
      var rate = Model.netRate(root.prevNetSample, net, (now - root.prevNetSampleTime) / 1000)
      if (rate) {
        root.netDownBps = rate.rxBps
        root.netUpBps = rate.txBps
        root.netReady = true
      }
    }
    root.prevNetSample = net
    root.prevNetSampleTime = now

    root.tempC = Model.parseTemp(s.TEMP || "")

    var disk = Model.parseDisk(s.DISK || "")
    if (disk) {
      root.diskPct = disk.usedPct
      root.diskTotalBytes = disk.totalBytes
      root.diskUsedBytes = disk.usedBytes
    }
  }

  function persistSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleSetting(key) {
    root.persistSetting(key, !root.setting(key, root.settingDefaults[key]))
  }

  function trackKeyFor(metricKey) {
    return "track" + metricKey.charAt(0).toUpperCase() + metricKey.slice(1)
  }

  function moveMetric(key, delta) {
    var current = root.order.slice()
    var idx = current.indexOf(key)
    if (idx < 0) return
    var next = idx + delta
    if (next < 0 || next >= current.length) return
    var tmp = current[next]
    current[next] = current[idx]
    current[idx] = tmp
    root.persistSetting("order", current)
  }

  function totalRowCount() {
    return root.displayOptionRows.length + root.order.length
  }

  function moveCursor(dy) {
    root.selectedIndex = Math.max(0, Math.min(root.totalRowCount() - 1, root.selectedIndex + dy))
  }

  function activateSelected() {
    var i = root.selectedIndex
    if (i < root.displayOptionRows.length) {
      root.toggleSetting(root.displayOptionRows[i].key)
      return
    }
    var key = root.order[i - root.displayOptionRows.length]
    if (key) root.toggleSetting(root.trackKeyFor(key))
  }

  function tempText() {
    if (root.tempC !== null) return Math.round(root.tempC) + "°C"
    return root.tempSensorResolved ? "n/a" : "…"
  }

  // ---- Per-metric lookups, shared by the bar row and the settings panel
  //      so both always agree on label/value/fill/urgency for a given key.
  function metricLabel(key) {
    if (key === "cpu") return "CPU usage"
    if (key === "mem") return "Memory usage"
    if (key === "disk") return "Disk space"
    if (key === "temp") return "CPU temperature"
    if (key === "net") return "Network speed"
    return key
  }

  function metricTracked(key) {
    if (key === "cpu") return root.trackCpu
    if (key === "mem") return root.trackMem
    if (key === "disk") return root.trackDisk
    if (key === "temp") return root.trackTemp
    if (key === "net") return root.trackNet
    return false
  }

  function metricGlyph(key) {
    if (key === "cpu") return ""    // GLYPH:cpu
    if (key === "mem") return ""    // GLYPH:mem
    if (key === "disk") return ""   // GLYPH:disk
    if (key === "temp") return ""   // GLYPH:temp
    return ""
  }

  function metricFraction(key) {
    if (key === "cpu") return root.cpuPct / 100
    if (key === "mem") return root.memPct / 100
    if (key === "disk") return root.diskPct / 100
    if (key === "temp") return root.tempC !== null ? (root.tempC - root.tempFloor) / (root.tempCeiling - root.tempFloor) : 0
    return 0
  }

  function metricUrgent(key) {
    if (key === "cpu") return root.cpuPct >= 90
    if (key === "mem") return root.memPct >= 90
    if (key === "disk") return root.diskPct >= 90
    if (key === "temp") return root.tempC !== null && root.tempC >= 85
    return false
  }

  function metricValueText(key) {
    if (key === "cpu") return root.cpuPct >= 0 ? (root.cpuPct + "%") : "…"
    if (key === "mem") return root.memPct >= 0 ? (root.memPct + "%") : "…"
    if (key === "disk") return root.diskPct >= 0 ? (root.diskPct + "%") : "…"
    if (key === "temp") return root.tempText()
    return ""
  }

  // Live readout shown as each metric row's description in the settings
  // panel, so you can see the current value even while deciding whether to
  // enable it — instead of a separate summary line elsewhere in the panel.
  function metricSummary(key) {
    if (key === "cpu") return root.cpuPct >= 0 ? ("Currently " + root.cpuPct + "%") : "Reading…"
    if (key === "mem") return root.memPct >= 0
      ? ("Currently " + root.memPct + "% (" + Model.formatBytes(root.memUsedBytes) + " / " + Model.formatBytes(root.memTotalBytes) + ")")
      : "Reading…"
    if (key === "disk") return root.diskPct >= 0
      ? ("Currently " + root.diskPct + "% (" + Model.formatBytes(root.diskUsedBytes) + " / " + Model.formatBytes(root.diskTotalBytes) + ")")
      : "Reading…"
    if (key === "temp") return "Currently " + root.tempText()
    if (key === "net") return root.netReady
      ? ("Currently ↓" + Model.formatRate(root.netDownBps) + "  ↑" + Model.formatRate(root.netUpBps))
      : "Reading…"
    return ""
  }

  function tooltipText() {
    var lines = []
    for (var i = 0; i < root.order.length; i++) {
      var key = root.order[i]
      if (root.metricTracked(key)) lines.push(root.metricLabel(key) + ": " + root.metricSummary(key).replace("Currently ", ""))
    }
    lines.push("Click for settings")
    return lines.join("\n")
  }

  Component.onCompleted: {
    rebuildSampleCommand()
    tempDiscoveryProc.running = true
    refresh()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    selectedIndex = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // One-time discovery of the package-temperature hwmon node. coretemp is
  // Intel, k10temp/zenpower are AMD — whichever is present on this machine
  // wins; if neither exists (e.g. a VM, or hardware with no exposed sensor)
  // the temperature metric just reports unavailable instead of guessing.
  Process {
    id: tempDiscoveryProc
    command: ["bash", "-c",
      "for d in /sys/class/hwmon/hwmon*; do n=$(cat \"$d/name\" 2>/dev/null); " +
      "case \"$n\" in coretemp|k10temp|zenpower) echo \"$d/temp1_input\"; break;; esac; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.tempSensorPath = String(text || "").trim()
        root.tempSensorResolved = true
        root.rebuildSampleCommand()
        root.refresh()
      }
    }
  }

  Process {
    id: sampleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(text)
    }
  }

  Timer {
    interval: Number(root.setting("intervalMs", 2000))
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "kdm.resources"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // Fixed layout widths for each value field's worst-case text, so the
  // bar's total width only changes when a metric is toggled on/off (a rare,
  // deliberate action) — never on every 2s tick just because "9%" became
  // "10%" or "12KB/s" became "1.2MB/s". A shifting-width clickable bar
  // widget risks misclicks on whatever sits next to it.
  TextMetrics { id: pctWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "100%" }
  TextMetrics { id: tempWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "999°C" }
  TextMetrics { id: netWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "999.9MB/s" }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Math.max(12, contentRow.implicitWidth + scaledHorizontalMargin * 2)
    tooltipText: root.tooltipText()

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      Repeater {
        model: root.order

        Row {
          id: metricSlot
          required property string modelData
          visible: root.metricTracked(modelData)
          spacing: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter

          FillIcon {
            visible: metricSlot.modelData !== "net"
            anchors.verticalCenter: parent.verticalCenter
            glyph: root.metricGlyph(metricSlot.modelData)
            fraction: root.metricFraction(metricSlot.modelData)
            pixelSize: Style.font.body
            fontFamily: root.fontFamily
            fillColor: root.metricUrgent(metricSlot.modelData)
              ? root.urgent
              : (root.accentFill ? Color.accent : root.foreground)
          }
          Text {
            visible: metricSlot.modelData !== "net" && (metricSlot.modelData === "temp" || root.showPercent)
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.metricValueText(metricSlot.modelData)
            width: metricSlot.modelData === "temp" ? tempWidthMetrics.width : pctWidthMetrics.width
            // Left-aligned, not right: the reserved width still keeps the
            // bar's total width stable, but the digits stay glued to their
            // own icon instead of drifting to the right edge of the box —
            // right-aligned, a short value like "2%" sat flush against the
            // *next* metric's icon instead of its own.
            horizontalAlignment: Text.AlignLeft
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Network has no natural 0-100% cap, so it gets two plain
          // fixed-width readouts instead of a fill icon.
          Row {
            visible: metricSlot.modelData === "net"
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter

            Row {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "↓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                text: root.netReady ? Model.formatRate(root.netDownBps) : "…"
                width: netWidthMetrics.width
                horizontalAlignment: Text.AlignLeft
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            Row {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "↑"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                text: root.netReady ? Model.formatRate(root.netUpBps) : "…"
                width: netWidthMetrics.width
                horizontalAlignment: Text.AlignLeft
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      Text {
        visible: !root.anyTracked
        text: ""   // GLYPH:fallback
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "Resources"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""   // GLYPH:hero
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DISPLAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.displayOptionRows

                Toggle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  label: modelData.label
                  description: modelData.description
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  checked: root.setting(modelData.key, root.settingDefaults[modelData.key])
                  hasCursor: root.cursorActive && root.selectedIndex === index
                  onClicked: root.toggleSetting(modelData.key)
                  onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = index } }
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "METRICS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.order

                RowLayout {
                  id: metricRow
                  required property string modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(6)

                  ColumnLayout {
                    spacing: Style.space(2)

                    PanelActionButton {
                      iconText: "▲"
                      tooltipText: "Move up"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      size: Style.space(18)
                      fontSize: Style.font.caption
                      enabled: metricRow.index > 0
                      onClicked: root.moveMetric(metricRow.modelData, -1)
                    }
                    PanelActionButton {
                      iconText: "▼"
                      tooltipText: "Move down"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      size: Style.space(18)
                      fontSize: Style.font.caption
                      enabled: metricRow.index < root.order.length - 1
                      onClicked: root.moveMetric(metricRow.modelData, 1)
                    }
                  }

                  Toggle {
                    Layout.fillWidth: true
                    label: root.metricLabel(metricRow.modelData)
                    description: root.metricSummary(metricRow.modelData)
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    checked: root.metricTracked(metricRow.modelData)
                    hasCursor: root.cursorActive && root.selectedIndex === (root.displayOptionRows.length + metricRow.index)
                    onClicked: root.toggleSetting(root.trackKeyFor(metricRow.modelData))
                    onHovered: function(on) {
                      if (on) { root.cursorActive = true; root.selectedIndex = root.displayOptionRows.length + metricRow.index }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // A glyph rendered twice — dim underneath, bright on top clipped to
  // `fraction` of the glyph's own ink height, bottom edge fixed — so it
  // fills like a battery/wifi icon instead of swapping between a handful
  // of stepped glyphs (no such stepped set exists for a chip/RAM/disk/
  // thermometer icon). Clipping against the *ink* bounds (via TextMetrics)
  // rather than the font's full line-height box matters: Nerd Font icons
  // sit centered in a line box with real padding above and below, so a
  // clip against the raw text height leaves a low fraction invisible —
  // clipped entirely within that padding rather than against the glyph.
  component FillIcon: Item {
    id: fillRoot
    property string glyph: ""
    property real fraction: 0
    property color fillColor: Color.foreground
    property color emptyColor: fillColor
    property real emptyOpacity: 0.28
    property real pixelSize: Style.font.body
    property string fontFamily: Style.font.family

    implicitWidth: emptyGlyph.implicitWidth
    implicitHeight: emptyGlyph.implicitHeight

    TextMetrics {
      id: ink
      font.family: fillRoot.fontFamily
      font.pixelSize: fillRoot.pixelSize
      text: fillRoot.glyph
    }

    readonly property real inkTop: emptyGlyph.baselineOffset + ink.tightBoundingRect.y
    readonly property real inkHeight: Math.max(1, ink.tightBoundingRect.height)
    readonly property real inkBottom: inkTop + inkHeight

    Text {
      id: emptyGlyph
      textFormat: Text.PlainText
      text: fillRoot.glyph
      color: fillRoot.emptyColor
      opacity: fillRoot.emptyOpacity
      font.family: fillRoot.fontFamily
      font.pixelSize: fillRoot.pixelSize
      renderType: Text.NativeRendering
    }

    Item {
      id: clipMask
      x: 0
      width: fillRoot.width
      clip: true
      y: fillRoot.inkBottom - fillRoot.inkHeight * Math.max(0, Math.min(1, fillRoot.fraction))
      height: fillRoot.inkBottom - y

      Text {
        x: 0
        y: -clipMask.y
        width: emptyGlyph.width
        textFormat: Text.PlainText
        text: fillRoot.glyph
        color: fillRoot.fillColor
        font.family: fillRoot.fontFamily
        font.pixelSize: fillRoot.pixelSize
        renderType: Text.NativeRendering
      }
    }
  }
}
