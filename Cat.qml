// Navbar Cat — a cat that walks along the Omarchy bar.
//
// The plugin is a `kind: "panel"` with `keepLoaded: true`, so the shell mounts
// it at startup (shell.qml:625) and it lives for the whole session. It draws a
// transparent strip over the bar on WlrLayer.Overlay — the same layer the bar's
// own drag ghost uses (Bar.qml:1167) — and is click-through everywhere except a
// small box around the cat while it is sitting still.
//
// All of the cat's decision-making lives in Brain.js, which is pure and tested.
// This file is the body: it gathers what is going on, hands a snapshot to the
// brain each tick, and moves the sprite toward whatever the brain asked for.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import qs.Commons
import "Brain.js" as Brain
import "Frames.js" as Frames

Item {
  id: root

  // Injected by the shell host (shell.qml:629-637).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.tallsam.navbar-cat"
  readonly property string assetDir: {
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (dir === "") return ""
    return (dir.indexOf("file://") === 0 ? dir : "file://" + dir) + "/assets"
  }
  readonly property string helper: {
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (dir === "") return ""
    return dir.replace(/^file:\/\//, "") + "/bin/navbar-cat-cursor"
  }

  // The shell assigns `manifest` after the component is constructed, so every
  // path derived from it is empty for the first moments of life. Nothing that
  // touches the filesystem may start before this turns true, or the sprite
  // tries to load `/cat32-fill.png` and the helper is launched as
  // `/bin/navbar-cat-cursor`.
  readonly property bool ready: assetDir !== "" && helper !== ""

  // ---------------------------------------------------------------- config

  // Settings live inline on this plugin's entry in shell.json's `plugins[]`.
  // Third-party plugins no longer receive `shell.shellConfig` (PluginShellApi
  // is scoped), and their `mutateShellConfig` only mutates `bar` — so we watch
  // shell.json ourselves and persist with `updateEntryInline`.
  property var config: ({})

  FileView {
    id: shellConfigFile
    path: (Quickshell.env("HOME") || "") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.reloadConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.config = ({})
  }

  function reloadConfig(raw) {
    var next = ({})
    try {
      var parsed = JSON.parse(String(raw || ""))
      var settings = parsed && Array.isArray(parsed.plugins) ? parsed.plugins : null
      if (settings) {
        for (var i = 0; i < settings.length; i++) {
          if (settings[i] && String(settings[i].id || "") === root.pluginId) {
            next = settings[i]
            break
          }
        }
      }
    } catch (e) {
      next = ({})
    }
    root.config = next
  }

  readonly property real speed: Number(config.speed) > 0 ? Number(config.speed) : 1.0
  readonly property bool pettable: config.pettable !== false
  readonly property bool chaseCursor: config.chaseCursor !== false
  readonly property int sleepAfter: Number(config.sleepAfter) > 0 ? Number(config.sleepAfter) : 180
  readonly property var reactions: config.reactions && typeof config.reactions === "object"
    ? config.reactions : ({})
  readonly property int catSize: Number(config.size) > 0 ? Number(config.size) : 16

  // Unknown names fall back rather than leaving the cat invisible on a typo.
  readonly property string character: {
    var wanted = String(config.character || "neko")
    return Frames.CHARACTERS.indexOf(wanted) !== -1 ? wanted : "neko"
  }

  readonly property bool pounce: config.pounce !== false

  // Sprinting and galloping are off unless the config asks  for them
  readonly property bool fastStride: config.fastStride !== false

  // Fraction of the bar to keep clear when the cat picks its own spot. Omarchy
  // centres the clock, so the middle is the one place reliably occupied.
  readonly property real avoidCenter: config.avoidCenter !== undefined
    ? Math.max(0, Math.min(0.9, Number(config.avoidCenter)))
    : 0.2
  readonly property bool rhythm: config.rhythm !== false
  readonly property int stirEvery: Number(config.stirEvery) > 0 ? Number(config.stirEvery) : 150
  readonly property int stirFor: Number(config.stirFor) > 0 ? Number(config.stirFor) : 25

  // Room for the cat to leave the bar during a pounce. The window grows inward
  // from the bar's own edge; the extra strip is fully transparent and carries
  // no input region, so it costs nothing when the cat is on the ground.
  readonly property int headroom: pounce ? Math.round(catSize * 1.5) : 0

  // ------------------------------------------------------------ bar state

  readonly property var bar: shell ? shell.bar : null
  readonly property string barPosition: bar ? String(bar.position) : "top"
  readonly property bool vertical: barPosition === "left" || barPosition === "right"
  readonly property int barSize: bar && bar.barSize ? bar.barSize : 26
  readonly property bool barHidden: bar ? bar.barHidden === true : false

  // ------------------------------------------------------------- monitors

  // "all" (default): every monitor is one long bar and the cat roams across them.
  // "focused": one cat that follows the focused output.  <name>: pinned output.
  readonly property string monitorMode: String(config.monitor || "focused")
  readonly property bool spanAll: monitorMode === "all"
  readonly property string wantedScreenName: {
    if (monitorMode !== "focused" && monitorMode !== "all") return monitorMode
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  readonly property var homeScreen: {
    var screens = Quickshell.screens
    if (!screens || screens.length === 0) return null
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === root.wantedScreenName) return screens[i]
    }
    return screens[0]
  }

  // Screens that make up the bar, in walking order.
  readonly property var barScreens: {
    if (!spanAll) return homeScreen ? [homeScreen] : []
    var list = []
    var screens = Quickshell.screens
    if (!screens) return list
    for (var i = 0; i < screens.length; i++) list.push(screens[i])
    list.sort(function (a, b) {
      return vertical ? a.y - b.y : a.x - b.x
    })
    return list
  }

  // Where each screen's segment starts on the virtual bar, plus total length.
  readonly property var screenOffsets: {
    var offsets = [], acc = 0
    for (var i = 0; i < barScreens.length; i++) {
      offsets.push(acc)
      acc += vertical ? barScreens[i].height : barScreens[i].width
    }
    return offsets
  }

  readonly property real totalLength: {
    var acc = 0
    for (var i = 0; i < barScreens.length; i++)
      acc += vertical ? barScreens[i].height : barScreens[i].width
    return acc
  }

  // Which segment the cat's centre is over.
  readonly property int catIndex: {
    var c = catPos + catSize / 2
    for (var i = barScreens.length - 1; i >= 0; i--)
      if (c >= screenOffsets[i]) return i
    return 0
  }

  // Kept under the old name so CatMenu.qml (which probably uses it) still works.
  readonly property var catScreen: barScreens.length > 0 ? barScreens[catIndex] : null

  // --------------------------------------------------------- world inputs

  property real pointerX: -1
  property real pointerY: -1
  property real lastPointerMoveAt: 0
  property real pettedAt: -1
  property var workspaceEvent: null
  property real notifyAt: -1
  property real themeChangedAt: -1

  // The shell owns the notification server, so a plugin cannot run a second
  // one — but it does not need to. `serviceFor` hands out the running service
  // (shell.qml:275) and its popup list is deliberately aliased for exactly
  // this: "consumers outside this Item's id scope can bind to it".
  readonly property var notifications: shell && shell.serviceFor
    ? shell.serviceFor("omarchy.notifications") : null
  readonly property var popupModel: notifications && notifications.popupModel
    ? notifications.popupModel : null
  property int _popupCount: 0

  Connections {
    target: root.popupModel
    function onCountChanged() {
      var n = root.popupModel ? root.popupModel.count : 0
      // Only an arrival is interesting; a toast expiring is not news.
      if (n > root._popupCount && root.reactions.notification !== false) {
        root.notifyAt = Date.now()
        root.nudge()
      }
      root._popupCount = n
    }
  }

  // A theme switch repaints the cat mid-stride, which is a good excuse to have
  // it startle. The first assignment is the initial colour, not a change.
  readonly property color themeInk: Color.bar.text
  property bool _themeSeen: false
  onThemeInkChanged: {
    if (_themeSeen && reactions.theme !== false) {
      themeChangedAt = Date.now()
      nudge()
    }
    _themeSeen = true
  }

  readonly property bool musicPlaying: {
    if (reactions.music === false) return false
    var players = Mpris.players ? Mpris.players.values : []
    for (var i = 0; i < players.length; i++) {
      if (players[i] && players[i].isPlaying) return true
    }
    return false
  }

  // A machine with no battery reports onBattery false forever, which would
  // read as "permanently charging" and leave the cat asleep for good. Only
  // count it as charging when there is actually a battery being charged.
  readonly property bool charging: {
    if (reactions.charging === false) return false
    var device = UPower.displayDevice
    return !!(device && device.isPresent && !UPower.onBattery)
  }

  // The pointer counts as "at the bar" inside the bar strip plus a small
  // approach margin, so heading for the bar is enough to summon the cat.
  readonly property int chaseMargin: 12

  // Returns { onBar, pos } with pos on the virtual bar, or null.
  function pointerHit() {
    if (pointerX < 0) return null
    var depth = barSize + chaseMargin
    for (var i = 0; i < barScreens.length; i++) {
      var s = barScreens[i]
      if (pointerX < s.x || pointerX > s.x + s.width
        || pointerY < s.y || pointerY > s.y + s.height) continue
      var near
      if (barPosition === "top") near = pointerY - s.y <= depth
      else if (barPosition === "bottom") near = (s.y + s.height) - pointerY <= depth
      else if (barPosition === "left") near = pointerX - s.x <= depth
      else near = (s.x + s.width) - pointerX <= depth
      if (!near) return null
      return {
        onBar: true,
        pos: screenOffsets[i] + (vertical ? pointerY - s.y : pointerX - s.x)
      }
    }
    return null
  }

  // ------------------------------------------------------------ cat state

  property real catPos: 0
  property string catPose: "stop"
  property bool catBob: false
  property bool catSettled: false
  property bool catGalloping: false
  // 0 while on the bar, up to 1 at the top of a pounce.
  property real catLift: 0
  // Which way is "into the screen" from the bar's edge.
  readonly property int inwardSign: (barPosition === "top" || barPosition === "left") ? 1 : -1
  property int animTick: 0
  // Seeded from the clock so the cat does not live the same day twice. The
  // brain's generator is deterministic by design — that is what makes the
  // wander tests reproducible — but a fixed seed would mean every session
  // started in the same spot and wandered the same route.
  property var brainState: Brain.freshState(Date.now() % 2147483647)

  readonly property bool maskActive: catSettled && root.pettable && !root.barHidden

  // --------------------------------------------------------- cursor feed

  // Hyprland has no cursor-move event and Quickshell exposes no pointer, so
  // the position is sampled by a helper. See bin/navbar-cat-cursor for why it
  // talks to the socket directly instead of shelling out to hyprctl.
  Process {
    id: cursorFeed
    running: root.ready && root.chaseCursor && !root.barHidden
    command: [root.helper]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function (line) {
        var parts = String(line).trim().split(/\s+/)
        if (parts.length < 2) return
        var x = parseInt(parts[0], 10)
        var y = parseInt(parts[1], 10)
        if (isNaN(x) || isNaN(y)) return
        root.pointerX = x
        root.pointerY = y
        root.lastPointerMoveAt = Date.now()
        root.nudge()
      }
    }
  }

  // A sleeping cat does not need the pointer ten times a second. Slowing the
  // sampler down while it sleeps is most of the reason this costs nothing when
  // the desktop is idle.
  readonly property int cursorInterval: catPose === "sleep" ? 500 : 100
  onCursorIntervalChanged: if (cursorFeed.running) cursorFeed.write(cursorInterval + "\n")

  // ------------------------------------------------------- event sources

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      var workspace = Hyprland.focusedWorkspace
      if (!workspace) return
      var id = Number(workspace.id)
      if (root._lastWorkspaceId >= 0 && id !== root._lastWorkspaceId) {
        root.workspaceEvent = { at: Date.now(), dir: id > root._lastWorkspaceId ? 1 : -1 }
        root.nudge()
      }
      root._lastWorkspaceId = id
    }
  }
  property int _lastWorkspaceId: -1

  onMusicPlayingChanged: nudge()
  onChargingChanged: nudge()
  onBarPositionChanged: nudge()

  // barLength now spans everything
  readonly property real barLength: totalLength

  onBarScreensChanged: nudge()      // replaces onCatScreenChanged
  // ------------------------------------------------------------ the tick

  // 30fps: fast enough that a running cat does not visibly stutter, slow
  // enough to be free. The sprite's own frames advance far slower (below).
  readonly property int tickMs: 33

  // One stride is two sprite frames. At top speed one stride covers
  // 4 cat lengths, so top speed follows the cat size.
  readonly property int frameMs: 150
  readonly property real strideLength: 4 * catSize
  // The bound goes up on a horizontal bar. On a vertical bar "up" has no
  // meaning, so it goes toward the screen interior.
  readonly property int gallopSign: vertical ? inwardSign : -1
  // The bound must fit in the free space on one side of the centred cat.
  readonly property real gallopHeight: Math.max(0, Math.min(catSize / 3, (barSize - catSize) / 2))
  // The leap takes this share of a stride. The hop takes the rest.
  readonly property real leapShare: 0.6
  // Largest nose-up or nose-down angle, in degrees.
  readonly property real gallopTilt: 5
  // Where the cat is inside the current stride, from 0 to 1.
  readonly property real gallopPhase: (catPos % strideLength) / strideLength
  // Position inside the current arc, from 0 to 1. The leap and the hop each
  // have their own arc.
  function gallopQ(phase) {
    return phase < leapShare ? phase / leapShare : (phase - leapShare) / (1 - leapShare)
  }
  // The hop is 40% as high as the leap.
  function gallopScale(phase) { return phase < leapShare ? 1 : 0.4 }

  function gallopLift(phase) {
    var q = gallopQ(phase)
    return gallopScale(phase) * 4 * q * (1 - q)
  }
  // Slope of the arc: +1 rising, 0 at the top, -1 falling.
  function gallopPitch(phase) {
    return gallopScale(phase) * (1 - 2 * gallopQ(phase))
  }
  readonly property real sprintSpeed: strideLength * 1000 / (2 * frameMs)  // About 150 px/s at the default size. Tying it to sprintSpeed keeps a run
  // slower than a sprint at every size.
  readonly property real runSpeed: sprintSpeed * 0.7
  
  function nudge() {
    // Something happened that the cat might care about — make sure the loop is
    // running to notice it.
    if (!ticker.running && !barHidden) ticker.running = true
  }

  Timer {
    id: ticker
    interval: root.tickMs
    repeat: true
    running: false
    onTriggered: root.step()
  }

  Timer {
    id: animator
    // oneko alternates its two frames far slower than the movement updates;
    // matching that keeps the walk cycle looking hand-drawn rather than frantic.
    interval: root.frameMs
    repeat: true
    running: ticker.running
    onTriggered: root.animTick = (root.animTick + 1) & 0xff
  }

  property bool _placed: false

  function step() {
    if (barScreens.length === 0 || barLength <= 0) return
    
    var now = Date.now()
    var maxPos = Math.max(0, barLength - catSize)

    // Drop the cat somewhere arbitrary the first time we know how long the bar
    // is. Starting at zero every session meant that on a machine left plugged
    // in — where the cat settles straight away — it always dozed off in the
    // same left-hand corner.
    if (!_placed) {
      _placed = true
      catPos = Brain.pickSpot(brainState, maxPos, barLength, avoidCenter)
    }

    var decision = Brain.decide({
      now: now,
      axis: vertical ? "v" : "h",
      edge: barPosition,
      barLength: barLength,
      catSize: catSize,
      x: catPos,
      pointer: pointerHit(),
      pettedAt: pettedAt >= 0 ? pettedAt : null,
      lastPointerMoveAt: lastPointerMoveAt,
      music: musicPlaying,
      charging: charging,
      workspaceEvent: workspaceEvent,
      notifyAt: notifyAt >= 0 ? notifyAt : null,
      notifying: reactions.notification !== false && popupModel !== null
        && popupModel.count > 0,
      themeChangedAt: themeChangedAt >= 0 ? themeChangedAt : null,
      hour: new Date().getHours(),
      config: {
        chaseCursor: chaseCursor,
        pettable: pettable,
        sleepAfter: sleepAfter,
        pounce: pounce,
        fastStride: fastStride,
        rhythm: rhythm,
        avoidCenter: avoidCenter,
        stirEvery: stirEvery,
        stirFor: stirFor,
        reactions: reactions,
      },
    }, brainState)

    brainState = decision.state

    // Move toward the target at whatever pace the brain asked for. Positions
    // are rounded to whole logical pixels: pixel art on fractional offsets
    // shimmers as it moves.
    if (decision.snap) {
      // A pounce is an arc the brain describes exactly, frame by frame. Easing
      // toward it the way we ease toward a walk target would flatten it.
      catPos = decision.target
    } else {
      var pixelsPerSecond = decision.gait === "sprint" ? sprintSpeed
        : decision.gait === "run" ? runSpeed
        : decision.gait === "walk" ? 55 : 0
      if (pixelsPerSecond > 0) {
        var stepSize = pixelsPerSecond * speed * (tickMs / 1000)
        var delta = decision.target - catPos
        catPos = Math.abs(delta) <= stepSize
          ? decision.target
          : catPos + (delta > 0 ? stepSize : -stepSize)
      }
    }
    catPos = Math.max(0, Math.min(maxPos, catPos))

    catPose = decision.pose
    catBob = decision.bob
    catSettled = decision.gait === "idle"
    catGalloping = decision.gait === "sprint"
    catLift = decision.lift

    // Let a stale scamper expire so it cannot re-fire.
    if (workspaceEvent && now - workspaceEvent.at > 4000) workspaceEvent = null
    if (notifyAt >= 0 && now - notifyAt > 20000) notifyAt = -1
    if (themeChangedAt >= 0 && now - themeChangedAt > 4000) themeChangedAt = -1

    // A sleeping cat needs no frames until something wakes it, and every event
    // source above calls nudge() to start the loop again.
    if (decision.idle) {
      ticker.running = false
      animTick = 0
      // The brain books its own next stir while it sleeps, so the body has to
      // set an alarm. Without it the cat would sleep until you touched the
      // mouse, which on an unattended machine is never.
      if (decision.wakeIn > 0) {
        stirAlarm.interval = Math.max(1000, Math.round(decision.wakeIn))
        stirAlarm.restart()
      }
    }
  }

  Timer {
    id: stirAlarm
    repeat: false
    onTriggered: root.nudge()
  }

  onBarHiddenChanged: {
    if (barHidden) ticker.running = false
    else nudge()
  }

  Component.onCompleted: {
    lastPointerMoveAt = Date.now()
    var workspace = Hyprland.focusedWorkspace
    if (workspace) _lastWorkspaceId = Number(workspace.id)
    nudge()
  }

  // ------------------------------------------------------------- settings

  // The menu is the one thing here that writes. Prefer updateEntryInline —
  // third-party mutateShellConfig is bar-scoped and cannot persist plugins[].
  function setSetting(key, value) {
    if (!shell) return
    var id = root.pluginId
    var next = { id: id }
    var cur = root.config && typeof root.config === "object" ? root.config : ({})
    for (var k in cur) {
      if (k === "id") continue
      next[k] = cur[k]
    }
    next[key] = value
    root.config = next
    if (typeof shell.updateEntryInline === "function") {
      shell.updateEntryInline(id, next)
      return
    }
    // Fallback for older shells that still expose a full mutator.
    if (typeof shell.mutateShellConfig === "function") {
      shell.mutateShellConfig(function (cfg) {
        if (!Array.isArray(cfg.plugins)) cfg.plugins = []
        var entry = null
        for (var i = 0; i < cfg.plugins.length; i++) {
          if (cfg.plugins[i] && String(cfg.plugins[i].id || "") === id) {
            entry = cfg.plugins[i]
            break
          }
        }
        if (!entry) {
          entry = { id: id }
          cfg.plugins.push(entry)
        }
        entry[key] = value
      })
    }
  }

  CatMenu {
    id: catMenu
    cat: root
    onChose: function (key, value) { root.setSetting(key, value) }
  }


  // ---------------------------------------------------------- the window

  Variants {
    model: root.barScreens

    delegate: PanelWindow {
      id: window
      required property var modelData
      readonly property int segIndex: root.barScreens.indexOf(modelData)

      readonly property real segStart: root.screenOffsets[segIndex] || 0
      readonly property real segLen: root.vertical ? modelData.height : modelData.width
      readonly property bool holdsCat: root.catScreen === modelData
      // Draw the cat here if any part of it overlaps this segment.
      readonly property bool catHere: root.catPos < segStart + segLen
                                      && root.catPos + root.catSize > segStart
      readonly property bool maskOn: root.maskActive && holdsCat

      screen: modelData
      visible: !root.barHidden
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "navbar-cat"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      anchors {
        top: root.barPosition !== "bottom"
        bottom: root.barPosition !== "top"
        left: root.barPosition !== "right"
        right: root.barPosition !== "left"
      }

      implicitWidth: root.vertical ? root.barSize + root.headroom : 0
      implicitHeight: root.vertical ? 0 : root.barSize + root.headroom

      readonly property real stripCentre: root.vertical
        ? (root.barPosition === "left" ? root.barSize / 2 : window.width - root.barSize / 2)
        : (root.barPosition === "top" ? root.barSize / 2 : window.height - root.barSize / 2)
      readonly property real liftOffset: root.catLift * root.headroom * root.inwardSign

      mask: Region {
        x: window.maskOn ? Math.round(sprite.x) : 0
        y: window.maskOn ? Math.round(sprite.y) : 0
        width: window.maskOn ? sprite.width : 0
        height: window.maskOn ? sprite.height : 0
      }

      CatSprite {
        id: sprite
        visible: window.catHere
        width: root.catSize
        height: root.catSize
        devicePixels: root.catSize * window.modelData.devicePixelRatio
        assetDir: root.assetDir
        character: root.character
        pose: root.catPose
        // While galloping, the legs follow the bounce. Frame 1 is open legs
        // (leap). Frame 0 is closed legs (hop).
        animTick: root.catGalloping
          ? (root.gallopPhase < root.leapShare ? 1 : 0)
          : root.animTick
        fillColor: Color.bar.text
        inkColor: Color.bar.background
        // Nose up while rising, nose down while falling. QML rotates
        // clockwise for positive values, so a cat that faces right needs a
        // negative angle to lift its nose.
        rotation: root.catGalloping && !root.vertical
          ? -(root.catPose === "right" ? 1 : -1)
            * root.gallopPitch(root.gallopPhase) * root.gallopTilt
          : 0

        // One long leap and one short hop per stride. The phase comes from the
        // distance covered, so the bounce matches the ground speed.
        readonly property real gallopOffset: root.catGalloping
          ? root.gallopLift(root.gallopPhase) * root.gallopHeight * root.gallopSign
          : 0
        readonly property real crossPos:
          window.stripCentre + window.liftOffset - height / 2 + bobOffset + gallopOffset
        readonly property real alongPos: root.catPos - window.segStart

        x: root.vertical ? Math.round(crossPos) : Math.round(alongPos)
        y: root.vertical ? Math.round(alongPos) : Math.round(crossPos)

        property int bobOffset: root.catBob ? ((root.animTick & 1) ? -1 : 0) : 0

        MouseArea {
          anchors.fill: parent
          enabled: window.maskOn
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function (mouse) {
            if (mouse.button === Qt.RightButton) {
              catMenu.anchorPos = root.vertical
                ? sprite.y + sprite.height / 2
                : sprite.x + sprite.width / 2
              catMenu.open = true
              return
            }
            root.pettedAt = Date.now()
            root.nudge()
          }
        }
      }
    }
  }
}