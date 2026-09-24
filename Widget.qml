import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Brown-02 (192.168.1.24) and Brown-01 (192.168.1.169), the two thin-client NAS boxes.
BarWidget {
  id: root
  moduleName: "tb.zima"

  readonly property string script:
    Qt.resolvedUrl("status.py").toString().replace(/^file:\/\//, "")
  readonly property string host: String(setting("host", "192.168.1.24"))
  readonly property string sshUser: String(setting("sshUser", "tylerbrown"))
  readonly property int pollSec: clampedInteger("pollSec", 15, 5, 300)

  property bool popupOpen: false
  property bool sawStatus: false
  property var clients: []
  property string checkedAt: ""
  property string errorText: ""
  property string armedId: ""
  property string restartingId: ""
  property string restartHost: ""
  property string restartNote: ""

  readonly property bool opened: popupOpen
  readonly property var shownClients: clients.length ? clients : [
    { name: "Brown-02", status: "offline", detail: "checking" },
    { name: "Brown-01", status: "offline", detail: "checking" }
  ]
  readonly property bool anyFault: {
    for (var i = 0; i < shownClients.length; i++) {
      if (shownClients[i] && shownClients[i].status === "fault") return true
    }
    return false
  }

  function clampedInteger(key, fallback, minimum, maximum) {
    var value = Math.round(Number(setting(key, fallback)))
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function shortName(name) {
    var text = String(name || "")
    if (text.indexOf("Brown-02") >= 0) return "Brown-02"
    if (text.indexOf("Brown-01") >= 0) return "Brown-01"
    return text
  }

  function clientById(id) {
    for (var i = 0; i < clients.length; i++) {
      if (clients[i] && clients[i].id === id) return clients[i]
    }
    return ({ id: id, name: id, status: "offline", detail: sawStatus ? "no answer" : "checking" })
  }

  function toneFor(status) {
    if (status === "online") return "#3cba7a"
    if (status === "fault") return "#e24b4b"
    return "#f0d020"
  }

  function wordFor(status) {
    if (status === "online") return "ONLINE"
    if (status === "fault") return "FAULT"
    return "OFFLINE"
  }

  function statusSummary() {
    var online = 0
    var offline = 0
    var fault = 0
    for (var i = 0; i < shownClients.length; i++) {
      var status = shownClients[i] ? shownClients[i].status : "offline"
      if (status === "online") online += 1
      else if (status === "fault") fault += 1
      else offline += 1
    }
    var parts = []
    if (online) parts.push(online + " online")
    if (fault) parts.push(fault + " fault")
    if (offline) parts.push(offline + " offline")
    if (!parts.length) parts.push("checking")
    return parts.join(" · ")
  }

  function metricText(client, value) {
    if (!client || client.status !== "online") return "—"
    if (client.metrics === "unavailable") return "unavailable"
    return value || "—"
  }

  function latencyText(client) {
    if (!client || client.latency_ms === undefined || client.latency_ms === null)
      return client && client.status === "online" ? "—" : "—"
    return client.latency_ms + " ms"
  }

  function powerText(client) {
    if (!client || client.power_w === undefined || client.power_w === null) return "—"
    return client.power_w + " W"
  }

  function cpuText(client) {
    if (!client || client.cpu_pct === undefined || client.cpu_pct === null) return "—"
    return client.cpu_pct + "%"
  }

  function cpuColor(client) {
    if (!client || client.status !== "online") return Color.muted
    var amount = Number(client.cpu_pct)
    if (isFinite(amount) && amount >= 90) return "#e24b4b"
    return Color.popups.text
  }

  function memoryText(client) {
    if (!client || client.status !== "online") return "—"
    var memory = client.memory
    if (!memory || !memory.text) return client.metrics === "unavailable" ? "unavailable" : "—"
    return memory.text
  }

  function memoryColor(client) {
    if (!client || client.status !== "online") return Color.muted
    if (!client.memory || !client.memory.fault) return Color.popups.text
    return "#e24b4b"
  }

  function storageRows(client) {
    if (!client) return []
    return client.storage || []
  }

  function storageLine(client) {
    var rows = storageRows(client)
    if (!rows.length) return ""
    var lines = []
    for (var i = 0; i < rows.length; i++)
      lines.push(rows[i].name + " · " + rows[i].text)
    return lines.join("\n")
  }

  function showStorage(client) {
    if (!client) return false
    if (client.status === "offline" && !storageRows(client).length) return false
    return storageRows(client).length > 0 || client.status === "online"
  }

  function storageColor(client) {
    if (!client || client.status !== "online") return Color.muted
    var rows = storageRows(client)
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].fault) return "#e24b4b"
    }
    return Color.popups.text
  }

  function connectionDetail(client) {
    if (!client) return ""
    var detail = String(client.detail || "").trim()
    if (!detail) return ""
    var lower = detail.toLowerCase()
    if (lower === "online" || lower === wordFor(client.status).toLowerCase()) return ""
    if (lower === "checking" && !sawStatus) return detail
    return detail
  }

  function armRestart(client) {
    if (!client || client.status !== "online" || restartingId !== "") return
    if (armedId !== client.id) {
      armedId = client.id
      restartNote = ""
      return
    }
    armedId = ""
    restartingId = client.id
    restartHost = client.address || ""
    restartNote = "Rebooting " + shortName(client.name || client.address) + "."
    restartProc.running = true
  }

  function tooltipText() {
    var parts = []
    for (var i = 0; i < shownClients.length; i++) {
      parts.push(shortName(shownClients[i].name) + " " + wordFor(shownClients[i].status).toLowerCase())
    }
    return parts.join("  ·  ")
  }

  function parsePayload(text) {
    var line = String(text || "").replace(/\s+$/, "")
    var start = line.lastIndexOf("\n")
    if (start >= 0) line = line.slice(start + 1)
    try {
      return JSON.parse(line)
    } catch (error) {
      return null
    }
  }

  function poll() {
    if (!statusProc.running) statusProc.running = true
  }

  function open() { popupOpen = true }
  function close() {
    popupOpen = false
    armedId = ""
  }
  function togglePopup() { popupOpen = !popupOpen }

  implicitWidth: vertical ? barSize : chip.implicitWidth + Style.space(8)
  implicitHeight: barSize

  Timer {
    interval: root.pollSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Process {
    id: statusProc
    command: ["python3", root.script, root.host, root.sshUser]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = root.parsePayload(text)
        root.sawStatus = true
        if (!payload || !payload.clients) {
          root.errorText = "bad status"
          root.clients = []
          return
        }
        root.clients = payload.clients
        root.errorText = ""
        root.checkedAt = Qt.formatDateTime(new Date(), "h:mm AP")
      }
    }
  }

  Process {
    id: restartProc
    command: ["python3", root.script, "restart", root.restartHost, root.sshUser]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = root.parsePayload(text)
        var failed = !payload || payload.ok !== true
        root.restartNote = failed
          ? ("Restart failed. " + ((payload && payload.error) || "no answer"))
          : ("Reboot started on " + root.restartHost + ".")
        root.restartingId = ""
        if (!failed) root.poll()
      }
    }
  }

  Rectangle {
    id: chip
    anchors.centerIn: parent
    implicitWidth: chipRow.implicitWidth + Style.space(16)
    implicitHeight: Math.min(root.barSize - Style.space(6), Style.space(28))
    radius: height / 2
    color: Color.notifications.background
    border.width: 1
    border.color: root.anyFault ? "#e24b4b" : Color.popups.border

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      Repeater {
        model: root.shownClients
        delegate: Row {
          required property var modelData
          spacing: Style.space(4)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: root.toneFor(modelData.status)
          }
          Text {
            visible: !root.vertical
            anchors.verticalCenter: parent.verticalCenter
            text: root.shortName(modelData.name || "")
            color: Color.notifications.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: root.togglePopup()
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(520))
    contentHeight: popup.fittedContentHeight(bodyCol.implicitHeight, Style.space(560))

    Flickable {
      id: bodyScroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: bodyCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: bodyCol
        width: bodyScroll.width
        spacing: Style.space(10)

        Column {
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            height: Math.max(titleText.implicitHeight, whenText.implicitHeight)

            Text {
              id: titleText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Zima Stats"
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              renderType: Text.NativeRendering
            }

            Text {
              id: whenText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.checkedAt === "" ? "—" : root.checkedAt
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          Text {
            width: parent.width
            text: root.statusSummary()
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        Repeater {
          model: root.shownClients
          delegate: Rectangle {
            required property var modelData
            width: bodyCol.width
            implicitHeight: cardCol.implicitHeight + Style.space(20)
            radius: Style.space(8)
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
            border.width: 1
            border.color: root.toneFor(modelData.status)

            Column {
              id: cardCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Row {
                spacing: Style.space(8)
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: root.toneFor(modelData.status)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.shortName(modelData.name || "") + " · " + root.wordFor(modelData.status)
                  color: Color.popups.text
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  renderType: Text.NativeRendering
                }
              }

              Grid {
                width: parent.width
                columns: 2
                columnSpacing: Style.space(6)
                rowSpacing: Style.space(6)

                Repeater {
                  model: [
                    {
                      label: "Latency",
                      value: root.latencyText(modelData),
                      color: modelData.status === "online" ? Color.popups.text : Color.muted
                    },
                    {
                      label: "Power",
                      value: root.metricText(modelData, root.powerText(modelData)),
                      color: modelData.status === "online" ? Color.popups.text : Color.muted
                    },
                    {
                      label: "CPU",
                      value: root.metricText(modelData, root.cpuText(modelData)),
                      color: root.cpuColor(modelData)
                    },
                    {
                      label: "Memory",
                      value: root.memoryText(modelData),
                      color: root.memoryColor(modelData)
                    }
                  ]
                  delegate: Rectangle {
                    required property var modelData
                    width: (cardCol.width - Style.space(6)) / 2
                    height: Style.space(60)
                    radius: Style.space(6)
                    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
                    border.width: 1
                    border.color: Color.popups.border

                    Column {
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: modelData.label
                        color: Color.muted
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        font.capitalization: Font.AllUppercase
                        elide: Text.ElideRight
                        renderType: Text.NativeRendering
                      }

                      Text {
                        width: parent.width
                        text: modelData.value
                        color: modelData.color
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                        renderType: Text.NativeRendering
                      }
                    }
                  }
                }
              }

              Column {
                visible: root.showStorage(modelData)
                width: parent.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: "Storage"
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.capitalization: Font.AllUppercase
                  renderType: Text.NativeRendering
                }

                Text {
                  width: parent.width
                  text: root.storageLine(modelData) || (modelData.status === "online" ? "—" : "")
                  color: root.storageColor(modelData)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  renderType: Text.NativeRendering
                }
              }

              Text {
                visible: root.connectionDetail(modelData) !== ""
                width: parent.width
                text: root.connectionDetail(modelData)
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                renderType: Text.NativeRendering
              }

              Text {
                visible: root.armedId === modelData.id
                width: parent.width
                text: "Reboots this NAS."
                wrapMode: Text.WordWrap
                color: Color.urgent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                renderType: Text.NativeRendering
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: root.restartingId === modelData.id ? "Restarting" : (root.armedId === modelData.id ? "Restart now" : "Restart")
                  enabled: modelData.status === "online" && root.restartingId === ""
                  bordered: true
                  foreground: root.armedId === modelData.id ? Color.urgent : Color.popups.text
                  onClicked: root.armRestart(modelData)
                }
                Button {
                  visible: root.armedId === modelData.id
                  text: "Cancel"
                  bordered: true
                  foreground: Color.popups.text
                  onClicked: root.armedId = ""
                }
              }
            }
          }
        }

        Text {
          visible: root.restartNote !== ""
          width: parent.width
          text: root.restartNote
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
        }

        Button {
          text: statusProc.running ? "Refreshing" : "Refresh"
          enabled: !statusProc.running
          bordered: true
          foreground: Color.popups.text
          onClicked: root.poll()
        }

        Item { width: 1; height: Style.space(8) }
      }
    }
  }
}
