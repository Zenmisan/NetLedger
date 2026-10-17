import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "dev.zenmi.netledger"

  readonly property string dbPath: setting("dbPath", "/var/lib/netledger/ledger.db")
  readonly property int pollInterval: Math.max(1, setting("refreshIntervalSec", 2)) * 1000

  property real rxRate: 0.0
  property real txRate: 0.0
  property string topProcess: ""
  property string topCategory: ""

  readonly property color cyanColor: "#22d3ee"
  readonly property color amberColor: "#f59e0b"

  // Open / Close state contract for Omarchy bar
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("dbPath" in target) target.dbPath = root.dbPath
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Periodic poll of live rates from SQLite live_summary
  Timer {
    id: pollTimer
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!liveQueryProc.running) {
        liveQueryProc.command = [
          "sqlite3",
          "--json",
          root.dbPath,
          "SELECT rx_rate, tx_rate, top_process, top_category FROM live_summary WHERE id=1;"
        ]
        liveQueryProc.running = true
      }
    }
  }

  Process {
    id: liveQueryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var trimmed = String(text || "").trim()
          if (!trimmed || trimmed === "") return
          var rows = JSON.parse(trimmed)
          if (rows && rows.length > 0) {
            var row = rows[0]
            root.rxRate = parseFloat(row.rx_rate || 0.0)
            root.txRate = parseFloat(row.tx_rate || 0.0)
            root.topProcess = String(row.top_process || "")
            root.topCategory = String(row.top_category || "")
          }
        } catch (e) {
          // Ignore transient JSON parse errors during DB write
        }
      }
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "dev.zenmi.netledger"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: 8
    verticalPadding: 4

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }

    contentItem: RowLayout {
      id: contentRow
      spacing: 6
      anchors.centerIn: parent

      // Dynamic #1 Process badge if throughput > 100 KB/s (102400 B/s)
      RowLayout {
        visible: (root.rxRate + root.txRate) > 102400 && root.topProcess !== ""
        spacing: 3

        Text {
          text: Model.categoryIcon(root.topCategory)
          font.pixelSize: 11
          color: root.bar ? root.bar.foreground : Color.foreground
        }

        Text {
          text: root.topProcess.length > 12 ? root.topProcess.substring(0, 10) + "…" : root.topProcess
          font.pixelSize: 10
          font.bold: true
          color: root.bar ? root.bar.foreground : Color.foreground
          elide: Text.ElideRight
        }
      }

      // Stacked Cyan Download and Amber Upload rates
      ColumnLayout {
        spacing: 0

        RowLayout {
          spacing: 2
          Text {
            text: "↓"
            font.pixelSize: 9
            font.bold: true
            color: root.cyanColor
          }
          Text {
            text: Model.formatRate(root.rxRate)
            font.pixelSize: 9
            font.bold: true
            color: root.cyanColor
          }
        }

        RowLayout {
          spacing: 2
          Text {
            text: "↑"
            font.pixelSize: 9
            font.bold: true
            color: root.amberColor
          }
          Text {
            text: Model.formatRate(root.txRate)
            font.pixelSize: 9
            font.bold: true
            color: root.amberColor
          }
        }
      }
    }
  }
}
