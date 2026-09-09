import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Walking through a snapshot, one directory at a time.
//
// The plugin mounts the .pxar archive via proxmox-backup-client's FUSE
// backend once on first use, then serves each navigation request with
// `find $mountpoint/$path -mindepth 1 -maxdepth 1`. That's cheap: a single
// readdir per click, no recursive listing, no streaming through restic-style
// JSON.
//
// The mount stays alive for the lifetime of the panel. Closing the panel
// unmounts. Switching snapshot or archive remounts under the same path slot.
//
// Restoring never writes in place. Everything lands in a dated folder under
// ~/Restored, so a restore cannot erase work created after the snapshot; the
// user moves it back themselves, seeing exactly what they overwrite.

FocusScope {
  id: root

  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool confirmOpen: restoreConfirm.opened
  function confirmCancel() {
    // Clear the target fields so a fresh selection doesn't show the old
    // name in the dialog. accept() leaves them in place because the
    // restore Proc reads them after the dialog closes.
    restoreTargetPath = ""
    restoreTargetName = ""
    restoreConfirm.opened = false
  }
  function confirmAccept() {
    if (root.restoreTargetPath !== "")
      PbsBackupStore.restore(root.snapshotId, root.archiveName, root.restoreTargetPath)
    restoreConfirm.opened = false
  }

  signal back()

  property string restoreTargetPath: ""
  property string restoreTargetName: ""

  readonly property string currentFolderName: {
    var path = PbsBackupStore.currentPath
    if (path === "" || path === "/") return "/"
    return path.substring(path.lastIndexOf("/") + 1)
  }

  property string snapshotId: ""
  property string archiveName: ""
  property var selected: null
  property string filter: ""

  // Kept with the active snapshot so archive selection stays stable while
  // snapshots update asynchronously.
  property var archivesList: []

  implicitHeight: column.implicitHeight

  Item {
    id: keySink
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (restoreConfirm.opened) root.confirmCancel()
        else if (root.filter !== "") root.clearFilter()
        else root.back()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        root.moveCursor(1); event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        root.moveCursor(-1); event.accepted = true
      } else if (event.key === Qt.Key_PageDown) {
        root.moveCursor(10); event.accepted = true
      } else if (event.key === Qt.Key_PageUp) {
        root.moveCursor(-10); event.accepted = true
      } else if (event.key === Qt.Key_Home) {
        root.moveCursor(-root.rows.length); event.accepted = true
      } else if (event.key === Qt.Key_End) {
        root.moveCursor(root.rows.length); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (restoreConfirm.opened) root.confirmAccept()
        else root.activateCursor()
        event.accepted = true
      } else if (event.key === Qt.Key_Backspace) {
        if (root.filter !== "") root.backspaceFilter()
        else root.goUp()
        event.accepted = true
      } else if (event.key === Qt.Key_Left) {
        root.goUp(); event.accepted = true
      } else if (event.text && event.text.length === 1 && event.text >= " ") {
        root.appendFilter(event.text); event.accepted = true
      }
    }
  }

  function takeFocus() { keySink.forceActiveFocus() }

  function ensureLoaded() {
    if (!visible) return
    if (PbsBackupStore.groups.length === 0) return
    takeFocus()
    if (!PbsBackupStore.snapshotsLoaded && !PbsBackupStore.snapshotsBusy)
      PbsBackupStore.loadSnapshots()
  }

  onVisibleChanged: ensureLoaded()
  Component.onCompleted: ensureLoaded()

  Connections {
    target: PbsBackupStore
    function onGroupsChanged() { root.ensureLoaded() }
  }

  // The PBS archive is the root of this snapshot's filesystem. There is no
  // "above archive" level, so goUp at the archive root is a no-op.
  function openArchive(snapshot, archive) {
    root.snapshotId = snapshot
    root.archiveName = archive
    root.selected = null
    root.cursorIndex = 0
    clearFilter()
    PbsBackupStore.listPath(snapshot, archive, "/")
  }

  function clearFilter() { root.filter = ""; root.cursorIndex = 0 }

  function appendFilter(text) {
    if (text === undefined || text === null) return
    var ch = String(text)
    if (ch.length !== 1 || ch < " ") return
    root.filter += ch
    root.cursorIndex = 0
  }

  function backspaceFilter() {
    if (root.filter.length > 0) { root.filter = root.filter.slice(0, -1); root.cursorIndex = 0 }
  }

  // Switching archives keeps you where you were standing. Picking another
  // archive is nearly always "what did this folder look like in this other
  // snapshot", and being thrown back to the top every time makes comparing
  // two archives a chore.
  function switchArchive(snapshot, archive) {
    var previous = PbsBackupStore.currentPath
    root.snapshotId = snapshot
    root.archiveName = archive
    root.selected = null
    root.cursorIndex = 0
    clearFilter()
    var target = (previous !== "") ? previous : "/"
    PbsBackupStore.listPath(snapshot, archive, target)
  }

  function enterDirectory(path) {
    root.selected = null
    root.cursorIndex = 0
    clearFilter()
    PbsBackupStore.listPath(root.snapshotId, root.archiveName, path)
  }

  function goUp() {
    var path = PbsBackupStore.currentPath
    if (path === "" || path === "/") return
    var parent = path.substring(0, path.lastIndexOf("/"))
    if (parent === "") parent = "/"
    enterDirectory(parent)
  }

  readonly property bool atRoot: PbsBackupStore.currentPath === "/" || PbsBackupStore.currentPath === ""

  property int cursorIndex: 0

  readonly property var rows: {
    var out = []
    if (!root.atRoot) out.push({ name: "..", type: "up", path: "", size: null, mtime: null })
    var entries = root.visibleEntries
    for (var i = 0; i < entries.length; i++) out.push(entries[i])
    return out
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = cursorIndex + delta
    if (next < 0) next = 0
    if (next > rows.length - 1) next = rows.length - 1
    cursorIndex = next
    listView.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    if (String(row.type) === "up") root.goUp()
    else if (String(row.type) === "dir") root.enterDirectory(String(row.path))
    else root.selected = row
  }

  onRowsChanged: if (cursorIndex > rows.length - 1) cursorIndex = Math.max(0, rows.length - 1)

  readonly property var visibleEntries: {
    var all = PbsBackupStore.entries || []
    if (root.filter === "") return all
    var needle = root.filter.toLowerCase()
    var out = []
    for (var i = 0; i < all.length; i++)
      if (String(all[i].name).toLowerCase().indexOf(needle) !== -1) out.push(all[i])
    return out
  }

  // Pick the first snapshot as soon as the list arrives, so the browser opens
  // on content instead of an empty frame.
  Connections {
    target: PbsBackupStore
    function onSnapshotsChanged() {
      if (root.snapshotId === "" && PbsBackupStore.snapshots.length > 0) {
        var first = PbsBackupStore.snapshots[0]
        root.snapshotId = String(first.id)
        if (root.archiveName === "" && PbsBackupStore.archives.length > 0)
          root.archiveName = String(PbsBackupStore.archives[0].name)
        if (root.archiveName !== "")
          root.openArchive(root.snapshotId, root.archiveName)
      }
    }
    function onArchivesChanged() {
      if (root.archiveName === "" && PbsBackupStore.archives.length > 0) {
        root.archiveName = String(PbsBackupStore.archives[0].name)
        if (root.snapshotId !== "")
          root.openArchive(root.snapshotId, root.archiveName)
      }
    }
  }

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(10)

    // --- header ----------------------------------------------------------
    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\uf060"
        tooltipText: "Back"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.back()
      }

      // Which backup you are looking in. Only when there is a choice.
      Dropdown {
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignVCenter
        visible: PbsBackupStore.groups.length > 1
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: PbsBackupStore.browseName
        options: {
          var list = []
          for (var i = 0; i < PbsBackupStore.groups.length; i++) {
            var g = PbsBackupStore.groups[i]
            list.push({ value: String(g.name),
                        label: PbsBackupStore.groupLabel(g) })
          }
          return list
        }
        onChanged: function(value) {
          root.snapshotId = ""
          root.archiveName = ""
          root.archivesList = []
          PbsBackupStore.browseGroup(value)
          root.takeFocus()
        }
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }

      Dropdown {
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignVCenter
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: root.snapshotId
        options: {
          var list = []
          for (var i = 0; i < PbsBackupStore.snapshots.length; i++) {
            var s = PbsBackupStore.snapshots[i]
            list.push({ value: String(s.id),
                        label: PbsBackupStore.shortDate(s.time) })
          }
          return list
        }
        onChanged: function(value) {
          root.snapshotId = value
          root.archiveName = ""
          PbsBackupStore.loadArchives(value)
          root.takeFocus()
        }
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }
    }

    // --- archive picker -------------------------------------------------
    Row {
      width: parent.width
      spacing: Style.space(8)
      visible: root.archiveName !== "" || PbsBackupStore.archives.length > 1

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Archive"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Dropdown {
        width: parent.width - sourceLabel2.implicitWidth - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: root.archiveName
        options: {
          var list = []
          for (var i = 0; i < PbsBackupStore.archives.length; i++) {
            var a = PbsBackupStore.archives[i]
            list.push({ value: String(a.name),
                        label: String(a.name) + (a.size ? "  (" + PbsBackupStore.humanBytes(a.size) + ")" : "") })
          }
          return list
        }
        onChanged: function(value) {
          root.switchArchive(root.snapshotId, value)
          root.takeFocus()
        }
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }

      Text {
        id: sourceLabel2
        visible: false
        text: ""
      }
    }

    Text {
      width: parent.width
      visible: PbsBackupStore.snapshotsBusy || PbsBackupStore.snapshotsError !== ""
             || PbsBackupStore.archivesBusy || PbsBackupStore.archivesError !== ""
      text: {
        if (PbsBackupStore.snapshotsBusy) return "Loading snapshots\u2026"
        if (PbsBackupStore.archivesBusy) return "Loading archives\u2026"
        if (PbsBackupStore.snapshotsError !== "") return PbsBackupStore.snapshotsError
        if (PbsBackupStore.archivesError !== "") return PbsBackupStore.archivesError
        return ""
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: (PbsBackupStore.snapshotsError !== "" || PbsBackupStore.archivesError !== "")
             ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- breadcrumb -----------------------------------------------------
    Text {
      width: parent.width
      visible: PbsBackupStore.currentPath !== "" && PbsBackupStore.currentPath !== "/"
      text: PbsBackupStore.currentPath
      textFormat: Text.PlainText
      elide: Text.ElideLeft
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: {
        var total = PbsBackupStore.entries.length
        if (total === 0) return ""
        if (root.filter !== "")
          return "\u201C" + root.filter + "\u201D \u00b7 "
                 + root.visibleEntries.length + " of " + total
        return total < 12 ? "" : total + " items \u00b7 type to filter"
      }
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.filter !== "" ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- listing ---------------------------------------------------------
    Text {
      width: parent.width
      visible: PbsBackupStore.listBusy || PbsBackupStore.listError !== ""
      text: PbsBackupStore.listBusy ? "Reading folder\u2026" : PbsBackupStore.listError
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: PbsBackupStore.listError !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      width: parent.width
      height: Math.min(Style.space(300), Math.max(Style.space(60), listView.contentHeight + Style.space(4)))
      visible: !PbsBackupStore.listBusy && PbsBackupStore.listError === ""
               && root.archiveName !== ""
      color: "transparent"

      ListView {
        id: listView
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.rows

        delegate: RestoreRow {
          width: listView.width
          entryName: String(modelData.name)
          entryType: String(modelData.type)
          entrySize: modelData.size
          selected: root.selected && String(root.selected.path) === String(modelData.path)
          hasCursor: index === root.cursorIndex
          foreground: root.foreground
          dim: root.dim
          accent: root.accent
          fontFamily: root.fontFamily
          onActivated: {
            root.takeFocus()
            root.cursorIndex = index
            root.activateCursor()
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: {
        if (PbsBackupStore.listBusy || PbsBackupStore.listError !== "") return ""
        if (PbsBackupStore.entries.length === 0)
          return root.atRoot ? "" : "This folder is empty in this snapshot."
        if (root.visibleEntries.length === 0) return "Nothing here matches the filter."
        return ""
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Mount hint: lets a power user open the FUSE mount in their file
    // manager and use cp / find / grep from a terminal without going through
    // the restore dialog.
    Text {
      width: parent.width
      visible: PbsBackupStore.mountPoint !== ""
      text: "Mounted at " + PbsBackupStore.mountPoint
      textFormat: Text.PlainText
      elide: Text.ElideLeft
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- restore ---------------------------------------------------------
    PanelSeparator { width: parent.width }

    MenuRow {
      width: parent.width
      visible: root.selected !== null && !PbsBackupStore.restoreBusy
      label: root.selected ? "Restore \u201C" + String(root.selected.name) + "\u201D" : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        root.restoreTargetPath = String(root.selected.path)
        root.restoreTargetName = String(root.selected.name)
        restoreConfirm.opened = true
      }
    }

    MenuRow {
      width: parent.width
      visible: PbsBackupStore.currentPath !== "" && !PbsBackupStore.restoreBusy
      label: "Restore this folder (" + root.currentFolderName + ")"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        root.restoreTargetPath = PbsBackupStore.currentPath
        root.restoreTargetName = root.currentFolderName
        restoreConfirm.opened = true
      }
    }

    Text {
      width: parent.width
      visible: PbsBackupStore.restoreBusy
      topPadding: visible ? Style.space(6) : 0
      bottomPadding: visible ? Style.space(6) : 0
      text: "Restoring\u2026"
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: PbsBackupStore.restoreTarget !== "" || PbsBackupStore.restoreError !== ""
      text: PbsBackupStore.restoreError !== ""
            ? PbsBackupStore.restoreError
            : "Restored into " + PbsBackupStore.restoreTarget
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      color: PbsBackupStore.restoreError !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  ConfirmDialog {
    id: restoreConfirm
    anchors.fill: parent
    z: 10
    message: root.restoreTargetName !== ""
             ? "Restore \u201C" + PbsBackupStore.plain(root.restoreTargetName)
               + "\u201D into ~/Restored? Nothing outside that folder is touched."
             : ""
    confirmText: "Restore"
    fontFamily: root.fontFamily
    onConfirmed: root.confirmAccept()
    onCanceled: root.confirmCancel()
  }
}
