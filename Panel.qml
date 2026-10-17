import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "dev.zenmi.netledger"
  ipcTarget: "dev.zenmi.netledger"
  manageIpc: false

  property string dbPath: "/var/lib/netledger/ledger.db"
  property string activePreset: "24H"
  property bool customRangeOpen: false
  property string customFromInput: "-36h"
  property string customToInput: ""
  property string activeFilter: ""
  property string sortBy: "total" // "total" | "rx" | "tx"
  property var isolatedBucket: null

  // Telemetry Aggregates
  property var processGroups: []
  property var histogramBuckets: []
  property real totalRxBytes: 0
  property real totalTxBytes: 0
  property real totalBytes: 0
  property string peakWindowText: "No traffic recorded"

  // Expanded group tracker { [rootGroup]: bool }
  property var expandedGroups: ({})

  readonly property color cyanColor: "#22d3ee"
  readonly property color amberColor: "#f59e0b"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: bar ? bar.background : Color.background
  readonly property color dimColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color outlineColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color surfaceColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color surfaceHoverColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)

  width: 540
  implicitHeight: 640

  function refresh() {
    if (!root.opened) return

    var rangeInfo
    if (root.isolatedBucket !== null) {
      rangeInfo = {
        startTs: root.isolatedBucket.ts,
        endTs: root.isolatedBucket.ts + (root.activePreset === "30D" ? 3600 : 300),
        isLive: false,
        tierTable: root.activePreset === "30D" ? "rollup_1hour" : "rollup_5min"
      }
    } else {
      rangeInfo = Model.resolveTimeRange(root.activePreset, root.customFromInput, root.customToInput)
    }

    // 1. Fetch Process Lineage Tree
    var sqlTree = Model.buildTreeQuery(root.dbPath, rangeInfo, root.activeFilter, root.sortBy)
    if (!treeQueryProc.running) {
      treeQueryProc.command = ["sqlite3", "--json", root.dbPath, sqlTree]
      treeQueryProc.running = true
    }

    // 2. Fetch Histogram Buckets (if not isolating single bucket)
    if (root.isolatedBucket === null && !histQueryProc.running) {
      var sqlHist = Model.buildHistogramQuery(root.dbPath, rangeInfo)
      histQueryProc.command = ["sqlite3", "--json", root.dbPath, sqlHist]
      histQueryProc.running = true
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
    }
  }

  // Periodic poll timer while open
  Timer {
    id: refreshTimer
    interval: root.activePreset === "LIVE" ? 2000 : 6000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: treeQueryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var trimmed = String(text || "").trim()
          var rows = trimmed !== "" ? JSON.parse(trimmed) : []
          var res = Model.processRowsToTree(rows)
          root.processGroups = res.groups
          root.totalRxBytes = res.windowRx
          root.totalTxBytes = res.windowTx
          root.totalBytes = res.windowTotal
        } catch (e) {
          root.processGroups = []
        }
      }
    }
  }

  Process {
    id: histQueryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var trimmed = String(text || "").trim()
          var rows = trimmed !== "" ? JSON.parse(trimmed) : []
          var maxTotal = 1
          var peakBucket = null
          var buckets = []

          // Subsample or bucketize to ~32 bars max for sparkline display
          var step = Math.max(1, Math.floor(rows.length / 32))
          for (var i = 0; i < rows.length; i += step) {
            var r = rows[i]
            var rx = parseInt(r.rx || 0, 10)
            var tx = parseInt(r.tx || 0, 10)
            var tot = rx + tx
            var ts = parseInt(r.bucket_ts || 0, 10)

            if (tot > maxTotal) {
              maxTotal = tot
              peakBucket = { ts: ts, total: tot }
            }

            buckets.push({
              ts: ts,
              rx: rx,
              tx: tx,
              total: tot
            })
          }

          for (var j = 0; j < buckets.length; j++) {
            buckets[j].relHeight = Math.max(0.08, buckets[j].total / maxTotal)
          }

          root.histogramBuckets = buckets

          if (peakBucket && peakBucket.total > 0) {
            var dateObj = new Date(peakBucket.ts * 1000)
            var dateStr = dateObj.toLocaleDateString(undefined, { day: "numeric", month: "short" })
            root.peakWindowText = "Peak: " + dateStr + " (" + Model.formatBytes(peakBucket.total) + ")"
          } else {
            root.peakWindowText = "Minimal traffic in window"
          }
        } catch (e) {
          root.histogramBuckets = []
        }
      }
    }
  }

  // Visual Root Container
  Item {
    anchors.fill: parent

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 14
      spacing: 12

      // =========================================================================
      // ZONE 1: HEADER & RANGE PRESETS
      // =========================================================================
      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: "NETLEDGER"
          font.bold: true
          font.pixelSize: 13
          font.letterSpacing: 1.2
          color: root.foreground
        }

        Item { Layout.fillWidth: true }

        // Presets: [● LIVE] [24H] [2D] [7D] [30D] [📅 Range]
        RowLayout {
          spacing: 4

          Repeater {
            model: ["LIVE", "24H", "2D", "7D", "30D"]

            Rectangle {
              id: presetBtn
              required property string modelData
              implicitWidth: labelText.implicitWidth + 14
              implicitHeight: 24
              radius: 4
              color: root.activePreset === modelData && root.isolatedBucket === null
                ? root.surfaceHoverColor
                : (presetMa.containsMouse ? root.surfaceColor : "transparent")
              border.color: root.activePreset === modelData && root.isolatedBucket === null
                ? root.cyanColor
                : root.outlineColor

              RowLayout {
                anchors.centerIn: parent
                spacing: 4

                Rectangle {
                  visible: presetBtn.modelData === "LIVE"
                  width: 6
                  height: 6
                  radius: 3
                  color: root.cyanColor
                }

                Text {
                  id: labelText
                  text: presetBtn.modelData
                  font.pixelSize: 10
                  font.bold: root.activePreset === presetBtn.modelData
                  color: root.activePreset === presetBtn.modelData ? root.foreground : root.dimColor
                }
              }

              MouseArea {
                id: presetMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.activePreset = presetBtn.modelData
                  root.isolatedBucket = null
                  root.customRangeOpen = false
                  root.refresh()
                }
              }
            }
          }

          // [📅 Range] toggle button
          Rectangle {
            implicitWidth: rangeLabel.implicitWidth + 14
            implicitHeight: 24
            radius: 4
            color: root.customRangeOpen ? root.surfaceHoverColor : (rangeMa.containsMouse ? root.surfaceColor : "transparent")
            border.color: root.customRangeOpen ? root.amberColor : root.outlineColor

            RowLayout {
              anchors.centerIn: parent
              spacing: 3
              Text { text: "📅"; font.pixelSize: 10 }
              Text {
                id: rangeLabel
                text: "Range"
                font.pixelSize: 10
                font.bold: root.customRangeOpen
                color: root.customRangeOpen ? root.foreground : root.dimColor
              }
            }

            MouseArea {
              id: rangeMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.customRangeOpen = !root.customRangeOpen
              }
            }
          }
        }
      }

      // Collapsible Custom Range Input Bar
      Rectangle {
        visible: root.customRangeOpen
        Layout.fillWidth: true
        implicitHeight: 38
        radius: 6
        color: root.surfaceColor
        border.color: root.outlineColor

        RowLayout {
          anchors.fill: parent
          anchors.margins: 6
          spacing: 8

          Text {
            text: "From:"
            font.pixelSize: 10
            color: root.dimColor
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 24
            radius: 4
            color: root.background
            border.color: root.outlineColor

            TextInput {
              id: fromInput
              anchors.fill: parent
              anchors.margins: 4
              text: root.customFromInput
              font.pixelSize: 10
              color: root.foreground
              selectByMouse: true
              onTextChanged: root.customFromInput = text
            }
          }

          Text {
            text: "To:"
            font.pixelSize: 10
            color: root.dimColor
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 24
            radius: 4
            color: root.background
            border.color: root.outlineColor

            TextInput {
              id: toInput
              anchors.fill: parent
              anchors.margins: 4
              text: root.customToInput
              font.pixelSize: 10
              color: root.foreground
              selectByMouse: true
              onTextChanged: root.customToInput = text
            }
          }

          Rectangle {
            implicitWidth: 50
            implicitHeight: 24
            radius: 4
            color: applyMa.containsMouse ? root.amberColor : root.surfaceHoverColor
            border.color: root.amberColor

            Text {
              anchors.centerIn: parent
              text: "Apply"
              font.pixelSize: 10
              font.bold: true
              color: applyMa.containsMouse ? "#000000" : root.foreground
            }

            MouseArea {
              id: applyMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.activePreset = "CUSTOM"
                root.isolatedBucket = null
                root.refresh()
              }
            }
          }
        }
      }

      // =========================================================================
      // ZONE 2: TELEMETRY TOTALS & INTERACTIVE HISTOGRAM
      // =========================================================================
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 82
        radius: 6
        color: root.surfaceColor
        border.color: root.outlineColor

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 8
          spacing: 6

          // Byte Totals Header
          RowLayout {
            Layout.fillWidth: true
            spacing: 12

            RowLayout {
              spacing: 4
              Text { text: "TOTAL IN (↓):"; font.pixelSize: 11; font.bold: true; color: root.dimColor }
              Text { text: Model.formatBytes(root.totalRxBytes); font.pixelSize: 11; font.bold: true; color: root.cyanColor }
            }

            RowLayout {
              spacing: 4
              Text { text: "TOTAL OUT (↑):"; font.pixelSize: 11; font.bold: true; color: root.dimColor }
              Text { text: Model.formatBytes(root.totalTxBytes); font.pixelSize: 11; font.bold: true; color: root.amberColor }
            }

            Item { Layout.fillWidth: true }

            // Peak window indicator / Reset button
            RowLayout {
              spacing: 6

              Text {
                text: root.isolatedBucket !== null ? "ISOLATED BUCKET" : root.peakWindowText
                font.pixelSize: 10
                color: root.dimColor
              }

              Rectangle {
                visible: root.isolatedBucket !== null
                implicitWidth: 42
                implicitHeight: 18
                radius: 3
                color: root.surfaceHoverColor
                border.color: root.outlineColor

                Text {
                  anchors.centerIn: parent
                  text: "Reset"
                  font.pixelSize: 9
                  color: root.foreground
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.isolatedBucket = null
                    root.refresh()
                  }
                }
              }
            }
          }

          // Sparkline / Time-Brush Histogram Bars
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2

            Repeater {
              model: root.histogramBuckets

              Rectangle {
                id: barItem
                required property var modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "transparent"

                Rectangle {
                  anchors.bottom: parent.bottom
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.max(3, parent.width - 1)
                  height: Math.max(3, parent.height * barItem.modelData.relHeight)
                  radius: 2
                  color: barItemMa.containsMouse
                    ? "#ffffff"
                    : (root.isolatedBucket && root.isolatedBucket.ts === barItem.modelData.ts ? root.amberColor : root.cyanColor)
                  opacity: barItemMa.containsMouse ? 1.0 : 0.8
                }

                MouseArea {
                  id: barItemMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.isolatedBucket = barItem.modelData
                    root.refresh()
                  }
                }
              }
            }
          }
        }
      }

      // =========================================================================
      // ZONE 3: SEARCH & SORT BAR
      // =========================================================================
      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        // Search Input Field
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: 28
          radius: 5
          color: root.surfaceColor
          border.color: root.outlineColor

          RowLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 6

            Text { text: "🔍"; font.pixelSize: 10; opacity: 0.7 }

            TextInput {
              id: filterInput
              Layout.fillWidth: true
              font.pixelSize: 11
              color: root.foreground
              selectByMouse: true

              Text {
                visible: filterInput.text.length === 0
                text: "Filter process, child binary, or PID..."
                font.pixelSize: 11
                color: root.dimColor
              }

              onTextChanged: {
                filterDebounce.restart()
              }
            }
          }

          Timer {
            id: filterDebounce
            interval: 250
            repeat: false
            onTriggered: {
              root.activeFilter = filterInput.text
              root.refresh()
            }
          }
        }

        // Sort Toggles: [Total ▼] [↓] [↑]
        RowLayout {
          spacing: 3

          Text {
            text: "Sort:"
            font.pixelSize: 10
            color: root.dimColor
          }

          Rectangle {
            implicitWidth: 54
            implicitHeight: 26
            radius: 4
            color: root.sortBy === "total" ? root.surfaceHoverColor : "transparent"
            border.color: root.sortBy === "total" ? root.cyanColor : root.outlineColor

            Text {
              anchors.centerIn: parent
              text: "Total ▼"
              font.pixelSize: 10
              font.bold: root.sortBy === "total"
              color: root.sortBy === "total" ? root.foreground : root.dimColor
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortBy = "total"; root.refresh() }
            }
          }

          Rectangle {
            implicitWidth: 30
            implicitHeight: 26
            radius: 4
            color: root.sortBy === "rx" ? root.surfaceHoverColor : "transparent"
            border.color: root.sortBy === "rx" ? root.cyanColor : root.outlineColor

            Text {
              anchors.centerIn: parent
              text: "↓"
              font.pixelSize: 11
              font.bold: true
              color: root.sortBy === "rx" ? root.cyanColor : root.dimColor
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortBy = "rx"; root.refresh() }
            }
          }

          Rectangle {
            implicitWidth: 30
            implicitHeight: 26
            radius: 4
            color: root.sortBy === "tx" ? root.surfaceHoverColor : "transparent"
            border.color: root.sortBy === "tx" ? root.amberColor : root.outlineColor

            Text {
              anchors.centerIn: parent
              text: "↑"
              font.pixelSize: 11
              font.bold: true
              color: root.sortBy === "tx" ? root.amberColor : root.dimColor
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortBy = "tx"; root.refresh() }
            }
          }
        }
      }

      // =========================================================================
      // ZONE 4: EXPANDABLE PROCESS LINEAGE TREE
      // =========================================================================
      ListView {
        id: processList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: 6
        model: root.processGroups

        delegate: Rectangle {
          id: groupCard
          required property var modelData
          required property int index

          width: processList.width
          implicitHeight: cardContent.implicitHeight + 14
          radius: 6
          color: groupMa.containsMouse ? root.surfaceHoverColor : root.surfaceColor
          border.color: root.outlineColor

          readonly property bool isExpanded: !!root.expandedGroups[modelData.rootGroup]

          ColumnLayout {
            id: cardContent
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            // Primary Root Group Row
            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: groupCard.isExpanded ? "▾" : "▸"
                font.pixelSize: 12
                color: root.foreground
              }

              Text {
                text: Model.categoryIcon(groupCard.modelData.category)
                font.pixelSize: 12
              }

              Text {
                text: groupCard.modelData.rootGroup
                font.bold: true
                font.pixelSize: 12
                color: root.foreground
                Layout.fillWidth: true
                elide: Text.ElideRight
              }

              // Rate / Byte totals
              RowLayout {
                spacing: 8
                Text {
                  text: "↓ " + Model.formatBytes(groupCard.modelData.rxBytes)
                  font.pixelSize: 11
                  font.bold: true
                  color: root.cyanColor
                }
                Text {
                  text: "↑ " + Model.formatBytes(groupCard.modelData.txBytes)
                  font.pixelSize: 11
                  font.bold: true
                  color: root.amberColor
                }
              }
            }

            // Dual-Segment Proportional Bar & Share Label
            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              // Progress Bar Track
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: 7
                radius: 3
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                clip: true

                // Normalized container based on relative share of top process
                Item {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: parent.width * groupCard.modelData.relativeBarShare

                  // Cyan Download segment
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * groupCard.modelData.rxProportion
                    radius: 3
                    color: root.cyanColor
                  }

                  // Amber Upload segment
                  Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * groupCard.modelData.txProportion
                    radius: 3
                    color: root.amberColor
                  }
                }
              }

              Text {
                text: groupCard.modelData.percentOfWindow.toFixed(1) + "%"
                font.pixelSize: 10
                color: root.dimColor
              }
            }

            // Expanded Children View
            ColumnLayout {
              visible: groupCard.isExpanded
              Layout.fillWidth: true
              Layout.leftMargin: 16
              spacing: 4

              Repeater {
                model: groupCard.modelData.children

                RowLayout {
                  required property var modelData
                  required property int index
                  Layout.fillWidth: true
                  spacing: 6

                  Text {
                    text: index === groupCard.modelData.children.length - 1 ? "└─" : "├─"
                    font.family: "monospace"
                    font.pixelSize: 11
                    color: root.dimColor
                  }

                  Text {
                    text: modelData.comm
                    font.bold: true
                    font.pixelSize: 11
                    color: root.foreground
                  }

                  Text {
                    text: modelData.detail !== "" && modelData.detail !== modelData.comm
                      ? "(" + modelData.detail + ")"
                      : ""
                    font.pixelSize: 10
                    color: root.dimColor
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }

                  Text {
                    text: "↓ " + Model.formatBytes(modelData.rxBytes)
                    font.pixelSize: 10
                    color: root.cyanColor
                  }

                  Text {
                    text: "↑ " + Model.formatBytes(modelData.txBytes)
                    font.pixelSize: 10
                    color: root.amberColor
                  }
                }
              }
            }
          }

          MouseArea {
            id: groupMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var map = Object.assign({}, root.expandedGroups)
              var current = !!map[groupCard.modelData.rootGroup]
              map[groupCard.modelData.rootGroup] = !current
              root.expandedGroups = map
            }
          }
        }
      }
    }
  }
}
