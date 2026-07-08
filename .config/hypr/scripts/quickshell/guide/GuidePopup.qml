import QtQuick
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../"

Item {
    id: root
    focus: true

    // Main.qml passes these to every widget it creates/reopens; unused here but
    // declared so the assignments don't raise "non-existent property" errors.
    property var notifModel
    property var liveNotifs
    property real layoutWidth: 0
    property real layoutHeight: 0

    Caching { id: paths }

    // --- Responsive Scaling Logic ---
    Scaler {
        id: scaler
        currentWidth: Screen.width
    }
    
    function s(val) { 
        return scaler.s(val); 
    }

    // --- Helper Functions ---
    function formatBytes(bytes) {
        if (bytes === 0 || isNaN(bytes)) return '0 B';
        var k = 1024;
        var sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        var i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
    }

    // -------------------------------------------------------------------------
    // KEYBOARD SHORTCUTS & NAVIGATION
    // -------------------------------------------------------------------------
    Keys.onEscapePressed: {
        closeSequence.start();
        event.accepted = true;
    }
    Keys.onTabPressed: {
        let next = (currentTab + 1) % tabNames.length;
        if (next === 0) next = 1; // Skip Settings Tab visually
        currentTab = next;
        event.accepted = true;
    }
    Keys.onBacktabPressed: {
        let prev = (currentTab - 1 + tabNames.length) % tabNames.length;
        if (prev === 0) prev = tabNames.length - 1; // Skip Settings Tab visually
        currentTab = prev;
        event.accepted = true;
    }
    Keys.onLeftPressed: {
        if (currentTab === 2) { 
            if (selectedModuleIndex > 0) {
                selectedModuleIndex--;
                modulesList.positionViewAtIndex(selectedModuleIndex, ListView.Contain);
            }
            event.accepted = true;
        }
    }
    Keys.onRightPressed: {
        if (currentTab === 2) { 
            if (selectedModuleIndex < modulesDataModel.count - 1) {
                selectedModuleIndex++;
                modulesList.positionViewAtIndex(selectedModuleIndex, ListView.Contain);
            }
            event.accepted = true;
        }
    }
    Keys.onReturnPressed: {
        if (currentTab === 2) { 
            let target = modulesDataModel.get(selectedModuleIndex).target;
            Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "toggle", target]);
            event.accepted = true;
        }
    }
    Keys.onEnterPressed: { Keys.onReturnPressed(event); }

    MatugenColors { id: _theme }
    // -------------------------------------------------------------------------
    // COLORS
    // -------------------------------------------------------------------------
    readonly property color base: _theme.base
    readonly property color mantle: _theme.mantle
    readonly property color crust: _theme.crust
    readonly property color text: _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color subtext1: _theme.subtext1
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color overlay0: _theme.overlay0
    readonly property color mauve: _theme.mauve
    readonly property color pink: _theme.pink
    readonly property color blue: _theme.blue
    readonly property color sapphire: _theme.sapphire
    readonly property color green: _theme.green
    readonly property color peach: _theme.peach
    readonly property color yellow: _theme.yellow
    readonly property color red: _theme.red

    // ── Shared ambient clock ──
    // The ambient colour blend (30s cosine), background orb sweep (20s) and the
    // avatar ring rotation (15s) were each a per-frame animation that kept the
    // render loop at full frame rate the whole time the popup was open. One
    // 50ms wall-clock timer now drives all three as exact-waveform bindings —
    // every step is sub-pixel / sub-percent, so 20fps sampling looks identical.
    property real ambientPhase: 0
    property real _ambientLast: 0
    Timer {
        // 10fps: the fastest ambient motion here (orb sweep) moves under 5px per
        // 100ms step on an 800px heavily-blurred orb — still sub-perceptual, and
        // this scene is expensive to repaint (blurred orbs + MultiEffect avatar).
        interval: 100; repeat: true; running: root.visible
        onTriggered: {
            var n = Date.now();
            if (root._ambientLast > 0) root.ambientPhase += Math.min(200, n - root._ambientLast);
            root._ambientLast = n;
        }
        onRunningChanged: root._ambientLast = 0
    }
    // Two InOutSine halves (0→1 over 15s, 1→0 over 15s) compose into one cosine.
    readonly property real colorBlend: (1 - Math.cos(2 * Math.PI * ambientPhase / 30000)) / 2
    // The big ambient orbs are layer.enabled + MultiEffect-blurred: a COLOUR
    // change re-renders (re-blurs) each huge layer, and their colours blend off
    // the ambient clock — that re-blurred three ~900px gaussian passes every
    // tick (~19ms of CPU per frame). The orbs use this 16-step quantized blend
    // instead: the layer re-blurs ~once a second, and a 1/16 colour step on a
    // 4–15%-opacity blob is far below perception. Positions still glide every
    // tick — moving a cached layer is free. Borders/text keep the smooth blend.
    readonly property real orbBlend: Math.round(colorBlend * 16) / 16
    readonly property color orbPurple: Qt.tint(root.mauve, Qt.rgba(root.pink.r, root.pink.g, root.pink.b, orbBlend))
    readonly property color orbBlue: Qt.tint(root.blue, Qt.rgba(root.sapphire.r, root.sapphire.g, root.sapphire.b, orbBlend))
    
    property color ambientPurple: Qt.tint(root.mauve, Qt.rgba(root.pink.r, root.pink.g, root.pink.b, colorBlend))
    property color ambientBlue: Qt.tint(root.blue, Qt.rgba(root.sapphire.r, root.sapphire.g, root.sapphire.b, colorBlend))

    // -------------------------------------------------------------------------
    // GLOBALS
    // -------------------------------------------------------------------------
    property string dotsVersion: "Loading..."

    Process {
        id: versionReader
        command: ["bash", "-c", "source ~/.local/state/imperative-dots-version 2>/dev/null && echo $LOCAL_VERSION || echo 'Unknown'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                let out = this.text ? this.text.trim() : "";
                if (out !== "") root.dotsVersion = out;
            }
        }
    }

    // -------------------------------------------------------------------------
    // SYSTEM INFO PROPERTIES & FETCHER (CACHED)
    // -------------------------------------------------------------------------
    property string sysUser: "Loading..."
    property string sysHost: "Loading..."
    property string sysOS: "Loading..."
    property string sysKernel: "Loading..."
    property string sysCPU: "Loading..."
    property string sysGPU: "Loading..."
    property string faceIconPath: ""
    property string sysUptime: "Loading..."

    Process {
        id: sysInfoProc
        running: true
        command: [
            "bash", "-c",
            "CACHE=\"" + paths.getCacheDir("guide") + "/sysinfo.txt\"; " +
            "if [ ! -f \"$CACHE\" ]; then " +
            "  ICON=\"\"; if [ -f ~/.face.icon ]; then ICON=$(readlink -f ~/.face.icon); elif [ -f ~/.face ]; then ICON=$(readlink -f ~/.face); fi; " +
            "  echo \"$(whoami)|$(hostname)|$(uname -r)|$(cat /etc/os-release | grep '^PRETTY_NAME=' | cut -d'=' -f2 | tr -d '\\\"')|$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2 | xargs)|$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | tail -n1 | cut -d':' -f3 | xargs)|$ICON\" > \"$CACHE\"; " +
            "fi; " +
            "cat \"$CACHE\""
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                let line = this.text ? this.text.trim() : "";
                let parts = line.split("|");
                if (parts.length >= 6) {
                    root.sysUser = parts[0];
                    root.sysHost = parts[1];
                    root.sysKernel = parts[2];
                    root.sysOS = parts[3];
                    root.sysCPU = parts[4];
                    root.sysGPU = parts[5] ? parts[5] : "Integrated Graphics";
                    if (parts.length >= 7 && parts[6].trim() !== "") root.faceIconPath = parts[6].trim();
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // STATE MANAGEMENT & DATA
    // -------------------------------------------------------------------------
    property int currentTab: 1
    property int selectedModuleIndex: 0
    property var tabNames: ["Settings", "System", "Modules", "Matugen", "About"]
    property var tabIcons: ["", "", "󰣆", "󰏘", ""]

    property real introBase: 0.0
    property real introSidebar: 0.0
    property real introContent: 0.0

    ListModel {
        id: modulesDataModel
        ListElement { title: "Calendar & Weather"; target: "calendar"; icon: ""; desc: "Dual-sync calendar with live \nOpenWeatherMap integration."; preview: "previews/preview_calendar.png" }
        ListElement { title: "Media & Lyrics"; target: "music"; icon: "󰎆"; desc: "PlayerCtl integration, Cava \nvisualizer, and live lyrics."; preview: "previews/preview_music.png" }
        ListElement { title: "Battery & Power"; target: "battery"; icon: "󰁹"; desc: "Uptime tracking, power profiles, \nand battery health metrics."; preview: "previews/preview_battery.png" }
        ListElement { title: "Network Hub"; target: "network"; icon: "󰤨"; desc: "Wi-Fi and Bluetooth connection \nmanagement via nmcli/bluez."; preview: "previews/preview_network.png" }
        ListElement { title: "FocusTime"; target: "focustime"; icon: "󰄉"; desc: "Built-in Pomodoro timer daemon \nwith session tracking."; preview: "previews/preview_focustime.png" }
        ListElement { title: "Wallpaper Picker"; target: "wallpaper"; icon: ""; desc: "Live awww backend rendering \nwith Matugen color generation."; preview: "previews/preview_wallpaper.png" }
        ListElement { title: "Monitors"; target: "monitors"; icon: "󰍹"; desc: "Quick display management."; preview: "previews/preview_monitors.png" }
        ListElement { title: "Athena"; target: "athena"; icon: "󰚩"; desc: "Voice conversation with Hermes.\nPress Super+G to talk (push-to-talk)."; preview: "previews/preview_stewart.png" }
    }

    Component.onCompleted: { 
        startupSequence.start(); 
    }

    ParallelAnimation {
        id: startupSequence
        NumberAnimation { 
            target: root
            property: "introBase"
            from: 0.0
            to: 1.0
            duration: 900
            easing.type: Easing.OutExpo 
        }
        SequentialAnimation { 
            PauseAnimation { duration: 150 }
            NumberAnimation { 
                target: root
                property: "introSidebar"
                from: 0.0
                to: 1.0
                duration: 1000
                easing.type: Easing.OutBack
                easing.overshoot: 1.05 
            } 
        }
        SequentialAnimation { 
            PauseAnimation { duration: 250 }
            NumberAnimation { 
                target: root
                property: "introContent"
                from: 0.0
                to: 1.0
                duration: 1100
                easing.type: Easing.OutBack
                easing.overshoot: 1.02 
            } 
        }
    }

    SequentialAnimation {
        id: closeSequence
        ParallelAnimation { 
            NumberAnimation { 
                target: root
                property: "introContent"
                to: 0.0
                duration: 150
                easing.type: Easing.InExpo 
            }
            NumberAnimation { 
                target: root
                property: "introSidebar"
                to: 0.0
                duration: 150
                easing.type: Easing.InExpo 
            } 
        }
        NumberAnimation { 
            target: root
            property: "introBase"
            to: 0.0
            duration: 200
            easing.type: Easing.InQuart 
        }
        ScriptAction { 
            script: Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "close"]) 
        }
    }

    // -------------------------------------------------------------------------
    // BACKGROUND AMBIENCE (Enhanced with more/bigger orbs)
    // -------------------------------------------------------------------------
    Item {
        anchors.fill: parent
        opacity: introBase
        scale: 0.95 + (0.05 * introBase)
        
        Rectangle {
            anchors.fill: parent
            radius: root.s(16)
            color: root.base
            border.color: root.surface0
            border.width: 1
            clip: true
            
            // One revolution per 20s off the shared ambient clock (was its own
            // per-frame NumberAnimation).
            readonly property real time: (root.ambientPhase % 20000) / 20000 * Math.PI * 2
            
            // Orb 1
            Rectangle {
                width: root.s(800)
                height: root.s(800)
                radius: root.s(400)
                x: parent.width * 0.5 + Math.cos(parent.time) * root.s(150)
                y: parent.height * 0.1 + Math.sin(parent.time * 1.5) * root.s(150)
                color: root.orbPurple
                opacity: 0.06
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blurMax: 100; blur: 1.0 }
            }
            
            // Orb 2
            Rectangle {
                width: root.s(900)
                height: root.s(900)
                radius: root.s(450)
                x: parent.width * 0.1 + Math.sin(parent.time * 0.8) * root.s(200)
                y: parent.height * 0.4 + Math.cos(parent.time * 1.2) * root.s(150)
                color: root.orbBlue
                opacity: 0.05
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blurMax: 110; blur: 1.0 }
            }

            // Orb 3
            Rectangle {
                width: root.s(700)
                height: root.s(700)
                radius: root.s(350)
                x: parent.width * 0.3 + Math.cos(parent.time * 1.1) * root.s(120)
                y: parent.height * 0.6 + Math.sin(parent.time * 0.9) * root.s(180)
                color: Qt.tint(root.peach, Qt.rgba(root.yellow.r, root.yellow.g, root.yellow.b, orbBlend))
                opacity: 0.04
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blurMax: 90; blur: 1.0 }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MAIN LAYOUT
    // -------------------------------------------------------------------------
    RowLayout {
        anchors.fill: parent
        anchors.margins: root.s(20)
        spacing: root.s(20)

        // ==========================================
        // SIDEBAR
        // ==========================================
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: root.s(220)
            radius: root.s(12)
            color: Qt.alpha(root.surface0, 0.4)
            border.color: root.surface1
            border.width: 1
            opacity: introSidebar
            transform: Translate { x: root.s(-30) * (1.0 - introSidebar) }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.s(15)
                spacing: root.s(10)
                
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.s(60)
                    
                    RowLayout {
                        anchors.fill: parent
                        spacing: root.s(12)
                        
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            width: root.s(36)
                            height: root.s(36)
                            radius: root.s(10)
                            color: root.ambientPurple
                            Text { 
                                anchors.centerIn: parent
                                text: "󰣇"
                                font.family: "Iosevka Nerd Font"
                                font.pixelSize: root.s(20)
                                color: root.base 
                            }
                        }
                        
                        ColumnLayout {
                            Layout.alignment: Qt.AlignVCenter
                            spacing: root.s(2)
                            Text { 
                                text: "Imperative"
                                font.family: "JetBrains Mono"
                                font.weight: Font.Black
                                font.pixelSize: root.s(15)
                                color: root.text
                                Layout.alignment: Qt.AlignLeft 
                            }
                            Text { 
                                text: "v" + (root.dotsVersion !== "Loading..." ? root.dotsVersion : "...")
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"
                                font.pixelSize: root.s(11)
                                color: root.subtext0
                                Layout.alignment: Qt.AlignLeft 
                            }
                        }
                    }
                }

                Rectangle { 
                    Layout.fillWidth: true
                    height: 1
                    color: Qt.alpha(root.surface1, 0.5)
                    Layout.bottomMargin: root.s(10) 
                }

                // --- MORPHING TABS LOGIC ---
                Item {
                    Layout.fillWidth: true
                    // Dynamically set height based on elements: (Tabs count * 44) + 1 Divider (21)
                    Layout.preferredHeight: root.s(65) + (root.tabNames.length - 1) * root.s(44)

                    // The Morphing Highlight Background
                    Rectangle {
                        id: activeHighlight
                        width: parent.width
                        height: root.s(44)
                        radius: root.s(8)
                        color: root.mauve
                        z: 0

                        property int curIdx: root.currentTab
                        // Index 0 starts at 0. Index 1 starts after Index 0 (44) and Divider (21) = 65
                        property real targetY: curIdx === 0 ? 0 : root.s(65) + (curIdx - 1) * root.s(44)
                        y: targetY

                        Behavior on y {
                            NumberAnimation { duration: 400; easing.type: Easing.OutExpo }
                        }
                    }

                    Column {
                        anchors.fill: parent
                        spacing: 0
                        
                        Repeater {
                            model: root.tabNames.length
                            
                            Column {
                                width: parent.width

                                Rectangle {
                                    width: parent.width
                                    height: root.s(44)
                                    radius: root.s(8)
                                    z: 1
                                    
                                    property bool isActive: root.currentTab === index
                                    // Make it transparent if active so the highlight shows through
                                    color: isActive ? "transparent" : (tabMa.containsMouse ? Qt.alpha(root.surface1, 0.5) : "transparent")
                                    
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: root.s(15)
                                        spacing: root.s(12)

                                        // The "Slide Right" text effect from snippet 2.
                                        // Qualified via id: unqualified lookup in a Translate
                                        // skips intermediate ancestors (threw ReferenceError).
                                        id: tabRowContent
                                        property real contentShift: parent.isActive ? root.s(6) : 0
                                        Behavior on contentShift { NumberAnimation { duration: 400; easing.type: Easing.OutExpo } }
                                        transform: Translate { x: tabRowContent.contentShift }
                                        
                                        Item {
                                            Layout.preferredWidth: root.s(24)
                                            Layout.alignment: Qt.AlignVCenter
                                            Text { 
                                                anchors.centerIn: parent
                                                text: root.tabIcons[index]
                                                font.family: "Iosevka Nerd Font"
                                                font.pixelSize: root.s(18)
                                                // Dynamic colors (crust vs subtext0) for contrast
                                                color: parent.parent.parent.isActive ? root.crust : root.subtext0
                                                Behavior on color { ColorAnimation { duration: 150 } } 
                                            }
                                        }
                                        
                                        Text { 
                                            text: root.tabNames[index]
                                            font.family: "JetBrains Mono"
                                            font.weight: parent.parent.isActive ? Font.Bold : Font.Medium
                                            font.pixelSize: root.s(13)
                                            // Dynamic colors (crust vs subtext0) for contrast
                                            color: parent.parent.isActive ? root.crust : root.subtext0
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            Behavior on color { ColorAnimation { duration: 150 } } 
                                        }
                                    }
                                    
                                    MouseArea { 
                                        id: tabMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (index === 0) {
                                                Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "toggle", "settings"]);
                                            } else {
                                                root.currentTab = index;
                                            }
                                        } 
                                    }
                                }
                                
                                // Divider natively wrapped to provide spacing
                                Item {
                                    visible: index === 0
                                    width: parent.width
                                    height: root.s(21) // 10 top + 1 mid + 10 bot
                                    
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: parent.width
                                        height: 1
                                        color: Qt.alpha(root.surface1, 0.5)
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                // --- CLOSE BUTTON ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.s(44)
                    radius: root.s(8)
                    color: closeHover.containsMouse ? Qt.alpha(root.red, 0.1) : "transparent"
                    border.color: closeHover.containsMouse ? root.red : root.surface1
                    border.width: 1
                    scale: closeHover.pressed ? 0.95 : (closeHover.containsMouse ? 1.02 : 1.0)
                    
                    Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    Item {
                        anchors.centerIn: parent
                        width: arrowText.implicitWidth
                        height: arrowText.implicitHeight
                        Text { 
                            id: arrowText
                            text: ""
                            font.family: "Iosevka Nerd Font"
                            font.pixelSize: root.s(16)
                            color: closeHover.containsMouse ? root.red : root.subtext0
                            Behavior on color { ColorAnimation { duration: 150 } } 
                        }
                    }
                    MouseArea { 
                        id: closeHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: closeSequence.start() 
                    }
                }
            }
        }

        // ==========================================
        // CONTENT AREA
        // ==========================================
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            opacity: introContent
            scale: 0.95 + (0.05 * introContent)
            transform: Translate { y: root.s(20) * (1.0 - introContent) }

            // ------------------------------------------
            // TAB 1: SYSTEM OVERVIEW
            // ------------------------------------------
            Item {
                anchors.fill: parent
                visible: root.currentTab === 1
                opacity: visible ? 1.0 : 0.0
                id: slidePage1
                property real slideY: visible ? 0 : root.s(10)
                
                Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                transform: Translate { y: slidePage1.slideY }
                Behavior on opacity { NumberAnimation { duration: 250 } }

                ListModel {
                    id: systemDataModel
                    ListElement { pkg: "Hyprland"; role: "Wayland Compositor"; icon: ""; clr: "blue"; link: "https://hyprland.org/" }
                    ListElement { pkg: "Quickshell"; role: "UI Framework"; icon: "󰣆"; clr: "mauve"; link: "https://git.outfoxxed.me/outfoxxed/quickshell" }
                    ListElement { pkg: "Matugen"; role: "Theme Engine"; icon: "󰏘"; clr: "peach"; link: "https://github.com/InioX/matugen" }
                    ListElement { pkg: "Rofi Wayland"; role: "App Launcher"; icon: ""; clr: "green"; link: "https://github.com/lbonn/rofi" }
                    ListElement { pkg: "Kitty"; role: "Terminal Emulator"; icon: "󰄛"; clr: "yellow"; link: "https://sw.kovidgoyal.net/kitty/" }
                    ListElement { pkg: "SwayOSD / NC"; role: "Overlays & Notifs"; icon: "󰂚"; clr: "pink"; link: "https://github.com/ErikReider/SwayOSD" }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: root.s(15)
                    anchors.leftMargin: root.s(20)
                    anchors.rightMargin: root.s(20)
                    anchors.bottomMargin: root.s(20)
                    spacing: root.s(20)

                    // ENHANCED DEVICE INFO BLOCK
                    Rectangle {
                        id: sysBox
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.s(180)
                        radius: root.s(16)
                        color: sysBoxMa.containsMouse ? Qt.alpha(root.surface0, 0.7) : Qt.alpha(root.surface0, 0.4)
                        border.color: sysBoxMa.containsMouse ? root.ambientBlue : root.surface1
                        border.width: 1
                        clip: true
                        
                        Behavior on color { ColorAnimation { duration: 300 } }
                        Behavior on border.color { ColorAnimation { duration: 300 } }

                        Rectangle {
                            width: root.s(250)
                            height: root.s(250)
                            radius: root.s(125)
                            color: root.orbBlue
                            opacity: 0.15
                            x: sysBoxMa.containsMouse ? parent.width * 0.7 : parent.width * 0.8
                            y: -root.s(50)
                            layer.enabled: true
                            layer.effect: MultiEffect { blurEnabled: true; blurMax: 80; blur: 1.0 }
                            Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutExpo } }
                        }
                        
                        Rectangle {
                            width: root.s(200)
                            height: root.s(200)
                            radius: root.s(100)
                            color: root.orbPurple
                            opacity: 0.15
                            x: sysBoxMa.containsMouse ? root.s(50) : -root.s(50)
                            y: root.s(20)
                            layer.enabled: true
                            layer.effect: MultiEffect { blurEnabled: true; blurMax: 80; blur: 1.0 }
                            Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutExpo } }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: root.s(20)
                            spacing: root.s(30)

                            Item {
                                Layout.preferredWidth: root.s(100)
                                Layout.preferredHeight: root.s(100)
                                
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: root.s(100)
                                    height: root.s(100)
                                    radius: root.s(50)
                                    color: "transparent"
                                    border.color: Qt.alpha(root.ambientPurple, sysBoxMa.containsMouse ? 0.8 : 0.3)
                                    border.width: root.s(3)
                                    scale: sysBoxMa.containsMouse ? 1.05 : 1.0
                                    
                                    Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }
                                    Behavior on border.color { ColorAnimation { duration: 300 } }
                                    
                                    // 360°/15s off the shared ambient clock (was a
                                    // per-frame RotationAnimation).
                                    rotation: (root.ambientPhase % 15000) / 15000 * 360
                                }
                                
                                Item {
                                    anchors.centerIn: parent
                                    width: root.s(84)
                                    height: root.s(84)
                                    
                                    Rectangle { 
                                        id: avatarMaskTab0
                                        anchors.fill: parent
                                        radius: width / 2
                                        color: "black"
                                        visible: false
                                        layer.enabled: true 
                                    }
                                    
                                    Image {
                                        id: userAvatarImg
                                        anchors.fill: parent
                                        source: root.faceIconPath !== "" ? "file://" + root.faceIconPath.replace("file://", "") : ""
                                        fillMode: Image.PreserveAspectCrop
                                        visible: false
                                        asynchronous: true
                                        smooth: true
                                        mipmap: true
                                    }
                                    
                                    MultiEffect { 
                                        source: userAvatarImg
                                        anchors.fill: userAvatarImg
                                        maskEnabled: true
                                        maskSource: avatarMaskTab0
                                        visible: root.faceIconPath !== "" 
                                    }
                                    
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: width / 2
                                        color: root.faceIconPath === "" ? root.surface0 : "transparent"
                                        border.color: root.surface2
                                        border.width: 1
                                        Text { 
                                            anchors.centerIn: parent
                                            text: ""
                                            font.family: "Iosevka Nerd Font"
                                            font.pixelSize: root.s(42)
                                            color: root.text
                                            visible: root.faceIconPath === ""
                                            scale: sysBoxMa.containsMouse ? 1.1 : 1.0
                                            Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: root.s(8)
                                
                                Text { 
                                    text: root.sysUser
                                    font.family: "JetBrains Mono"
                                    font.weight: Font.Black
                                    font.pixelSize: root.s(24)
                                    color: root.text 
                                }
                                
                                Text { 
                                    text: "@" + root.sysHost
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: root.s(14)
                                    color: root.subtext0 
                                }
                                
                                Rectangle { 
                                    Layout.fillWidth: true
                                    height: 1
                                    color: Qt.alpha(root.surface1, 0.5)
                                    Layout.topMargin: root.s(5)
                                    Layout.bottomMargin: root.s(5) 
                                }

                                RowLayout {
                                    spacing: root.s(15)
                                    RowLayout { 
                                        spacing: root.s(6)
                                        Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root.blue } 
                                        Text { text: root.sysOS; font.family: "JetBrains Mono"; font.weight: Font.Medium; font.pixelSize: root.s(12); color: root.subtext0 } 
                                    }
                                    RowLayout { 
                                        spacing: root.s(6)
                                        Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root.peach } 
                                        Text { text: root.sysKernel; font.family: "JetBrains Mono"; font.weight: Font.Medium; font.pixelSize: root.s(12); color: root.subtext0 } 
                                    }
                                }
                                
                                RowLayout {
                                    spacing: root.s(15)
                                    RowLayout { 
                                        spacing: root.s(6)
                                        Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root.green } 
                                        Text { 
                                            text: root.sysCPU
                                            font.family: "JetBrains Mono"
                                            font.weight: Font.Medium
                                            font.pixelSize: root.s(12)
                                            color: root.subtext0
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: root.s(220) 
                                        } 
                                    }
                                    RowLayout { 
                                        spacing: root.s(6)
                                        Text { text: "󰢮"; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root.yellow } 
                                        Text { 
                                            text: root.sysGPU
                                            font.family: "JetBrains Mono"
                                            font.weight: Font.Medium
                                            font.pixelSize: root.s(12)
                                            color: root.subtext0
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: root.s(220) 
                                        } 
                                    }
                                }
                            }
                        }
                        MouseArea { id: sysBoxMa; anchors.fill: parent; hoverEnabled: true }
                    }

                    // AUTHOR BLOCK
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.s(50)
                        radius: root.s(10)
                        color: authorMa.containsMouse ? Qt.alpha(root.surface1, 0.6) : Qt.alpha(root.surface0, 0.4)
                        border.color: authorMa.containsMouse ? root.mauve : root.surface1
                        border.width: 1
                        scale: authorMa.pressed ? 0.98 : (authorMa.containsMouse ? 1.01 : 1.0)
                        
                        Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }

                        RowLayout {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: root.s(12)
                            spacing: root.s(15)
                            
                            Rectangle { 
                                Layout.alignment: Qt.AlignVCenter
                                width: root.s(32)
                                height: root.s(32)
                                radius: root.s(8)
                                color: root.surface0
                                border.color: root.surface2
                                border.width: 1
                                Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(20); color: root.text } 
                            }
                            
                            Row {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: root.s(1)
                                Repeater {
                                    model: [ { l: "i", c: root.red }, { l: "l", c: root.peach }, { l: "y", c: root.yellow }, { l: "a", c: root.green }, { l: "m", c: root.sapphire }, { l: "i", c: root.blue }, { l: "r", c: root.mauve }, { l: "o", c: root.pink } ]
                                    Text { 
                                        text: modelData.l
                                        font.family: "JetBrains Mono"
                                        font.weight: Font.Black
                                        font.pixelSize: root.s(14)
                                        color: modelData.c
                                        property real hoverOffset: authorMa.containsMouse ? root.s(-3) : 0
                                        transform: Translate { y: hoverOffset }
                                        Behavior on hoverOffset { NumberAnimation { duration: 300 + (index * 35); easing.type: Easing.OutBack } } 
                                    }
                                }
                            }
                            
                            Item { Layout.fillWidth: true }
                            
                            Rectangle { 
                                Layout.alignment: Qt.AlignVCenter
                                width: root.s(28)
                                height: root.s(28)
                                radius: root.s(6)
                                color: authorMa.containsMouse ? root.surface1 : "transparent"
                                Text { 
                                    anchors.centerIn: parent
                                    text: ""
                                    font.family: "Iosevka Nerd Font"
                                    font.pixelSize: root.s(14)
                                    color: authorMa.containsMouse ? root.mauve : root.subtext0
                                    Behavior on color { ColorAnimation { duration: 150 } } 
                                } 
                            }
                        }
                        MouseArea { 
                            id: authorMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/ilyamiro/nixos-configuration"]) 
                        }
                    }

                    // MODULES AND QUICK LINKS ROW
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.s(15)
                        
                        Repeater {
                            model: [ 
                                { name: "Settings", icon: "", color: "mauve", targetTab: 0, isToggle: true }, 
                                { name: "Modules", icon: "󰣆", color: "blue", targetTab: 2, isToggle: false } 
                            ]
                            
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.s(44)
                                radius: root.s(8)
                                color: navBtnMa.containsMouse ? Qt.alpha(root[modelData.color], 0.15) : Qt.alpha(root.surface0, 0.4)
                                border.color: navBtnMa.containsMouse ? root[modelData.color] : root.surface1
                                border.width: 1
                                scale: navBtnMa.pressed ? 0.95 : 1.0
                                
                                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutQuart } }
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Behavior on border.color { ColorAnimation { duration: 200 } }
                                
                                RowLayout { 
                                    anchors.centerIn: parent
                                    spacing: root.s(10)
                                    Text { text: modelData.icon; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root[modelData.color] } 
                                    Text { text: modelData.name; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: root.s(13); color: root.text } 
                                }
                                
                                MouseArea { 
                                    id: navBtnMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (modelData.isToggle) {
                                            Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "toggle", "settings"]);
                                        } else {
                                            root.currentTab = modelData.targetTab;
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text { 
                        text: "System Architecture"
                        font.family: "JetBrains Mono"
                        font.weight: Font.Black
                        font.pixelSize: root.s(24)
                        color: root.text
                        Layout.alignment: Qt.AlignVCenter
                        Layout.topMargin: root.s(5) 
                    }
                    
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        rowSpacing: root.s(15)
                        columnSpacing: root.s(15)
                        
                        Repeater {
                            model: systemDataModel
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.s(60)
                                radius: root.s(10)
                                color: sysCardMa.containsMouse ? Qt.alpha(root[model.clr], 0.1) : Qt.alpha(root.surface0, 0.4)
                                border.color: sysCardMa.containsMouse ? root[model.clr] : root.surface1
                                border.width: 1
                                scale: sysCardMa.pressed ? 0.98 : 1.0
                                
                                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutQuart } }
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Behavior on border.color { ColorAnimation { duration: 200 } }
                                
                                Item {
                                    anchors.fill: parent
                                    anchors.margins: root.s(10)
                                    
                                    Item { 
                                        id: sysIconBox
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: root.s(36)
                                        height: root.s(36)
                                        Text { anchors.centerIn: parent; text: model.icon; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(22); color: root[model.clr] } 
                                    }
                                    
                                    Column { 
                                        anchors.left: sysIconBox.right
                                        anchors.leftMargin: root.s(15)
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: root.s(2)
                                        Text { text: model.pkg; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: root.s(14); color: root.text } 
                                        Text { text: model.role; font.family: "JetBrains Mono"; font.pixelSize: root.s(11); color: root.subtext0 } 
                                    }
                                }
                                
                                MouseArea { 
                                    id: sysCardMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["xdg-open", model.link]) 
                                }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }

            // ------------------------------------------
            // TAB 2: MODULES
            // ------------------------------------------
            Item {
                anchors.fill: parent
                visible: root.currentTab === 2
                opacity: visible ? 1.0 : 0.0
                id: slidePage2
                property real slideY: visible ? 0 : root.s(10)
                
                Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                transform: Translate { y: slidePage2.slideY }
                Behavior on opacity { NumberAnimation { duration: 250 } }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: root.s(15)
                    anchors.leftMargin: root.s(20)
                    anchors.rightMargin: root.s(20)
                    anchors.bottomMargin: root.s(20)
                    spacing: root.s(20)

                    RowLayout {
                        Layout.fillWidth: true
                        
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: root.s(4)
                            Text { text: "Interactive Modules"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: root.s(28); color: root.text }
                            Text { text: "Use arrow keys or select below to preview. Double-click or press Enter to toggle."; font.family: "JetBrains Mono"; font.pixelSize: root.s(13); color: root.subtext0 }
                        }
                        
                        Item { Layout.fillWidth: true } 
                        
                        Rectangle {
                            Layout.preferredWidth: root.s(110)
                            Layout.preferredHeight: root.s(44)
                            radius: root.s(22)
                            color: launchMa.containsMouse ? Qt.alpha(root.ambientBlue, 0.9) : Qt.alpha(root.ambientBlue, 0.7)
                            border.color: root.ambientBlue
                            border.width: 1
                            scale: launchMa.pressed ? 0.95 : (launchMa.containsMouse ? 1.05 : 1.0)
                            
                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                            Behavior on color { ColorAnimation { duration: 150 } }
                            
                            RowLayout { 
                                anchors.centerIn: parent
                                spacing: root.s(8)
                                Text { text: "󰐊"; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(20); color: root.base } 
                                Text { text: "PLAY"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: root.s(14); color: root.base } 
                            }
                            
                            MouseArea { 
                                id: launchMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "toggle", modulesDataModel.get(root.selectedModuleIndex).target]) 
                            }
                        }
                    }

                    Rectangle {
                        id: previewContainer
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: root.s(12)
                        color: root.surface0
                        border.color: root.surface2
                        border.width: 1
                        clip: true
                        
                        property string targetSource: modulesDataModel.get(root.selectedModuleIndex).preview ? Qt.resolvedUrl(modulesDataModel.get(root.selectedModuleIndex).preview) : ""
                        
                        onTargetSourceChanged: { 
                            baseImage.source = overlayImage.source; 
                            overlayImage.opacity = 0.0; 
                            overlayImage.source = targetSource; 
                            fadeAnim.restart(); 
                        }
                        
                        Image { 
                            id: baseImage
                            anchors.fill: parent
                            anchors.margins: 0
                            // 1920x1080 source decoded at half size (~2x the pane) —
                            // same pixels on screen, a quarter of the texture memory.
                            sourceSize: Qt.size(960, 540)
                            fillMode: Image.PreserveAspectCrop
                            verticalAlignment: Image.AlignTop
                            horizontalAlignment: Image.AlignHCenter
                            smooth: true
                            mipmap: true
                            asynchronous: true 
                        }
                        
                        Image { 
                            id: overlayImage
                            anchors.fill: parent
                            anchors.margins: 0
                            sourceSize: Qt.size(960, 540)
                            fillMode: Image.PreserveAspectCrop
                            verticalAlignment: Image.AlignTop
                            horizontalAlignment: Image.AlignHCenter
                            smooth: true
                            mipmap: true
                            asynchronous: true
                            NumberAnimation on opacity { 
                                id: fadeAnim
                                to: 1.0
                                duration: 350
                                easing.type: Easing.InOutQuad 
                            } 
                        }
                    }

                    ListView {
                        id: modulesList
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.s(90)
                        orientation: ListView.Horizontal
                        spacing: root.s(15)
                        clip: true
                        model: modulesDataModel
                        currentIndex: root.selectedModuleIndex
                        highlightMoveDuration: 250
                        
                        delegate: Rectangle {
                            width: root.s(220)
                            height: root.s(90)
                            radius: root.s(12)
                            property bool isSelected: index === root.selectedModuleIndex
                            color: isSelected ? root.surface1 : (modMa.containsMouse ? Qt.alpha(root.surface1, 0.5) : Qt.alpha(root.surface0, 0.4))
                            border.color: isSelected ? root.ambientBlue : (modMa.containsMouse ? root.surface2 : root.surface1)
                            border.width: isSelected ? 2 : 1
                            scale: isSelected ? 1.0 : (modMa.pressed ? 0.96 : (modMa.containsMouse ? 1.02 : 1.0))
                            
                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                            Behavior on color { ColorAnimation { duration: 200 } }
                            Behavior on border.color { ColorAnimation { duration: 200 } }
                            
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.s(12)
                                spacing: root.s(5)
                                RowLayout { 
                                    spacing: root.s(10)
                                    Rectangle { 
                                        Layout.alignment: Qt.AlignVCenter
                                        width: root.s(28)
                                        height: root.s(28)
                                        radius: root.s(6)
                                        color: Qt.alpha(root.base, 0.5)
                                        Text { anchors.centerIn: parent; text: model.icon; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(14); color: isSelected ? root.ambientBlue : root.text } 
                                    } 
                                    Text { 
                                        text: model.title
                                        font.family: "JetBrains Mono"
                                        font.weight: Font.Bold
                                        font.pixelSize: root.s(12)
                                        color: root.text
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        elide: Text.ElideRight 
                                    } 
                                }
                                Text { 
                                    text: model.desc
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: root.s(10)
                                    color: root.subtext0
                                    Layout.alignment: Qt.AlignLeft
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideRight 
                                }
                            }
                            
                            MouseArea { 
                                id: modMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { 
                                    root.selectedModuleIndex = index; 
                                    modulesList.positionViewAtIndex(index, ListView.Contain); 
                                }
                                onDoubleClicked: { 
                                    root.selectedModuleIndex = index; 
                                    Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "toggle", model.target]) 
                                } 
                            }
                        }
                    }
                }
            }

            // ------------------------------------------
            // TAB 3: MATUGEN ENGINE
            // ------------------------------------------
            Item {
                anchors.fill: parent
                visible: root.currentTab === 3
                opacity: visible ? 1.0 : 0.0
                id: slidePage3
                property real slideY: visible ? 0 : root.s(10)
                
                Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                transform: Translate { y: slidePage3.slideY }
                Behavior on opacity { NumberAnimation { duration: 250 } }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: root.s(15)
                    anchors.leftMargin: root.s(20)
                    anchors.rightMargin: root.s(20)
                    anchors.bottomMargin: root.s(20)
                    spacing: root.s(20)

                    Text { text: "Theming Engine"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: root.s(28); color: root.text; Layout.alignment: Qt.AlignVCenter }
                    
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.s(160)
                        radius: root.s(12)
                        color: Qt.alpha(root.surface0, 0.4)
                        border.color: root.ambientPurple
                        border.width: 1
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: root.s(20)
                            spacing: root.s(20)
                            
                            Item { Layout.fillWidth: true } 
                            
                            ColumnLayout { 
                                Layout.alignment: Qt.AlignVCenter
                                spacing: root.s(8)
                                Rectangle { 
                                    Layout.alignment: Qt.AlignHCenter
                                    width: root.s(60)
                                    height: root.s(60)
                                    radius: root.s(10)
                                    color: root.surface1
                                    Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(28); color: root.text } 
                                } 
                                Text { text: "Wallpaper"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: root.s(12); color: root.text; Layout.alignment: Qt.AlignHCenter } 
                            }
                            
                            Item { 
                                Layout.preferredWidth: root.s(60)
                                Layout.preferredHeight: root.s(20)
                                Layout.alignment: Qt.AlignVCenter
                                Repeater { 
                                    model: 3
                                    Item { 
                                        width: parent.width
                                        height: parent.height
                                        Rectangle { 
                                            width: root.s(6)
                                            height: root.s(6)
                                            radius: root.s(3)
                                            color: [root.mauve, root.peach, root.blue][index]
                                            y: parent.height / 2 - root.s(3)
                                            SequentialAnimation on x { 
                                                loops: Animation.Infinite
                                                running: root.visible && root.currentTab === 3
                                                PauseAnimation { duration: index * 400 }
                                                NumberAnimation { from: 0; to: parent.width; duration: 1200; easing.type: Easing.InOutSine } 
                                            } 
                                            SequentialAnimation on opacity { 
                                                loops: Animation.Infinite
                                                running: root.visible && root.currentTab === 3
                                                PauseAnimation { duration: index * 400 }
                                                NumberAnimation { from: 0; to: 1; duration: 300 }
                                                PauseAnimation { duration: 600 }
                                                NumberAnimation { from: 1; to: 0; duration: 300 } 
                                            } 
                                        } 
                                    } 
                                } 
                            }
                            
                            Rectangle {
                                width: root.s(180)
                                height: root.s(90)
                                radius: root.s(12)
                                color: root.base
                                border.color: root.ambientPurple
                                Layout.alignment: Qt.AlignVCenter
                                
                                SequentialAnimation on border.width { 
                                    loops: Animation.Infinite
                                    running: root.visible && root.currentTab === 3
                                    NumberAnimation { from: root.s(1); to: root.s(4); duration: 1000; easing.type: Easing.InOutSine }
                                    NumberAnimation { from: root.s(4); to: root.s(1); duration: 1000; easing.type: Easing.InOutSine } 
                                }
                                
                                ColumnLayout { 
                                    anchors.centerIn: parent
                                    spacing: root.s(8)
                                    Text { text: "Matugen Core"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: root.s(15); color: root.ambientPurple; Layout.alignment: Qt.AlignHCenter } 
                                    RowLayout { 
                                        spacing: root.s(4)
                                        Layout.alignment: Qt.AlignHCenter
                                        Repeater { 
                                            model: [root.red, root.peach, root.yellow, root.green, root.blue, root.mauve]
                                            Rectangle { 
                                                Layout.alignment: Qt.AlignVCenter
                                                width: root.s(12)
                                                height: root.s(12)
                                                radius: root.s(6)
                                                color: modelData
                                                SequentialAnimation on scale { 
                                                    loops: Animation.Infinite
                                                    running: root.visible && root.currentTab === 3
                                                    PauseAnimation { duration: index * 150 }
                                                    NumberAnimation { to: 1.3; duration: 300; easing.type: Easing.OutQuart }
                                                    NumberAnimation { to: 1.0; duration: 400; easing.type: Easing.OutQuart }
                                                    PauseAnimation { duration: 1000 } 
                                                } 
                                            } 
                                        } 
                                    } 
                                } 
                            }
                            
                            Item { 
                                Layout.preferredWidth: root.s(60)
                                Layout.preferredHeight: root.s(20)
                                Layout.alignment: Qt.AlignVCenter
                                Repeater { 
                                    model: 3
                                    Item { 
                                        width: parent.width
                                        height: parent.height
                                        Rectangle { 
                                            width: root.s(6)
                                            height: root.s(6)
                                            radius: root.s(3)
                                            color: [root.green, root.yellow, root.pink][index]
                                            y: parent.height / 2 - root.s(3)
                                            SequentialAnimation on x { 
                                                loops: Animation.Infinite
                                                running: root.visible && root.currentTab === 3
                                                PauseAnimation { duration: index * 400 }
                                                NumberAnimation { from: 0; to: parent.width; duration: 1200; easing.type: Easing.InOutSine } 
                                            } 
                                            SequentialAnimation on opacity { 
                                                loops: Animation.Infinite
                                                running: root.visible && root.currentTab === 3
                                                PauseAnimation { duration: index * 400 }
                                                NumberAnimation { from: 0; to: 1; duration: 300 }
                                                PauseAnimation { duration: 600 }
                                                NumberAnimation { from: 1; to: 0; duration: 300 } 
                                            } 
                                        } 
                                    } 
                                } 
                            }
                            
                            ColumnLayout { 
                                Layout.alignment: Qt.AlignVCenter
                                spacing: root.s(8)
                                Rectangle { 
                                    Layout.alignment: Qt.AlignHCenter
                                    width: root.s(60)
                                    height: root.s(60)
                                    radius: root.s(10)
                                    color: root.surface1
                                    Text { anchors.centerIn: parent; text: "󰏘"; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(28); color: root.text } 
                                } 
                                Text { text: "Templates"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: root.s(12); color: root.text; Layout.alignment: Qt.AlignHCenter } 
                            }
                            Item { Layout.fillWidth: true } 
                        }
                    }

                    Text { text: "When you change wallpapers, Matugen extracts the dominant colors and injects them directly into these configuration files in real-time:"; font.family: "JetBrains Mono"; font.pixelSize: root.s(13); color: root.subtext0; Layout.fillWidth: true; wrapMode: Text.WordWrap; Layout.alignment: Qt.AlignVCenter }

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 3
                        rowSpacing: root.s(10)
                        columnSpacing: root.s(10)
                        
                        Repeater {
                            model: [ 
                                { f: "kitty-colors.conf", i: "󰄛", c: "yellow" }, 
                                { f: "nvim-colors.lua", i: "", c: "green" }, 
                                { f: "rofi.rasi", i: "", c: "blue" }, 
                                { f: "cava-colors.ini", i: "󰎆", c: "mauve" }, 
                                { f: "sddm-colors.qml", i: "󰍃", c: "peach" }, 
                                { f: "swaync/osd.css", i: "󰂚", c: "pink" } 
                            ]
                            
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.s(45)
                                radius: root.s(8)
                                color: tplMa.containsMouse ? Qt.alpha(root[modelData.c], 0.1) : root.surface0
                                border.color: tplMa.containsMouse ? root[modelData.c] : "transparent"
                                border.width: 1
                                
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                
                                RowLayout { 
                                    anchors.fill: parent
                                    anchors.margins: root.s(10)
                                    spacing: root.s(10)
                                    Item { 
                                        Layout.preferredWidth: root.s(24)
                                        Layout.alignment: Qt.AlignVCenter
                                        Text { anchors.centerIn: parent; text: modelData.i; font.family: "Iosevka Nerd Font"; font.pixelSize: root.s(16); color: root[modelData.c] } 
                                    } 
                                    Text { text: modelData.f; font.family: "JetBrains Mono"; font.weight: Font.Medium; font.pixelSize: root.s(12); color: root.text; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter } 
                                }
                                MouseArea { id: tplMa; anchors.fill: parent; hoverEnabled: true }
                            }
                        }
                    }
                }
            }

            // ------------------------------------------
            // TAB 4: ABOUT
            // ------------------------------------------
            Item {
                anchors.fill: parent
                visible: root.currentTab === 4
                opacity: visible ? 1.0 : 0.0
                id: slidePage4
                property real slideY: visible ? 0 : root.s(10)
                
                Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                transform: Translate { y: slidePage4.slideY }
                Behavior on opacity { NumberAnimation { duration: 250 } }

                RowLayout {
                    anchors.centerIn: parent
                    spacing: root.s(30)

                    Repeater {
                        model: [
                            { name: "NixOS Config", icon: "", color: "blue", url: "https://github.com/ilyamiro/nixos-configuration" },
                            { name: "Imperative Dots", icon: "󰣇", color: "mauve", url: "https://github.com/ilyamiro/imperative-dots" },
                            { name: "Wallpapers", icon: "", color: "peach", url: "https://github.com/ilyamiro/shell-wallpapers" }
                        ]

                        Rectangle {
                            Layout.preferredWidth: root.s(140)
                            Layout.preferredHeight: root.s(140)
                            radius: root.s(16)
                            color: repoMa.containsMouse ? Qt.alpha(root[modelData.color], 0.15) : Qt.alpha(root.surface0, 0.4)
                            border.color: repoMa.containsMouse ? root[modelData.color] : root.surface1
                            border.width: 1
                            scale: repoMa.pressed ? 0.95 : (repoMa.containsMouse ? 1.05 : 1.0)

                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                            Behavior on color { ColorAnimation { duration: 200 } }
                            Behavior on border.color { ColorAnimation { duration: 200 } }

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: root.s(15)

                                Text {
                                    text: modelData.icon
                                    font.family: "Iosevka Nerd Font"
                                    font.pixelSize: root.s(42)
                                    color: root[modelData.color]
                                    Layout.alignment: Qt.AlignHCenter
                                }

                                Text {
                                    text: modelData.name
                                    font.family: "JetBrains Mono"
                                    font.weight: Font.Bold
                                    font.pixelSize: root.s(13)
                                    color: root.text
                                    Layout.alignment: Qt.AlignHCenter
                                }
                            }

                            MouseArea {
                                id: repoMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Quickshell.execDetached(["xdg-open", modelData.url])
                            }
                        }
                    }
                }
            }
        }
    }
}
