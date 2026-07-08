import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../"
import "../WindowRegistry.js" as Registry

PanelWindow {
    id: popupWindow

    Caching { id: paths }

    property var popupModel
    property real uiScale: 1.0

    // Local map — live QObjects are stored here directly via storeNotif()
    // called from Main.qml's onNotification handler. Never crosses window
    // boundaries via a binding, which is what was breaking sourceNotif.
    property var _notifMap: ({})

    function storeNotif(uid, notif) {
        _notifMap[uid] = notif;
    }

    function getNotif(uid) {
        return _notifMap[uid] || null;
    }

    function removeNotif(uid) {
        delete _notifMap[uid];
        popupWindow.removeRequested(uid);
    }

    signal removeRequested(int uid)

    property var layoutConfig: Registry.getPopupLayout(Screen.width, popupWindow.uiScale)

    WlrLayershell.namespace: "qs-popups"
    WlrLayershell.layer: WlrLayer.Overlay

    anchors {
        top: true
        right: true
    }

    margins {
        top: popupWindow.layoutConfig.marginTop
        right: popupWindow.layoutConfig.marginRight
    }

    exclusionMode: ExclusionMode.Ignore
    focusable: false
    color: "transparent"

    // implicit* — direct width/height on layer-shell windows is deprecated, and
    // the height Behavior re-fired the warning on every animation frame.
    implicitWidth: popupWindow.layoutConfig.w
    implicitHeight: Math.min(popupList.contentHeight, Screen.height * 0.8)

    Behavior on implicitHeight {
        NumberAnimation { duration: 400; easing.type: Easing.OutQuint }
    }

    property bool dndEnabled: false

    Process {
        id: dndPoller
        command: ["bash", "-c", "cat '" + paths.getCacheDir("dnd") + "/state' 2>/dev/null || echo '0'"]
        stdout: StdioCollector {
            onStreamFinished: popupWindow.dndEnabled = (this.text.trim() === "1")
        }
    }
    // Poll DND only while popups are actually on screen (was running: true —
    // a `cat` fork every second, 24/7). triggeredOnStart means the state is
    // read the instant the first popup appears, so a fresh notification still
    // respects DND immediately; changes while nothing is showing are invisible
    // by definition.
    Timer {
        interval: 1000; running: popupList.count > 0; repeat: true; triggeredOnStart: true
        onTriggered: dndPoller.running = true
    }

    Item {
        id: contentWrapper
        anchors.fill: parent

        opacity: popupWindow.dndEnabled ? 0.0 : 1.0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 300 } }

        MatugenColors { id: _theme }

        property var blobPalette1: [_theme.mauve, _theme.blue, _theme.peach, _theme.green, _theme.pink]
        property var blobPalette2: [_theme.sapphire, _theme.teal, _theme.maroon, _theme.yellow, _theme.red]

        // Timer-stepped at 20fps and gated on there being popups to decorate
        // (was an ungated per-frame NumberAnimation running around the clock).
        // Blobs sweep 2π per 25s — well under a pixel per 50ms step.
        property real globalOrbitAngle: 0
        Timer {
            interval: 50; repeat: true; running: popupList.count > 0
            onTriggered: contentWrapper.globalOrbitAngle = (contentWrapper.globalOrbitAngle + Math.PI * 2 * 50 / 25000) % (Math.PI * 2)
        }

        ListView {
            id: popupList
            anchors.fill: parent
            model: popupWindow.popupModel
            spacing: popupWindow.layoutConfig.spacing
            interactive: false
            clip: false

            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 400; easing.type: Easing.OutQuint }
                    NumberAnimation { property: "x"; from: popupWindow.width * 0.4; to: 0; duration: 500; easing.type: Easing.OutQuint }
                    NumberAnimation { property: "scale"; from: 0.9; to: 1.0; duration: 500; easing.type: Easing.OutQuint }
                }
            }

            remove: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; to: 0.0; duration: 350; easing.type: Easing.OutQuint }
                    NumberAnimation { property: "x"; to: popupWindow.width * 0.4; duration: 400; easing.type: Easing.OutQuint }
                    NumberAnimation { property: "scale"; to: 0.9; duration: 400; easing.type: Easing.OutQuint }
                }
            }

            displaced: Transition {
                NumberAnimation { properties: "x,y"; duration: 450; easing.type: Easing.OutQuint }
            }

            delegate: Item {
                id: delegateRoot
                width: ListView.view.width
                height: contentCol.height + (popupWindow.layoutConfig.padding * 2)

                property string fullSummary: model.summary || ""
                property string fullBody: model.body || ""
                property int typeLenSum: 0
                property int typeLenBody: 0
                property int popupUid: model.uid

                // Resolved fresh each time via function — no binding across windows
                property var sourceNotif: popupWindow.getNotif(model.uid)

                // actionArray is built from the JSON we constructed ourselves in Main.qml
                // so "id" key is correct here — it's our own data, not the QObject
                property var actionArray: {
                    try {
                        let parsed = model.actionsJson ? JSON.parse(model.actionsJson) : []
                        return parsed
                    } catch (e) {
                        return []
                    }
                }

                property int effectiveTimeout: {
                    var n = popupWindow.getNotif(model.uid);
                    // Quickshell's property is expireTimeout (the old n.timeout was
                    // always undefined, so EVERY popup fell back to 5000 and
                    // notify-send -t was silently ignored). -1 = sender left it to
                    // the server → keep the 5s default; 0 = never expire.
                    if (!n || n.expireTimeout === undefined) return 5000;
                    if (n.expireTimeout === 0) return 0;
                    if (n.expireTimeout > 0) return n.expireTimeout;
                    return 5000;
                }

                Connections {
                    target: delegateRoot.sourceNotif || null
                    function onClosed() {
                        popupWindow.removeNotif(delegateRoot.popupUid);
                    }
                }

                ParallelAnimation {
                    running: true
                    NumberAnimation {
                        target: delegateRoot; property: "typeLenSum"
                        from: 0; to: fullSummary.length
                        duration: Math.min(fullSummary.length * 20, 600)
                        easing.type: Easing.OutCubic
                    }
                    SequentialAnimation {
                        PauseAnimation { duration: 150 }
                        NumberAnimation {
                            target: delegateRoot; property: "typeLenBody"
                            from: 0; to: fullBody.length
                            duration: Math.min(fullBody.length * 15, 1200)
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Rectangle {
                    id: popupCard
                    anchors.fill: parent
                    radius: popupWindow.layoutConfig.radius
                    color: _theme.base
                    border.color: _theme.surface1
                    border.width: 1
                    clip: true

                    // index goes to -1 while the delegate is being removed and
                    // palette[-1] is undefined → "Unable to assign [undefined] to QColor"
                    property int _blobIdx: index >= 0 ? index % 5 : 0
                    property color blob1Color: contentWrapper.blobPalette1[_blobIdx]
                    property color blob2Color: contentWrapper.blobPalette2[_blobIdx]

                    Rectangle {
                        width: parent.width * 0.7; height: width; radius: width / 2
                        x: (parent.width / 2 - width / 2) + Math.cos(contentWrapper.globalOrbitAngle * 2 + index) * 60
                        y: (parent.height / 2 - height / 2) + Math.sin(contentWrapper.globalOrbitAngle * 2 + index) * 30
                        color: popupCard.blob1Color
                        opacity: 0.12
                    }

                    Rectangle {
                        width: parent.width * 0.5; height: width; radius: width / 2
                        x: (parent.width / 2 - width / 2) + Math.sin(contentWrapper.globalOrbitAngle * 1.5 - index) * -50
                        y: (parent.height / 2 - height / 2) + Math.cos(contentWrapper.globalOrbitAngle * 1.5 - index) * -40
                        color: popupCard.blob2Color
                        opacity: 0.10
                    }

                    Timer {
                        interval: delegateRoot.effectiveTimeout > 0 ? delegateRoot.effectiveTimeout : 5000
                        running: delegateRoot.effectiveTimeout > 0
                        onTriggered: popupWindow.removeNotif(delegateRoot.popupUid)
                    }

                    // Card body click — invokes "default" action
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            var n = popupWindow.getNotif(delegateRoot.popupUid);
                            if (n && n.actions) {
                                for (var i = 0; i < n.actions.length; i++) {
                                    if (n.actions[i].identifier === "default") {
                                        n.actions[i].invoke();
                                        break;
                                    }
                                }
                            }
                            Qt.callLater(function() { popupWindow.removeNotif(delegateRoot.popupUid); });
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: popupCard.radius
                            color: _theme.surface0
                            opacity: parent.containsMouse ? 0.3 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 250 } }
                        }
                    }

                    ColumnLayout {
                        id: contentCol
                        z: 1
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: popupWindow.layoutConfig.padding
                        spacing: 6 * popupWindow.uiScale

                        Text {
                            text: model.appName || "System"
                            // App names/summaries are plain strings per the spec —
                            // never parse sender-controlled text as markup. (The
                            // body below keeps StyledText deliberately: body markup
                            // IS part of the notification spec.)
                            textFormat: Text.PlainText
                            font.family: "JetBrains Mono"
                            font.weight: Font.Medium
                            font.pixelSize: 12 * popupWindow.uiScale
                            color: _theme.overlay1
                            Layout.fillWidth: true
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: hiddenSummary.implicitHeight

                            Text {
                                id: hiddenSummary
                                text: delegateRoot.fullSummary
                                // Must match the visible twin's format or the
                                // measured height can diverge from what renders.
                                textFormat: Text.PlainText
                                width: parent.width
                                font.family: "JetBrains Mono"
                                font.weight: Font.Bold
                                font.pixelSize: 15 * popupWindow.uiScale
                                wrapMode: Text.Wrap
                                visible: false
                            }

                            Text {
                                anchors.fill: parent
                                text: delegateRoot.fullSummary.substring(0, delegateRoot.typeLenSum)
                                textFormat: Text.PlainText
                                font: hiddenSummary.font
                                color: _theme.text
                                wrapMode: Text.Wrap
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: hiddenBody.implicitHeight
                            visible: delegateRoot.fullBody !== ""

                            Text {
                                id: hiddenBody
                                text: delegateRoot.fullBody
                                width: parent.width
                                font.family: "JetBrains Mono"
                                font.weight: Font.Medium
                                font.pixelSize: 13 * popupWindow.uiScale
                                wrapMode: Text.Wrap
                                textFormat: Text.StyledText
                                visible: false
                            }

                            Text {
                                anchors.fill: parent
                                text: delegateRoot.fullBody.substring(0, delegateRoot.typeLenBody)
                                font: hiddenBody.font
                                color: _theme.subtext0
                                wrapMode: Text.Wrap
                                textFormat: Text.StyledText
                            }
                        }

                        // --- INLINE ACTION BUTTONS ---
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: delegateRoot.actionArray.length > 0 ? (6 * popupWindow.uiScale) : 0
                            spacing: 8 * popupWindow.uiScale
                            visible: delegateRoot.actionArray.length > 0

                            Repeater {
                                model: delegateRoot.actionArray
                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 32 * popupWindow.uiScale
                                    radius: 8 * popupWindow.uiScale

                                    property bool isPrimary: index === 0

                                    color: {
                                        if (!_theme.blue) return "transparent";
                                        if (isPrimary) {
                                            return actionMouseArea.containsMouse ? _theme.blue : Qt.darker(_theme.blue, 1.2)
                                        } else {
                                            return actionMouseArea.containsMouse ? _theme.surface2 : _theme.surface1
                                        }
                                    }

                                    border.color: (!_theme.blue) ? "transparent" : (isPrimary ? _theme.blue : _theme.surface2)
                                    border.width: 1

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.text || "Action"
                                        font.family: "JetBrains Mono"
                                        font.weight: Font.Bold
                                        font.pixelSize: 12 * popupWindow.uiScale
                                        color: isPrimary ? _theme.crust : _theme.text
                                    }

                                    MouseArea {
                                        id: actionMouseArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        z: 10

                                        onClicked: {
                                            // modelData.id is from our own JSON (key "id") — correct
                                            // n.actions[i].identifier is the QObject property — correct
                                            var n = popupWindow.getNotif(delegateRoot.popupUid);
                                            if (n && n.actions) {
                                                for (var i = 0; i < n.actions.length; i++) {
                                                    if (n.actions[i].identifier === modelData.id) {
                                                        n.actions[i].invoke();
                                                        break;
                                                    }
                                                }
                                            }
                                            Qt.callLater(function() { popupWindow.removeNotif(delegateRoot.popupUid); });
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
}
