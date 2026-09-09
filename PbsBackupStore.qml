pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// All PBS Backup state lives here, and there is a concrete reason for that:
// a bar widget is instantiated once per monitor, so anything owning a Process
// or a Timer in Panel.qml would exist twice on a two-monitor setup and poll
// twice. This file is the model; Panel.qml and RestoreBrowser.qml are views.
//
// The rule this store is built around: showing "3 hours ago" must never cost a
// password, a network round trip, or a wait on a sleeping NAS. `status --json`
// reads nothing but local files, so the idle poll is free. Everything that
// does touch the repository -- snapshots, archives, ls, restore -- runs only
// in response to a click.

Singleton {
  id: root

  // The CLI sits next to this file, so the plugin works from wherever it was
  // installed without putting anything on $PATH.
  readonly property string cli:
    Qt.resolvedUrl("bin/omarchy-pbs-backup").toString().replace(/^file:\/\//, "")

  // Icon glyphs. Written as \u escapes on purpose: a literal private-use
  // glyph does not always survive the trip from editor to disk, and the
  // failure is silent -- an empty string, an invisible icon, and no error.
  readonly property string iconPbsBackup: "\uf1c0"  // database
  readonly property string iconFolder: "\uf07b"
  readonly property string iconFile: "\uf15b"
  readonly property string iconUp: "\uf148"

  property string fontFamily: ""

  // How times are drawn. Not the system locale, on purpose: this machine is
  // en_US, which would mean "9:54 PM", while the Omarchy clock beside us is
  // set to 24-hour. Following the locale would make the two widgets disagree
  // on the same bar.
  property string timeFormat: "HH:mm"
  property string dateFormat: "d MMM"

  // --- status -----------------------------------------------------------
  property bool configured: false
  // "Back Up Now" starts a systemd unit. Until `install` has run that unit
  // does not exist and the button would do nothing at all, with no feedback --
  // the plugin would simply look broken.
  property bool unitsInstalled: false
  // A configuration that exists but is wrong is a different problem from one
  // that isn't there, and needs a different thing said about it.
  property bool configInvalid: false
  property string configError: ""
  property var groups: []
  property bool loaded: false

  // "Any" views over the per-group state. The store keeps one Process per
  // group; "running" is whichever one is alive.
  readonly property bool anyRunning: {
    for (var i = 0; i < groups.length; i++)
      if (groups[i].running) return true
    return false
  }
  readonly property bool anyFailed: {
    for (var i = 0; i < groups.length; i++) {
      var run = groups[i].last_run
      if (run && run.result === "failed") return true
    }
    return false
  }
  readonly property bool running: anyRunning
  readonly property var progress: {
    for (var i = 0; i < groups.length; i++)
      if (groups[i].running && groups[i].progress) return groups[i].progress
    return null
  }
  readonly property bool failed: anyFailed
  readonly property bool multiple: groups.length > 1

  // Ticks once a minute so "3 hours ago" ages without a status call. Bumping
  // this property is what re-evaluates the relative-time bindings.
  property int clockTick: 0

  // --- polling ----------------------------------------------------------
  // Fast while a run is in progress, lazy otherwise. A backup that starts from
  // the timer at 03:00 is picked up within thirty seconds, which is soon
  // enough for something nobody is watching.
  readonly property int pollInterval: running ? 500 : 30000

  function refresh() { statusProc.running = true }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.applyStatus(text)
    }
  }

  function applyStatus(text) {
    var payload
    try {
      payload = JSON.parse(text)
    } catch (e) {
      // A crashing CLI must not blank the widget: keep whatever was on screen
      // and let the next poll try again.
      root.loaded = true
      return
    }
    root.configured = payload.configured === true
    root.unitsInstalled = payload.units_installed === true
    root.configInvalid = payload.invalid === true
    root.configError = payload.error ? String(payload.error) : ""
    root.groups = payload.groups || []
    root.loaded = true
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.clockTick++
  }

  // --- actions ----------------------------------------------------------
  // systemd owns every backup, including this one. Two reasons: the shell
  // restarts on a theme change or a plugin update, and a Process started here
  // would die with it halfway through a run; and the nightly timer and this
  // button start the same unit instance, so systemd serialises them without
  // any locking of our own.
  Process { id: startProc }
  Process { id: stopProc }
  Process { id: useProc; stdout: StdioCollector { onStreamFinished: root.refresh() } }

  function startAllBackups() {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].running) continue
      startOne(String(groups[i].name))
    }
    kickPoll.restart()
  }

  function startOne(name) {
    startProc.command = ["systemctl", "--user", "start", "--no-block",
                         "omarchy-pbs-backup@" + name + ".service"]
    startProc.running = true
  }

  function startBackup() {
    if (groups.length === 0 || anyRunning) return
    startOne(String(groups[0].name))
    kickPoll.restart()
  }

  function stopBackup() {
    if (groups.length === 0) return
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].running) {
        stopProc.command = ["systemctl", "--user", "stop",
                            "omarchy-pbs-backup@" + groups[i].name + ".service"]
        stopProc.running = true
      }
    }
    kickPoll.restart()
  }

  Timer {
    id: kickPoll
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  // omarchy-launch-editor honours whatever the user set as their default
  // editor and opens it in a terminal, which is what a JSON file wants.
  // xdg-open would hand a .json to whatever claims the mime type.
  function createConfig() {
    createProc.command = [root.cli, "config", "create"]
    createProc.running = true
  }

  Process {
    id: createProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.openConfig()
        root.refresh()
      }
    }
  }

  function openConfig() {
    configProc.command = ["omarchy-launch-editor",
                          homeDir + "/.config/omarchy-pbs-backup/config.json"]
    configProc.running = true
  }

  Process { id: configProc }

  readonly property string homeDir: Quickshell.env("HOME")

  // Any group with a log file we could open. Drives the visibility of the
  // "Show Last Log" menu row.
  readonly property bool hasLog: {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].last_run && groups[i].last_run.log_file) return true
    }
    return false
  }

  function openLog() {
    // Pick the most recently finished log, not the first group's log.
    // With multiple groups the first one in config order isn't necessarily
    // the one the user wants to inspect.
    var best = null
    var bestTime = ""
    for (var i = 0; i < groups.length; i++) {
      var run = groups[i].last_run
      if (!run || !run.log_file) continue
      if (!best || (run.finished_at && run.finished_at > bestTime)) {
        best = run.log_file
        bestTime = run.finished_at || ""
      }
    }
    if (!best) return
    logProc.command = ["xdg-open", String(best)]
    logProc.running = true
  }

  Process { id: logProc }

  // --- snapshots --------------------------------------------------------
  // Which group the restore browser is looking at. Separate from anything
  // the main panel does: browsing another group's history is reading, and
  // should not change what the next backup writes to.
  property string browseName: ""
  property var snapshots: []
  property bool snapshotsLoaded: false
  property bool snapshotsBusy: false
  property string snapshotsError: ""
  property var archives: []
  property bool archivesBusy: false
  property string archivesError: ""

  function browseGroup(name) {
    if (name === browseName) return
    browseName = name
    snapshots = []
    snapshotsLoaded = false
    archives = []
    clearListCache()
    loadSnapshots()
  }

  function loadSnapshots() {
    if (groups.length === 0 || snapshotsBusy) return
    if (browseName === "" && groups.length > 0) browseName = String(groups[0].name)
    snapshotsBusy = true
    snapshotsError = ""
    snapshotsProc.command = [root.cli, "snapshots", "--json", "--dest", String(browseName)]
    snapshotsProc.running = true
  }

  Process {
    id: snapshotsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.snapshotsBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.snapshotsError = "could not read snapshots"
          return
        }
        if (payload.ok !== true) {
          root.snapshotsError = payload.error ? String(payload.error) : "could not read snapshots"
          return
        }
        root.snapshots = payload.snapshots || []
        root.snapshotsLoaded = true
        // Auto-load archives for the first snapshot
        if (root.snapshots.length > 0) {
          var firstId = String(root.snapshots[0].id)
          if (root.browseSnapshotId !== firstId)
            root.loadArchivesFor(firstId)
        }
      }
    }
  }

  // Remember which snapshot we last queried archives for, so we don't re-fetch
  // every time the dropdown repaints.
  property string browseSnapshotId: ""

  function loadArchives() {
    // overload for snapshot id argument omitted — see loadArchivesFor
  }

  function loadArchivesFor(snapshotId) {
    if (!snapshotId || archivesBusy) return
    archivesBusy = true
    archivesError = ""
    browseSnapshotId = snapshotId
    archivesProc.command = [root.cli, "archives", "--json",
                            "--dest", String(browseName),
                            "--snapshot", String(snapshotId)]
    archivesProc.running = true
  }

  Process {
    id: archivesProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.archivesBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.archivesError = "could not read archives"
          return
        }
        if (payload.ok !== true) {
          root.archivesError = payload.error ? String(payload.error) : "could not read archives"
          return
        }
        root.archives = payload.archives || []
      }
    }
  }

  // --- directory listing -----------------------------------------------
  // One `find` per directory, never a recursive walk: a home directory holds
  // well over a million files and listing it whole would stall the panel for
  // minutes. Visited paths are cached for the session so walking back up is
  // instant.
  property var listCache: ({})
  property bool listBusy: false
  property string listError: ""
  property var entries: []
  property bool listTruncated: false
  property string currentPath: ""
  property string currentArchive: ""
  property string currentSnapshot: ""
  property string mountPoint: ""

  function cacheKey(snapshot, archive, path) {
    return snapshot + "|" + archive + "|" + path
  }

  function listPath(snapshot, archive, path) {
    if (!snapshot || !archive) return
    currentSnapshot = snapshot
    currentArchive = archive
    currentPath = path
    listError = ""

    var key = cacheKey(snapshot, archive, path)
    if (listCache[key] !== undefined) {
      entries = listCache[key].entries
      listTruncated = listCache[key].truncated
      mountPoint = listCache[key].mountPoint || ""
      return
    }

    entries = []
    listTruncated = false
    listBusy = true
    mountPoint = ""
    lsProc.command = [root.cli, "ls", "--json",
                      "--dest", String(browseName || (groups.length > 0 ? groups[0].name : "")),
                      "--snapshot", String(snapshot),
                      "--archive", String(archive),
                      "--path", String(path)]
    lsProc.running = true
  }

  Process {
    id: lsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.listBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.listError = "could not read this folder"
          return
        }
        if (payload.ok !== true) {
          root.listError = payload.error ? String(payload.error) : "could not read this folder"
          return
        }
        var key = root.cacheKey(root.currentSnapshot, root.currentArchive, String(payload.path))
        var record = { entries: payload.entries || [],
                       truncated: payload.truncated === true,
                       mountPoint: payload.mount_point ? String(payload.mount_point) : "" }
        root.listCache[key] = record
        if (String(payload.path) === root.currentPath) {
          root.entries = record.entries
          root.listTruncated = record.truncated
          root.mountPoint = record.mountPoint
        }
      }
    }
  }

  function clearListCache() {
    listCache = ({})
    entries = []
    currentPath = ""
    currentArchive = ""
    currentSnapshot = ""
    mountPoint = ""
  }

  // --- restore ----------------------------------------------------------
  // Never in place. Everything lands in a dated folder under ~/Restored, so a
  // restore can never erase work created after the snapshot; moving it back is
  // a deliberate act the user performs in a file manager, seeing what they
  // overwrite.
  property bool restoreBusy: false
  property string restoreTarget: ""
  property string restoreError: ""

  function restore(snapshot, archive, path) {
    if (groups.length === 0 || restoreBusy) return
    restoreBusy = true
    restoreError = ""
    restoreTarget = ""
    var destGroup = (browseName !== "") ? browseName : groups[0].name
    restoreProc.command = [root.cli, "restore",
                           "--dest", String(destGroup),
                           "--snapshot", String(snapshot),
                           "--archive", String(archive),
                           "--path", String(path)]
    restoreProc.running = true
  }

  Process {
    id: restoreProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.restoreBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.restoreError = "restore failed"
          return
        }
        if (payload.ok === true) root.restoreTarget = String(payload.target)
        else root.restoreError = payload.error ? String(payload.error) : "restore failed"
      }
    }
  }

  function unmount() {
    if (browseName === "") return
    var proc = {
      command: [root.cli, "unmount", "--dest", String(browseName)],
      running: true
    }
    // Fire-and-forget; we don't care about the result. Use Process via JS:
    unmountProc.command = proc.command
    unmountProc.running = true
  }

  Process { id: unmountProc }

  // --- formatting -------------------------------------------------------
  function plain(value) {
    return String(value === undefined || value === null ? "" : value).replace(/[<>]/g, "")
  }

  function parseTime(value) {
    if (!value) return null
    var date = new Date(String(value))
    return isNaN(date.getTime()) ? null : date
  }

  function relativeTime(value) {
    var date = parseTime(value)
    if (!date) return "never"

    var seconds = Math.floor((Date.now() - date.getTime()) / 1000)
    if (seconds < 0) seconds = 0
    if (seconds < 60) return "just now"

    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago")

    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")

    var days = Math.floor(hours / 24)
    if (days < 30) return days + (days === 1 ? " day ago" : " days ago")

    var months = Math.floor(days / 30)
    if (months < 12) return months + (months === 1 ? " month ago" : " months ago")

    var years = Math.floor(days / 365)
    return years + (years === 1 ? " year ago" : " years ago")
  }

  function shortDate(value) {
    var date = parseTime(value)
    if (!date) return ""
    return Qt.formatDateTime(date, root.dateFormat + " " + root.timeFormat)
  }

  // "Today, 21:52" / "Yesterday, 03:09" / "24 Aug, 03:09" -- the menu-bar
  // phrasing, where the day matters more than how many hours ago it was.
  function menuDate(value) {
    var date = parseTime(value)
    if (!date) return "Never"

    var now = new Date()
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    var time = Qt.formatDateTime(date, root.timeFormat)
    if (date >= midnight) return "Today, " + time
    if (date >= new Date(midnight.getTime() - 86400000)) return "Yesterday, " + time
    return Qt.formatDateTime(date, root.dateFormat) + ", " + time
  }

  function humanBytes(value) {
    var bytes = Number(value)
    if (!isFinite(bytes) || bytes <= 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var unit = 0
    while (bytes >= 1024 && unit < units.length - 1) { bytes /= 1024; unit++ }
    return (bytes >= 100 || unit === 0 ? Math.round(bytes) : bytes.toFixed(1)) + " " + units[unit]
  }

  function humanDuration(seconds) {
    var total = Number(seconds)
    if (!isFinite(total) || total < 0) return ""
    if (total < 60) return Math.round(total) + "s"
    var minutes = Math.floor(total / 60)
    if (minutes < 60) return minutes + "m " + Math.round(total % 60) + "s"
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
  }

  // What one group says about itself in the list.
  function groupLabel(g) {
    return g.display_name ? String(g.display_name) : String(g.name)
  }

  function groupState(g) {
    clockTick
    if (g.running) return "Working\u2026"
    if (!g.last_run) return "Never"
    if (g.last_run.result === "failed")
      return "Failed " + menuDate(g.last_run.finished_at)
             .replace(/^Today/, "today").replace(/^Yesterday/, "yesterday")
    return menuDate(g.last_run.finished_at)
  }

  function groupDetail(g) {
    clockTick
    if (g.running) return "Backing up\u2026"
    if (groupFailed(g)) {
      if (g.last_success_at)
        return "Last good backup: " + menuDate(g.last_success_at)
      return "No successful backup yet"
    }
    if (!g.last_run) return ""
    var parts = []
    if (g.snapshot_count)
      parts.push(g.snapshot_count + " snapshot" + (g.snapshot_count === 1 ? "" : "s"))
    if (g.last_run.data_added_bytes)
      parts.push(humanBytes(g.last_run.data_added_bytes) + " added last run")
    return parts.join(" \u00b7 ")
  }

  function groupFailed(g) {
    return g.last_run ? g.last_run.result === "failed" : false
  }

  // What the bar tooltip says. The bar shows the icon alone, so this is the
  // only place the age of a backup is legible without opening the panel.
  readonly property string tooltip: {
    clockTick
    if (!configured) return "PBS Backup — not configured yet"
    if (anyRunning) return "Backing up…"
    if (anyFailed) {
      var when = ""
      var since = ""
      for (var i = 0; i < groups.length; i++) {
        var g = groups[i]
        if (g.last_run && g.last_run.result === "failed") {
          when = menuDate(g.last_run.finished_at)
          if (g.last_success_at)
            since = " — last good one " + relativeTime(g.last_success_at)
          break
        }
      }
      return "Backup failed " + when.charAt(0).toLowerCase() + when.slice(1) + since
    }
    var last = ""
    for (var j = 0; j < groups.length; j++) {
      if (groups[j].last_run && groups[j].last_run.finished_at) {
        last = relativeTime(groups[j].last_run.finished_at)
        break
      }
    }
    if (last === "") return "PBS Backup — no backup yet"
    return "Last backup: " + last
  }
}
