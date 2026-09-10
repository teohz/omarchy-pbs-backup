import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// PBS Backup: scheduled Proxmox Backup Server backups, with the state of the
// last one a glance away and a snapshot browser one click further.
//
// The bar shows the icon and nothing else. Bar space is scarce and the age
// of a backup is not a number anyone wants to read continuously -- you only
// want to be disturbed when something is wrong, which is what the colour is
// for. The relative time lives in the tooltip and at the top of the panel.
//
// Everything with state lives in PbsBackupStore, a singleton: a bar widget is
// instantiated once per monitor, so timers and processes declared here would
// run twice on a two-monitor setup.

Panel {
  id: root

  moduleName: "teohz.pbs-backup"
  ipcTarget: "teohz.pbs-backup"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.2)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Which view the panel is showing. The restore browser reuses the same
  // KeyboardPanel and simply swaps the content, because a second window would
  // lose keyboard focus on Wayland the moment the first one closed.
  property bool browsing: false

  readonly property color barIconColor: {
    if (PbsBackupStore.running) return accent
    if (PbsBackupStore.failed) return urgent
    if (!PbsBackupStore.configured) return Qt.darker(barForeground, 1.9)
    return barForeground
  }

  // Panel is a bare Item with no size of its own, so without this the bar
  // hands the widget zero width -- and a zero-width widget still paints its
  // children, so it looks fine and is simply not clickable. Derive the size
  // from the content, never from a child that fills this item.
  readonly property bool showBadge: PbsBackupStore.failed
  readonly property int badgeSize: showBadge ? Style.space(9) : 0
  readonly property int barContentWidth:
    Style.bar.iconFont + (showBadge ? badgeSize - Style.space(3) : 0)
  readonly property int barSlot: barContentWidth + Style.space(10)
  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  function applySettings() {
    PbsBackupStore.fontFamily = root.fontFamily
    PbsBackupStore.timeFormat = String(root.setting("timeFormat", "HH:mm"))
    PbsBackupStore.dateFormat = String(root.setting("dateFormat", "d MMM"))
  }

  // Applied on settingsChanged as well as on completion: the host assigns
  // `settings` after constructing the widget, so reading them only in
  // onCompleted means reading an empty object.
  onSettingsChanged: root.applySettings()
  Component.onCompleted: root.applySettings()

  onOpenedChanged: {
    if (!opened) {
      root.browsing = false
      // Mounts persist across panel sessions. They die at the next
      // backup run via `private_dir $STATE_DIR mounts`, or at the
      // explicit Unmount menu row in the restore browser. Auto-unmounting
      // here tore down the FUSE mount the moment the user opened a file
      // manager — the file manager then showed 0-byte entries.
      return
    }
    PbsBackupStore.refresh()
  }

  // With the key catcher blocked, nothing else claims the keyboard: the
  // listing has to take it, and give it back on the way out.
  onBrowsingChanged: {
    if (browsing) browser.takeFocus()
    else keyCatcher.forceActiveFocus()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.barContentWidth
    tooltipText: PbsBackupStore.plain(PbsBackupStore.tooltip)

    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: PbsBackupStore.iconPbsBackup
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.barIconColor

          SequentialAnimation on opacity {
            running: PbsBackupStore.running
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { from: 1.0; to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.45; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
          }
          onVisibleChanged: if (!PbsBackupStore.running) opacity = 1.0
        }

        Rectangle {
          visible: root.showBadge
          width: root.badgeSize
          height: root.badgeSize
          radius: width / 2
          color: root.urgent
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: Style.bar.iconFont / 2
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -Style.bar.iconFont / 2.6

          Text {
            anchors.centerIn: parent
            text: "!"
            textFormat: Text.PlainText
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.badgeSize * 0.8)
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) PbsBackupStore.refresh()
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

    readonly property int desiredWidth: Style.space(root.browsing ? 460 : 280)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(
                     root.browsing ? browser.implicitHeight : mainColumn.implicitHeight,
                     Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      blocked: root.browsing

      onCloseRequested: {
        if (stopConfirm.opened) stopConfirm.opened = false
        else if (root.browsing && browser.confirmOpen) browser.confirmCancel()
        else if (root.browsing && browser.filter !== "") browser.clearFilter()
        else if (root.browsing) root.browsing = false
        else root.close()
      }

      onActivateRequested: {
        if (stopConfirm.opened) {
          PbsBackupStore.stopBackup()
          stopConfirm.opened = false
        } else if (root.browsing && browser.confirmOpen) {
          browser.confirmAccept()
        }
      }

      onTabRequested: function(direction) { root.switchPanel(direction) }

      // --- main view ------------------------------------------------------
      Flickable {
        id: mainScroll
        anchors.fill: parent
        visible: !root.browsing
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainColumn
          width: mainScroll.width
          spacing: 0

          Text {
            width: parent.width
            bottomPadding: Style.space(8)
            text: {
              if (PbsBackupStore.configInvalid) return "There is a problem with your configuration"
              if (!PbsBackupStore.configured) return "No backups are set up yet"
              if (PbsBackupStore.anyRunning) return "Backing up"
              if (PbsBackupStore.anyFailed) return "A backup failed"
              return "Backups"
            }
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: (PbsBackupStore.anyFailed || PbsBackupStore.configInvalid)
                   ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: text !== ""
            bottomPadding: visible ? Style.space(8) : 0
            text: {
              if (PbsBackupStore.configInvalid) return PbsBackupStore.configError
              if (!PbsBackupStore.configured) return "Create one below and it opens in your editor"
              return ""
            }
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: PbsBackupStore.configInvalid ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            bottomPadding: Style.space(8)

            Repeater {
              model: PbsBackupStore.groups

              Column {
                width: parent.width
                spacing: Style.space(1)

                Item {
                  width: parent.width
                  height: Style.space(18)

                  Text {
                    anchors.left: parent.left
                    anchors.right: stateText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: PbsBackupStore.groupLabel(modelData)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: stateText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: PbsBackupStore.groupState(modelData)
                    textFormat: Text.PlainText
                    color: PbsBackupStore.groupFailed(modelData) ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: PbsBackupStore.groupDetail(modelData)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: PbsBackupStore.groupFailed(modelData) ? root.dim : root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            visible: PbsBackupStore.running
            height: visible ? Style.space(3) : 0
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Rectangle {
              height: parent.height
              radius: parent.radius
              color: root.accent
              width: {
                var pr = PbsBackupStore.progress
                if (!pr || pr.percent === undefined || pr.percent === null) return 0
                return Math.max(0, Math.min(1, Number(pr.percent))) * parent.width
              }
              Behavior on width { NumberAnimation { duration: 300 } }
            }
          }

          Text {
            width: parent.width
            visible: PbsBackupStore.running && text !== ""
            topPadding: visible ? Style.space(4) : 0
            bottomPadding: visible ? Style.space(4) : 0
            text: {
              var pr = PbsBackupStore.progress
              if (!pr || !pr.total_bytes) return ""
              return PbsBackupStore.humanBytes(pr.bytes_done) + " of "
                     + PbsBackupStore.humanBytes(pr.total_bytes)
            }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          MenuRow {
            width: parent.width
            visible: PbsBackupStore.configured && PbsBackupStore.unitsInstalled
            label: PbsBackupStore.anyRunning ? "Stop This Backup" : "Back Up Now"
            destructive: PbsBackupStore.anyRunning
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              if (PbsBackupStore.anyRunning) stopConfirm.opened = true
              else if (PbsBackupStore.multiple) PbsBackupStore.startAllBackups()
              else PbsBackupStore.startBackup()
            }
          }

          Text {
            width: parent.width
            visible: PbsBackupStore.configured && !PbsBackupStore.unitsInstalled
            topPadding: visible ? Style.space(6) : 0
            bottomPadding: visible ? Style.space(6) : 0
            text: "Run \u2018omarchy-pbs-backup install\u2019 once to enable backups"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: PbsBackupStore.configured
          }

          MenuRow {
            width: parent.width
            visible: PbsBackupStore.configured
            label: "Restore Files\u2026"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              root.browsing = true
              if (!PbsBackupStore.snapshotsLoaded) PbsBackupStore.loadSnapshots()
            }
          }

          MenuRow {
            width: parent.width
            visible: PbsBackupStore.configured && PbsBackupStore.hasLog
            label: "Show Last Log\u2026"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              // Fire-and-forget: openLog tries omarchy-launch-editor
              // first (opens the log in the user's terminal editor),
              // then xdg-open as a fallback. If both fail, openLog
              // fires a notify-send so 'click → nothing happens' is
              // distinguishable from 'click → handler error'. Don't
              // close the panel — a terminal editor may launch
              // asynchronously in another workspace and a closed
              // panel + nothing visible is still indistinguishable
              // from "did nothing".
              PbsBackupStore.openLog()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          MenuRow {
            width: parent.width
            label: (PbsBackupStore.configured || PbsBackupStore.configInvalid)
                   ? "Open Configuration\u2026" : "Create Configuration\u2026"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              if (PbsBackupStore.configured || PbsBackupStore.configInvalid)
                PbsBackupStore.openConfig()
              else PbsBackupStore.createConfig()
              root.close()
            }
          }
        }
      }

      // --- restore view ---------------------------------------------------
      RestoreBrowser {
        id: browser
        anchors.fill: parent
        visible: root.browsing
        foreground: root.foreground
        dim: root.dim
        accent: root.accent
        urgent: root.urgent
        fontFamily: root.fontFamily
        onBack: root.browsing = false
      }
    }

    ConfirmDialog {
      id: stopConfirm
      anchors.fill: parent
      z: 10
      message: "Stop this backup? Nothing is lost, but no snapshot is created for this run."
      confirmText: "Stop"
      cancelText: "Keep running"
      fontFamily: root.fontFamily
      onConfirmed: {
        PbsBackupStore.stopBackup()
        stopConfirm.opened = false
      }
      onCanceled: stopConfirm.opened = false
    }
  }
}
