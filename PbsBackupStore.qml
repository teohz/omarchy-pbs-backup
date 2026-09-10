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

  // Track each group's last_run.finished_at from the previous poll.
  // applyStatus uses this to detect that a backup just finished for
  // the group the restore browser is currently looking at, and
  // refetch the snapshot list. Without this, a backup that completes
  // while the panel is open shows the OLD snapshot list until the
  // user manually switches group or closes the panel — Bug 3 / Bug 5.
  // Reset to {} when the user changes browseName (see browseGroup);
  // otherwise stale entries for the previous group could trigger a
  // spurious refetch.
  property var prevFinishedAt: ({})

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
    // Detect: did the active browse group's finished_at move forward?
    // We compare BEFORE assigning root.groups so the previous values
    // are still in scope.
    var prev = root.prevFinishedAt || {}
    var oldFinished = (root.browseName !== "" && prev[root.browseName])
      ? String(prev[root.browseName])
      : ""
    root.groups = payload.groups || []
    root.loaded = true
    // Rebuild prevFinishedAt from the new payload. Only set when
    // finished_at is non-empty — guards against transient missing
    // fields on a half-written status.json.
    var next = ({})
    for (var i = 0; i < root.groups.length; i++) {
      var g = root.groups[i]
      if (g && g.last_run && g.last_run.finished_at)
        next[String(g.name)] = String(g.last_run.finished_at)
    }
    root.prevFinishedAt = next
    // If the active browse group's finished_at changed, refetch the
    // snapshot list. We only refetch when we already had a list
    // loaded — first poll shouldn't race a user-driven loadSnapshots().
    if (root.browseName !== ""
        && root.snapshotsLoaded
        && oldFinished !== ""
        && next[root.browseName]
        && next[root.browseName] !== oldFinished) {
      root.loadSnapshots()
    }
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
                          root.configHome + "/omarchy-pbs-backup/config.json"]
    configProc.running = true
  }

  Process { id: configProc }

  readonly property string homeDir: Quickshell.env("HOME")

  // Mirror the CLI's ${XDG_CONFIG_HOME:-$HOME/.config} expansion. The
  // QML widget used to hard-code $HOME/.config, which silently pointed
  // at the wrong file when the user had XDG_CONFIG_HOME set.
  readonly property string configHome:
    Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")

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
    logFilePath = String(best)
    logProcFallbackTries = 0
    // Prefer omarchy-launch-editor: it's the canonical Omarchy
    // handler and opens the log in the user's terminal editor,
    // which is exactly what a .log file wants. xdg-open frequently
    // has no .log MIME handler (Nautilus owns inode/directory and
    // covers most of the desktop on Omarchy), which is what made
    // this menu row silently do nothing for the user.
    // Same rationale as openConfig() above — mirrors that pattern.
    logProc.command = ["omarchy-launch-editor", logFilePath]
    logProc.running = true
  }

  // Track which opener has been tried. omarchy-launch-editor first
  // (canonical, opens in terminal), xdg-open as a fallback when
  // omarchy-launch-editor is missing or errors out. Reset to 0 on
  // every fresh openLog() so the user gets a deterministic
  // omarchy-launch-editor-first experience each time.
  property int logProcFallbackTries: 0
  property string logFilePath: ""

  Process {
    id: logProc
    onExited: (exitCode) => {
      if (exitCode === 0 || root.logFilePath === "") return
      if (root.logProcFallbackTries === 0) {
        // omarchy-launch-editor failed (most commonly: not installed).
        // Try xdg-open once before giving up.
        root.logProcFallbackTries = 1
        root.logProc.command = ["xdg-open", root.logFilePath]
        root.logProc.running = true
      } else {
        // Both attempts failed. Tell the user instead of silently
        // doing nothing — Bug 7. Without this feedback, "click
        // menu row → nothing happens" is indistinguishable from
        // "the menu row never wired up".
        root.logNotifyProc.command = ["notify-send",
                                      "-a", "PBS Backup",
                                      "-u", "critical",
                                      "PBS Backup — could not open log",
                                      "Tried omarchy-launch-editor and xdg-open on:\n" +
                                      root.logFilePath + "\nInstall omarchy-launch-editor or set a default .log handler."]
        root.logNotifyProc.running = true
      }
    }
  }

  Process { id: logNotifyProc }

  // --- multi-mount tracking -------------------------------------------
  // Bug 9: replaces the old single-slot `mountPoint` string. Each
  // entry is { snapshotId, archive, mountPath, friendlyName }. Mounts
  // accumulate (navigating to a new snapshot adds a new entry;
  // switching back doesn't remove the old one). The per-mount Unmount
  // buttons in RestoreBrowser.qml iterate this list; the "Mount this
  // snapshot" button triggers mountSnapshot(currentSnapshot,
  // currentArchive) which adds a new entry on first click and is a
  // no-op on subsequent clicks (just opens the file manager).
  property var mounts: []

  // Return index of the entry that matches the given snapshot + archive,
  // or -1 if not currently mounted. Used to decide between
  // "open the existing mount" and "trigger a new mount".
  function findMount(snapshotId, archive) {
    var wantSnapshot = String(snapshotId || "")
    var wantArchive = String(archive || "")
    for (var i = 0; i < mounts.length; i++) {
      var m = mounts[i]
      if (String(m.snapshotId) === wantSnapshot
          && String(m.archive) === wantArchive) return i
    }
    return -1
  }

  // Append a mount entry. No-op if already present (callers shouldn't
  // double-add — lsProc only adds when findMount returned -1). The
  // mounts array is replaced with a fresh slice so QML's reactivity
  // fires (mutating in place doesn't trigger property bindings).
  function addMount(snapshotId, archive, mountPath, friendlyName) {
    if (findMount(snapshotId, archive) !== -1) return
    var copy = mounts.slice()
    copy.push({ snapshotId: String(snapshotId),
                archive: String(archive),
                mountPath: String(mountPath || ""),
                friendlyName: String(friendlyName || "") })
    mounts = copy
  }

  // Remove the entry matching snapshotId (regardless of archive —
  // there can only be one mount per snapshot under our scheme, since
  # mount_path_for is keyed by snapshot id). No-op if not present.
  function removeMount(snapshotId) {
    var want = String(snapshotId || "")
    var copy = []
    for (var i = 0; i < mounts.length; i++) {
      if (String(mounts[i].snapshotId) !== want) copy.push(mounts[i])
    }
    mounts = copy
  }

  // The current/most-recently-mounted entry's mountPath, or "" if no
  // mounts. Replaces the old `mountPoint` string for callers that
  // want "the mount we're listing right now". lsProc populates this
  // whenever it sets a new mountPoint on the listing.
  readonly property string mountPoint: {
    if (mounts.length === 0) return ""
    var cur = mounts[mounts.length - 1]
    return cur ? String(cur.mountPath || "") : ""
  }

  // Open a specific mount path in the user's file manager and fire a
  // notification with the breadcrumb. The notification child runs in
  // a one-shot shell so it can't block the panel's xdg-open handoff.
  // Used by both mountSnapshot (new mount + open) and the per-mount
  // list rows that just re-open the existing mount.
  function openMountWithNotify(mountPath) {
    if (!mountPath || mountPath === "") return
    mountProc.command = ["xdg-open", String(mountPath)]
    mountProc.running = true
    mountNotifyProc.command = ["/bin/sh", "-c",
      "MOUNT_BROWSE_PATH=" + JSON.stringify(String(mountPath)) + " '" +
      root.cli + "' mount_browse_notify"]
    mountNotifyProc.running = true
  }

  // Mount the given snapshot+archive and open it in the file manager.
  // If the snapshot is already mounted (findMount returns >= 0),
  // just opens that mount — no-op for the mount step. Otherwise
  // triggers a remount via listPath; lsProc populates the new entry
  // (its stdout handler calls addMount); mountOpenTimer then opens
  // the file manager once the entry is in the list.
  //
  // The user's spec: clicking Mount on the SAME snapshot is a no-op
  // for mounting — just opens the FM. Clicking on a DIFFERENT
  // snapshot (already mounted from a previous navigation) also no-ops
  // for mounting — the old mount stays alive, the new one (if not yet
  // mounted) gets mounted, both appear in the list. The "unmount the
  // current and mount the new" interpretation was rejected; we keep
  // mounts persistent and let the user manage them via the list.
  function mountSnapshot(snapshotId, archive) {
    var s = String(snapshotId || "")
    var a = String(archive || "")
    if (s === "" || a === "") return
    var idx = findMount(s, a)
    if (idx !== -1) {
      openMountWithNotify(mounts[idx].mountPath)
      return
    }
    pendingMountSnapshot = s
    pendingMountArchive = a
    listPath(s, a, "/")
    // lsProc may have populated synchronously (cache hit). Check
    // before starting the Timer.
    idx = findMount(s, a)
    if (idx !== -1) {
      openMountWithNotify(mounts[idx].mountPath)
      return
    }
    mountOpenTimer.start()
  }
  // The snapshot+archive mountSnapshot last queued to open, so the
  // mountOpenTimer knows which entry to wait for. lsProc's handler
  // also writes to these when it adds a new entry asynchronously.
  property string pendingMountSnapshot: ""
  property string pendingMountArchive: ""

  // Polls for lsProc to populate the pending mount entry, then opens
  // the file manager. Bounded by mountOpenDeadline so we don't spin
  // forever if the mount fails (lsProc already set listError in that
  // case, so the user sees the failure inline).
  Timer {
    id: mountOpenTimer
    property int remaining: 50
    interval: 100
    repeat: true
    running: false
    onTriggered: {
      var s = root.pendingMountSnapshot
      var a = root.pendingMountArchive
      var idx = root.findMount(s, a)
      if (idx !== -1 && root.mounts[idx].mountPath !== "") {
        running = false
        root.openMountWithNotify(root.mounts[idx].mountPath)
        root.pendingMountSnapshot = ""
        root.pendingMountArchive = ""
        return
      }
      remaining = remaining - 1
      if (remaining <= 0) {
        running = false
        root.pendingMountSnapshot = ""
        root.pendingMountArchive = ""
      }
    }
  }

  // Unmount just one snapshot's mount (per the new list UI). Optimistically
  // removes it from the mounts list so the row disappears immediately;
  // the onExited handler on unmountOneProc notifies on real failure.
  function unmountSnapshot(snapshotId) {
    var s = String(snapshotId || "")
    if (s === "") return
    var idx = -1
    for (var i = 0; i < mounts.length; i++) {
      if (String(mounts[i].snapshotId) === s) { idx = i; break }
    }
    if (idx === -1) return
    var group = browseName || (groups.length > 0 ? String(groups[0].name) : "")
    if (group === "") return
    unmountOneProc.command = [root.cli, "unmount",
                              "--dest", group,
                              "--snapshot", s]
    unmountOneProc.running = true
    removeMount(s)
  }

  // Unmount every mount the store knows about — used by the legacy
  // "Unmount all" affordance (none in the current UI; kept for
  // future use and tests).
  function unmountAll() {
    var targets = []
    if (browseName !== "") targets.push(browseName)
    for (var i = 0; i < groups.length; i++) {
      var n = String(groups[i].name)
      if (targets.indexOf(n) === -1) targets.push(n)
    }
    if (targets.length === 0) return
    // Drop the in-memory list immediately so the UI reflects reality.
    mounts = []
    unmountProc.command = [root.cli, "unmount", "--dest", String(targets[0])]
    unmountProc.running = true
    if (targets.length > 1) {
      unmountFollowups.targets = targets.slice(1)
      unmountFollowups.index = 0
      unmountFollowups.running = true
    }
  }

  Process { id: mountProc }
  Process { id: mountNotifyProc }
  Process {
    id: unmountOneProc
    onExited: (exitCode) => {
      // If the per-snapshot unmount fails (FUSE busy, missing dir)
      // we already optimistically removed the entry from `mounts`;
      // restore it so the row reappears and the user can retry.
      // Without this, the UI lies 'unmounted' while the mount is
      // still alive on disk.
      if (exitCode !== 0) {
        // We don't know which snapshot failed (the command array
        // was set just before .running=true). Notify so the user
        // has a chance to recover; restoring the specific entry is
        // a TODO that needs a richer Process contract.
        root.unmountNotifyProc.command = ["notify-send",
                                           "-a", "PBS Backup",
                                           "-u", "critical",
                                           "PBS Backup — unmount failed",
                                           "cmd_unmount exited " + exitCode +
                                           ". The mount may still be alive; run:\nomarchy-pbs-backup unmount --snapshot <id>"]
        root.unmountNotifyProc.running = true
      }
    }
  }
  Process { id: unmountProc }
  Process { id: unmountNotifyProc }

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

  function loadArchives(snapshotId) {
    // RestoreBrowser.qml:307 calls this with a snapshot id when the user
    // picks a different snapshot from the dropdown. The implementation
    // lives in loadArchivesFor — this is just the no-arg overload that
    // delegate here would have hidden.
    loadArchivesFor(snapshotId)
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
      // Bug 9: mountPoint is now a derived property of `mounts`. The
      // cache may carry a mountPoint from before this session's Bug 9
      // work, so we promote it into the live mounts list here. Cache
      // hit doesn't trigger cmd_ls (no auto-mount), so we just make
      // sure the entry exists in mounts and points at the right path.
      var cachedMp = listCache[key].mountPoint || ""
      if (cachedMp !== ""
          && root.findMount(snapshot, archive) === -1) {
        root.addMount(snapshot, archive, cachedMp, "")
      }
      return
    }

    entries = []
    listTruncated = false
    listBusy = true
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
          // Bug 9: cmd_ls now enriches mount failures with snapshot
          // and archive. Surface them in listError so the user knows
          // which one failed when switching repositories.
          var parts = []
          if (payload.snapshot) parts.push("snapshot=" + String(payload.snapshot))
          if (payload.archive) parts.push("archive=" + String(payload.archive))
          var context = parts.length > 0 ? (" [" + parts.join(", ") + "]") : ""
          root.listError = (payload.error ? String(payload.error) : "could not read this folder") + context
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
          // Bug 9: when cmd_ls returns a fresh mount, add it to the
          // multi-mount list (if not already present). mountPoint is
          // a derived view of the last entry's path. addMount only
          // appends; the cache hit branch above already handled the
          // "promote cached mountPath to mounts" case.
          if (record.mountPoint !== ""
              && root.findMount(root.currentSnapshot, root.currentArchive) === -1) {
            root.addMount(root.currentSnapshot, root.currentArchive, record.mountPoint, "")
          }
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
    // mountPoint is now derived from `mounts`; clearing it would
    // require clearing mounts too. The only callers of clearListCache
    // are browseGroup() (snapshot dropdown change — mounts stay alive
    // across snapshot switches by design) and the Bug 8 unmount()
    // path which is now gone (replaced by unmountSnapshot / unmountAll).
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
    // Pass the active FUSE mount as --copy-source so cmd_restore's cp
    // fast-path runs (Bug 1, commit 4f774bd). Without this flag every
    // restore falls back to `proxmox-backup-client restore ...` which
    // always extracts the entire .ppxar.didx chunk — picking a single
    // file would pull down the whole archive. The bash helper refuses
    // to use the flag if the path isn't a real directory, so it's safe
    // to pass mountPoint even if the user invoked restore from a state
    // where the mount had been cleaned up: the script falls back to PBS.
    var args = [root.cli, "restore",
                "--dest", String(destGroup),
                "--snapshot", String(snapshot),
                "--archive", String(archive),
                "--path", String(path)]
    if (mountPoint !== "") {
      args.push("--copy-source", String(mountPoint))
    }
    restoreProc.command = args
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
    // Legacy group-wide unmount kept for back-compat. Prefer the new
    // per-snapshot unmountSnapshot() (used by the per-mount Unmount
    // buttons in RestoreBrowser.qml). unmountAll() is the explicit
    // name for "clean everything" — both ultimately call cmd_unmount
    // over every group. Kept because the existing PbsBackupStore.qml
    // / tests still reference unmount().
    unmountAll()
  }

  Process {
    id: unmountProc
    onExited: (exitCode) => {
      // Failure feedback for unmountAll / legacy unmount. We don't
      // know which group failed (cmd_unmount was the last command),
      // so the message is generic. Per-snapshot failures go through
      // unmountOneProc.onExited above.
      if (exitCode !== 0) {
        root.unmountNotifyProc.command = ["notify-send",
                                           "-a", "PBS Backup",
                                           "-u", "critical",
                                           "PBS Backup — unmount failed",
                                           "cmd_unmount exited " + exitCode +
                                           ". The mount may still be alive; try Unmount again, or run:\nomarchy-pbs-backup unmount"]
        root.unmountNotifyProc.running = true
      }
    }
  }

  Timer {
    id: unmountFollowups
    property var targets: []
    property int index: 0
    interval: 200
    repeat: false
    onTriggered: {
      // Bug 8: only re-arm the timer when there's actual work. The
      // previous version unconditionally set `running = true`, which
      // meant a 200 ms idle timer kept firing forever once the queue
      // drained — wasteful, and could starve lower-priority timers in
      // a tight Quickshell event loop.
      if (index >= targets.length) {
        running = false
        return
      }
      var t = targets[index]
      index = index + 1
      unmountProc.command = [root.cli, "unmount", "--dest", String(t)]
      unmountProc.running = true
      running = true
    }
  }

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
    // Previously this also formatted `data_added_bytes` ("X added last run"),
    // but record_status never wrote that field — PBS does not expose it
    // in a form the CLI can rely on across versions. The snapshot_count
    // alone is the honest per-run metric the CLI can guarantee.
    if (g.snapshot_count)
      return g.snapshot_count + " snapshot" + (g.snapshot_count === 1 ? "" : "s")
    return ""
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
