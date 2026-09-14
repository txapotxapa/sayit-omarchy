import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Say It player: bar icon + popover modelled on the macOS app
// (github.com/callebtc/sayit): waveform with seek, transport controls and
// word-by-word highlighted text.
//
// sayitd (sayitd.py in github.com/txapotxapa/sayit-omarchy) rewrites $XDG_RUNTIME_DIR/sayit-state.json on
// every state change; the FileView watches it, so nothing polls. Position is
// published only on changes and extrapolated from the snapshot time while
// audio flows. Word timing is estimated inside each synthesized sentence from
// word length and punctuation; sentence boundaries themselves are exact.
BarWidget {
  id: root
  moduleName: "sayit.player"

  readonly property string runtimeDir: {
    var v = Quickshell.env("XDG_RUNTIME_DIR")
    return v && v !== "" ? v : "/run/user/1000"
  }
  readonly property string statePath: runtimeDir + "/sayit-state.json"
  readonly property string cli: Quickshell.env("HOME") + "/.local/bin/sayit"

  readonly property string iconSpeak: String.fromCodePoint(0xF050A)     // text-to-speech
  readonly property string iconVolume: String.fromCodePoint(0xF057E)
  readonly property string iconMute: String.fromCodePoint(0xF075F)
  readonly property string iconPause: String.fromCodePoint(0xF03E4)
  readonly property string iconPlay: String.fromCodePoint(0xF040A)
  readonly property string iconBack: String.fromCodePoint(0xF0D2A)      // rewind-10
  readonly property string iconForward: String.fromCodePoint(0xF0D71)   // fast-forward-10
  readonly property string iconCopy: String.fromCodePoint(0xF018F)
  readonly property string iconClose: String.fromCodePoint(0xF0156)
  readonly property string iconVoice: String.fromCodePoint(0xF05CB)     // account-voice
  readonly property string iconChevron: String.fromCodePoint(0xF0140)

  readonly property var speeds: [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
  readonly property var voiceGroups: [
    { name: "American", voices: ["af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova",
                                 "am_michael", "am_fenrir", "am_puck", "am_adam", "am_echo", "am_eric", "am_liam", "am_onyx"] },
    { name: "British", voices: ["bf_emma", "bf_isabella", "bf_alice", "bf_lily", "bm_george", "bm_fable", "bm_lewis", "bm_daniel"] },
    { name: "Spanish", voices: ["ef_dora", "em_alex", "em_santa"] }
  ]

  property var snap: ({ state: "idle" })
  property var lastSnap: null            // last utterance, shown while idle
  property real now: Date.now() / 1000
  property bool popupOpen: false
  property bool autoOpened: false
  property bool showVoices: false
  property bool showVolume: false
  property int lastJobId: -1

  readonly property bool busy: (snap.state || "idle") !== "idle"
  readonly property var view: busy ? snap : (lastSnap || snap)
  readonly property bool paused: snap.state === "paused"
  readonly property bool buffering: snap.state === "speaking" && snap.flowing !== true
  readonly property string statusText: !busy ? (lastSnap ? "Finished" : "Idle")
    : (paused ? "Paused" : (buffering ? "Buffering" : "Playing"))
  readonly property real total: view.total || 0
  readonly property real duration: busy
    ? (snap.complete ? total : Math.max(total, snap.estimate || 0))
    : total
  readonly property real position: {
    if (!busy) return lastSnap ? total : 0
    var p = snap.position || 0
    if (snap.flowing && snap.t) p += Math.max(0, now - snap.t)
    return Math.min(p, total)
  }
  readonly property real speed: snap.speed || 1
  readonly property real volume: snap.volume === undefined ? 1 : snap.volume
  readonly property string currentVoice: snap.voice || "af_heart"

  // ---- words and timing -------------------------------------------------
  // [{text, offset, start, end}] across all sentences; start/end null until
  // that sentence is synthesized.
  readonly property var words: {
    var out = []
    var chunks = view.chunks || []
    var offset = 0
    for (var c = 0; c < chunks.length; c++) {
      var parts = String(chunks[c].text).split(/\s+/).filter(function(w) { return w.length > 0 })
      var weights = parts.map(function(w) {
        var weight = w.length + 1
        if (/[,;:]$/.test(w)) weight += 4
        if (/[.!?…]$/.test(w)) weight += 7
        return weight
      })
      var sum = weights.reduce(function(a, b) { return a + b }, 0) || 1
      var timed = chunks[c].start !== undefined && chunks[c].start !== null
      var t = timed ? chunks[c].start : 0
      for (var i = 0; i < parts.length; i++) {
        var d = timed ? chunks[c].dur * weights[i] / sum : 0
        out.push({ text: parts[i], offset: offset, start: timed ? t : null, end: timed ? t + d : null })
        t += d
        offset += parts[i].length + 1
      }
    }
    return out
  }
  readonly property int currentWord: {
    if (!busy) return words.length
    var p = position
    var last = -1
    for (var i = 0; i < words.length; i++) {
      if (words[i].start === null) break
      last = i
      if (p < words[i].end) return i
    }
    return last
  }

  function hex(c) { return Qt.rgba(c.r, c.g, c.b, 1).toString() }
  function mix(fg, bg, amount) { return hex(Qt.tint(bg, Qt.rgba(fg.r, fg.g, fg.b, amount))) }
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

  readonly property color cardBg: Color.popups.background
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string readColor: hex(fg)
  readonly property string todoColor: mix(fg, cardBg, 0.42)
  readonly property string wordColor: hex(Color.accent)
  readonly property string wordBg: mix(Color.accent, cardBg, 0.22)

  readonly property string html: {
    var read = [], cur = "", todo = []
    for (var i = 0; i < words.length; i++) {
      if (i < currentWord) read.push(esc(words[i].text))
      else if (i === currentWord) cur = esc(words[i].text)
      else todo.push(esc(words[i].text))
    }
    var out = "<span style=\"color:" + readColor + "\">" + read.join(" ") + "</span>"
    if (cur !== "")
      out += (read.length ? " " : "") + "<span style=\"color:" + wordColor + "; background-color:" + wordBg + "\">&nbsp;" + cur + "&nbsp;</span>"
    if (todo.length)
      out += " <span style=\"color:" + todoColor + "\">" + todo.join(" ") + "</span>"
    return out
  }

  // ---- actions ------------------------------------------------------------
  function close() { popupOpen = false; autoOpened = false }

  function send(args) {
    if (root.bar) root.bar.run(Util.shellQuote(root.cli) + " " + args)
  }

  function clock(seconds) {
    var s = Math.max(0, Math.round(seconds))
    var m = Math.floor(s / 60)
    return (m < 10 ? "0" : "") + m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  function speedLabel(v) { return (Math.round(v * 100) / 100) + "×" }

  function stepSpeed(dir) {
    var i = 0
    for (var k = 0; k < speeds.length; k++) if (Math.abs(speeds[k] - speed) < 0.01) i = k
    var next = speeds[(i + dir + speeds.length) % speeds.length]
    send("speed " + next)
  }

  function onThisMonitor() {
    var win = root.QsWindow.window
    var screen = win ? win.screen : null
    var focused = Hyprland.focusedMonitor
    return !screen || !focused || screen.name === focused.name
  }

  function parse(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }  // caught mid-rewrite
    if (!data || !data.state) return
    if (data.state !== "idle" && data.id !== undefined) {
      if (data.id !== lastJobId) {
        lastJobId = data.id
        var manual = data.source === "selection" || data.source === "clipboard" || data.source === "replay"
        if (manual && !popupOpen && onThisMonitor()) { popupOpen = true; autoOpened = true }
      }
      lastSnap = data
    }
    snap = data
    now = Date.now() / 1000
  }

  onBusyChanged: if (!busy && autoOpened) autoCloseTimer.restart()

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.snap = { state: "idle" }
  }

  Timer {
    interval: 100
    repeat: true
    running: root.busy && root.snap.flowing === true
    onTriggered: root.now = Date.now() / 1000
  }

  Timer {
    id: autoCloseTimer
    interval: 1800
    onTriggered: if (!root.busy && root.autoOpened) root.close()
  }

  // ---- bar icon -----------------------------------------------------------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.paused ? root.iconPause : root.iconSpeak
    active: root.busy && !root.paused
    useActiveColor: false
    dimmed: !root.busy
    tooltipText: root.busy ? "Say It · " + root.statusText.toLowerCase() : "Say It"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.send(root.busy ? "toggle" : "replay")
      else { root.popupOpen = !root.popupOpen; root.autoOpened = false }
    }
    onWheelMoved: function(delta) { if (root.busy) root.send(delta > 0 ? "seek -5" : "seek 5") }
  }

  // Progress line under the icon while speaking.
  Rectangle {
    visible: root.busy && !root.vertical
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(3)
    anchors.horizontalCenter: parent.horizontalCenter
    width: Style.space(16)
    height: Math.max(1, Style.space(2))
    radius: height / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.2)

    Rectangle {
      height: parent.height
      radius: parent.radius
      width: root.duration > 0 ? parent.width * Math.min(1, root.position / root.duration) : 0
      color: Color.accent
    }
  }

  // ---- popover ------------------------------------------------------------
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Header
      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: "Say It"
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: root.statusText
          color: Qt.darker(root.fg, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: root.fg; width: parent.width }

      // Waveform + times
      Column {
        width: parent.width
        spacing: Style.space(4)

        Item {
          id: wave
          width: parent.width
          height: Style.space(44)

          readonly property int barCount: Math.max(20, Math.floor(width / Style.space(5)))
          readonly property real peak: {
            var env = root.view.env || []
            var m = 0.05
            for (var i = 0; i < env.length; i++) if (env[i] > m) m = env[i]
            return m
          }

          Row {
            anchors.fill: parent
            spacing: 0

            Repeater {
              model: wave.barCount

              Item {
                required property int index
                width: wave.width / wave.barCount
                height: wave.height

                readonly property real at: (index + 0.5) / wave.barCount * root.duration
                readonly property var env: root.view.env || []
                readonly property int envIndex: Math.floor(at * 10)
                readonly property bool known: envIndex < env.length && root.duration > 0
                readonly property real level: known ? Math.sqrt(env[envIndex] / wave.peak) : 0.1
                readonly property bool played: at <= root.position

                Rectangle {
                  anchors.centerIn: parent
                  width: Math.max(2, parent.width * 0.55)
                  height: Math.max(2, wave.height * Math.min(1, parent.level))
                  radius: width / 2
                  color: parent.played ? Color.accent : root.fg
                  opacity: parent.played ? 1 : (parent.known ? 0.35 : 0.15)
                }
              }
            }
          }

          Rectangle {
            visible: root.busy && root.duration > 0
            x: Math.min(wave.width - width, wave.width * root.position / root.duration)
            width: Math.max(2, Style.space(2))
            height: wave.height
            radius: width / 2
            color: Color.accent
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.busy && root.duration > 0
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: function(mouse) {
              root.send("seek --to " + (mouse.x / wave.width * root.duration).toFixed(2))
            }
          }
        }

        Item {
          width: parent.width
          height: elapsed.implicitHeight

          Text {
            id: elapsed
            textFormat: Text.PlainText
            text: root.clock(root.position)
            color: Qt.darker(root.fg, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            visible: (root.snap.queued || 0) > 0
            text: root.snap.queued + " more queued"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.clock(root.duration)
            color: Qt.darker(root.fg, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Transport
      Item {
        width: parent.width
        height: playButton.height

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Button {
            iconText: root.volume <= 0.01 ? root.iconMute : root.iconVolume
            tooltipText: "Volume " + Math.round(root.volume * 100) + "%"
            foreground: root.fg
            selected: root.showVolume
            onClicked: root.showVolume = !root.showVolume
          }

          Button {
            text: root.speedLabel(root.speed)
            tooltipText: "Speed · click to change, scroll to adjust"
            foreground: root.fg
            onClicked: root.stepSpeed(1)
            onRightClicked: root.stepSpeed(-1)

            WheelHandler {
              onWheel: function(event) { root.stepSpeed(event.angleDelta.y > 0 ? 1 : -1) }
            }
          }
        }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(10)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.iconBack
            tooltipText: "Back 10 seconds"
            foreground: root.fg
            enabled: root.busy
            opacity: enabled ? 1 : 0.4
            onClicked: root.send("seek -10")
          }

          Rectangle {
            id: playButton
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(44)
            height: width
            radius: width / 2
            color: Color.accent
            scale: playArea.pressed ? 0.94 : (playArea.containsMouse ? 1.05 : 1)
            Behavior on scale { NumberAnimation { duration: 90 } }

            Text {
              anchors.centerIn: parent
              anchors.horizontalCenterOffset: root.busy && !root.paused ? 0 : Style.space(1)
              textFormat: Text.PlainText
              text: root.busy && !root.paused ? root.iconPause : root.iconPlay
              color: root.cardBg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }

            MouseArea {
              id: playArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.send(root.busy ? "toggle" : "replay")
            }
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.iconForward
            tooltipText: "Forward 10 seconds"
            foreground: root.fg
            enabled: root.busy
            opacity: enabled ? 1 : 0.4
            onClicked: root.send("seek 10")
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Button {
            iconText: root.iconCopy
            tooltipText: "Copy text"
            foreground: root.fg
            enabled: (root.view.text || "") !== ""
            opacity: enabled ? 1 : 0.4
            onClicked: Quickshell.execDetached(["wl-copy", "--", root.view.text])
          }

          Button {
            iconText: root.iconClose
            tooltipText: root.busy ? "Stop" : "Close"
            foreground: root.fg
            onClicked: {
              if (root.busy) root.send("stop")
              root.close()
            }
          }
        }
      }

      PanelSlider {
        visible: root.showVolume
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: 1.5
        step: 0.05
        value: root.volume
        onReleased: function(v) { root.send("volume " + v.toFixed(2)) }
      }

      // Spoken text, highlighted word by word
      Item {
        width: parent.width
        height: Style.space(150)
        visible: root.words.length > 0

        Flickable {
          id: flick
          anchors.fill: parent
          clip: true
          contentWidth: width
          contentHeight: body.contentHeight + Style.space(24)
          boundsBehavior: Flickable.StopAtBounds

          Behavior on contentY {
            enabled: !flick.moving
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
          }

          TextEdit {
            id: body
            width: flick.width
            readOnly: true
            selectByMouse: false
            activeFocusOnPress: false
            textFormat: TextEdit.RichText
            wrapMode: TextEdit.Wrap
            text: root.html
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title

            onTextChanged: Qt.callLater(root.followWord)
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(28)
          gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(root.cardBg.r, root.cardBg.g, root.cardBg.b, 0) }
            GradientStop { position: 1; color: root.cardBg }
          }
        }
      }

      PanelSeparator { foreground: root.fg; width: parent.width }

      // Footer: voice picker + service
      Item {
        width: parent.width
        height: voiceButton.implicitHeight

        Button {
          id: voiceButton
          anchors.left: parent.left
          iconText: root.iconVoice
          text: "Kokoro · " + root.currentVoice + " " + root.iconChevron
          foreground: root.fg
          selected: root.showVoices
          onClicked: root.showVoices = !root.showVoices
        }

        Button {
          anchors.right: parent.right
          text: "Quit"
          tooltipText: "Stop the sayit service (it restarts on the next hotkey)"
          foreground: root.fg
          onClicked: {
            root.close()
            root.bar.run("systemctl --user stop sayit.service")
          }
        }
      }

      Column {
        visible: root.showVoices
        width: parent.width
        spacing: Style.space(8)

        Repeater {
          model: root.voiceGroups

          Column {
            required property var modelData
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: modelData.name
              color: Qt.darker(root.fg, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Flow {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: modelData.voices

                Button {
                  required property string modelData
                  text: modelData.substring(3) + (modelData.charAt(1) === "f" ? " ♀" : " ♂")
                  tooltipText: modelData
                  foreground: root.fg
                  selected: modelData === root.currentVoice
                  onClicked: root.send("voice " + modelData)
                }
              }
            }
          }
        }
      }
    }
  }

  // Keep the spoken word about a third of the way down the text box.
  function followWord() {
    if (!popupOpen || flick.moving || currentWord < 0 || currentWord >= words.length) return
    var rect = body.positionToRectangle(words[currentWord].offset)
    var target = rect.y - flick.height * 0.3
    flick.contentY = Math.max(0, Math.min(target, flick.contentHeight - flick.height))
  }
}
