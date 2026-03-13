import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import Qt.labs.settings

PlasmoidItem {
    id: root

    Settings {
        id: settings
        category: "hue"
        property string bridgeIp: ""
        property string apiKey: ""
    }

    property string bridgeIp: settings.bridgeIp
    property string apiUser:  settings.apiKey
    property string apiBase:  "http://" + bridgeIp + "/api/" + apiUser

    property bool configured: bridgeIp !== "" && apiUser !== ""

    property var  rooms:      ({})
    property var  lights:     ({})
    property int  lightsOn:   0
    property int  lightsTotal: 0
    property bool sliderBusy: false
    property bool pollLocked: false
    property string modelHash: ""

    switchWidth:  Kirigami.Units.gridUnit * 22
    switchHeight: Kirigami.Units.gridUnit * 28

    toolTipMainText: "Hue Dashboard"
    toolTipSubText:  lightsOn + " / " + lightsTotal + " on"

    // ── Timers & API ─────────────────────────────────────────────────────────

    Timer {
        id: pollTimer
        interval: 2000; running: root.configured; repeat: true; triggeredOnStart: true
        onTriggered: fetchState()
    }

    Timer {
        id: debounce
        interval: 300; repeat: false
        property string url: ""; property string body: ""
        onTriggered: root.apiPut(url, body, null)
    }

    Timer {
        id: pollLockTimer
        interval: 3000; repeat: false
        onTriggered: root.pollLocked = false
    }

    function apiGet(path, cb) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200)
                try { cb(JSON.parse(xhr.responseText)) } catch(e) {}
        }
        xhr.open("GET", apiBase + path)
        xhr.send()
    }

    function apiPut(path, body, cb) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() { if (xhr.readyState === 4 && cb) cb() }
        xhr.open("PUT", apiBase + path)
        xhr.send(body)
    }

    function fetchState() {
        if (pollLocked) return
        apiGet("/lights", function(d) { lights = d; buildModel() })
        apiGet("/groups", function(d) { rooms  = d })
    }

    function buildModel() {
        if (sliderBusy) return
        var on = 0, total = 0, entries = []
        var gkeys = Object.keys(rooms)
        for (var ri = 0; ri < gkeys.length; ri++) {
            var gid = gkeys[ri], g = rooms[gid]
            if (g.type !== "Room") continue
            var llist = [], anyOn = false
            var lids = g.lights || []
            for (var li = 0; li < lids.length; li++) {
                var lid = lids[li], l = lights[lid]
                if (!l) continue
                total++
                var st = l.state || {}
                if (st.on) { on++; anyOn = true }
                llist.push({
                    lightId:   lid,
                    lightName: l.name || ("Light " + lid),
                    isOn:      !!st.on,
                    bri:       (st.bri !== undefined) ? st.bri : 128,
                    hasBri:    (st.bri !== undefined),
                    reachable: (st.reachable !== false)
                })
            }
            entries.push({ groupId: gid, roomName: g.name || ("Room " + gid), anyOn: anyOn, roomLights: llist })
        }
        lightsOn = on; lightsTotal = total
        var hash = JSON.stringify(entries)
        if (hash === modelHash) return
        modelHash = hash
        roomModel.clear()
        for (var i = 0; i < entries.length; i++) roomModel.append(entries[i])
    }

    // ── Optimistic UI updates ───────────────────────────────────────────────

    function lockPoll() {
        pollLocked = true
        modelHash = ""
        pollLockTimer.restart()
    }

    function toggleLight(lid, newOn) {
        var l = lights[lid]
        if (l && l.state) l.state.on = newOn
        lockPoll()
        buildModel()
        apiPut("/lights/" + lid + "/state", JSON.stringify({on: newOn}), null)
    }

    function toggleRoom(gid, newOn) {
        var g = rooms[gid]
        if (g && g.lights) {
            for (var i = 0; i < g.lights.length; i++) {
                var l = lights[g.lights[i]]
                if (l && l.state) l.state.on = newOn
            }
        }
        lockPoll()
        buildModel()
        apiPut("/groups/" + gid + "/action", JSON.stringify({on: newOn}), null)
    }

    function allOff() {
        var lkeys = Object.keys(lights)
        for (var i = 0; i < lkeys.length; i++) {
            var l = lights[lkeys[i]]
            if (l && l.state) l.state.on = false
        }
        lockPoll()
        buildModel()
        var ks = Object.keys(rooms)
        for (var j = 0; j < ks.length; j++)
            if (rooms[ks[j]].type === "Room")
                apiPut("/groups/" + ks[j] + "/action", JSON.stringify({on: false}), null)
    }

    function resetSettings() {
        settings.bridgeIp = ""
        settings.apiKey   = ""
        rooms    = {}
        lights   = {}
        lightsOn = 0
        lightsTotal = 0
        roomModel.clear()
    }

    ListModel { id: roomModel }

    // ── Compact (tray icon) ───────────────────────────────────────────────────

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        hoverEnabled: true

        Kirigami.Icon {
            anchors.fill: parent
            source: "user-home"
            opacity: parent.containsMouse ? 0.8 : 1.0
        }

        // Small indicator dot: green when any lights on
        Rectangle {
            anchors { right: parent.right; bottom: parent.bottom; margins: 1 }
            width: 6; height: 6; radius: 3
            color: root.lightsOn > 0 ? Kirigami.Theme.positiveTextColor : "transparent"
            border.color: root.lightsOn > 0 ? Kirigami.Theme.backgroundColor : "transparent"
            border.width: 1
        }
    }

    // ── Full (popup) ──────────────────────────────────────────────────────────

    fullRepresentation: Item {
        Layout.preferredWidth:  Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 28
        Layout.minimumWidth:    Kirigami.Units.gridUnit * 18
        Layout.minimumHeight:   Kirigami.Units.gridUnit * 16

        // ── Setup view (shown when not configured) ──────────────────────────
        Loader {
            anchors.fill: parent
            active: !root.configured
            visible: active
            sourceComponent: setupComponent
        }

        // ── Normal view (shown when configured) ─────────────────────────────
        Loader {
            anchors.fill: parent
            active: root.configured
            visible: active
            sourceComponent: normalComponent
        }
    }

    // ── Setup flow component ────────────────────────────────────────────────

    Component {
        id: setupComponent

        Item {
            id: setupRoot

            property int step: 1          // 1 = discover, 2 = pair
            property string discoveredIp: ""
            property bool discovering: false
            property string discoverError: ""
            property bool pairing: false
            property string pairError: ""

            Component.onCompleted: startDiscovery()

            function startDiscovery() {
                discovering = true
                discoverError = ""
                discoveredIp = ""

                var xhr = new XMLHttpRequest()
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    discovering = false
                    if (xhr.status === 200) {
                        try {
                            var arr = JSON.parse(xhr.responseText)
                            if (arr.length > 0 && arr[0].internalipaddress) {
                                discoveredIp = arr[0].internalipaddress
                                ipField.text = discoveredIp
                            } else {
                                discoverError = "No bridges found on your network."
                            }
                        } catch(e) {
                            discoverError = "Invalid response from discovery service."
                        }
                    } else {
                        discoverError = "Discovery failed (HTTP " + xhr.status + "). Enter IP manually."
                    }
                }
                xhr.open("GET", "https://discovery.meethue.com")
                xhr.send()
            }

            function startPairing() {
                var ip = ipField.text.trim()
                if (ip === "") return
                pairing = true
                pairError = ""

                var xhr = new XMLHttpRequest()
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    pairing = false
                    if (xhr.status === 200) {
                        try {
                            var resp = JSON.parse(xhr.responseText)
                            if (resp.length > 0) {
                                if (resp[0].error) {
                                    var errType = resp[0].error.type
                                    if (errType === 101) {
                                        pairError = "Link button not pressed. Press the button on your bridge, then try again."
                                    } else {
                                        pairError = resp[0].error.description || ("Error " + errType)
                                    }
                                } else if (resp[0].success && resp[0].success.username) {
                                    settings.bridgeIp = ip
                                    settings.apiKey   = resp[0].success.username
                                }
                            }
                        } catch(e) {
                            pairError = "Invalid response from bridge."
                        }
                    } else {
                        pairError = "Connection failed (HTTP " + xhr.status + ")."
                    }
                }
                xhr.open("POST", "http://" + ip + "/api")
                xhr.send(JSON.stringify({ devicetype: "hue-dashboard#plasma" }))
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing * 2
                spacing: Kirigami.Units.largeSpacing

                // Header
                Text {
                    Layout.fillWidth: true
                    text: "HUE // SETUP"
                    font.pixelSize: 15; font.bold: true; font.family: "monospace"
                    color: Kirigami.Theme.textColor
                }

                Kirigami.Separator { Layout.fillWidth: true }

                Item { Layout.fillHeight: true }

                // ── Step 1: Discover ────────────────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    visible: setupRoot.step === 1

                    Text {
                        Layout.fillWidth: true
                        text: "Step 1 — Find your bridge"
                        font.pixelSize: 13; font.bold: true
                        color: Kirigami.Theme.textColor
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: setupRoot.discovering
                        text: "Searching..."
                        font.pixelSize: 12
                        color: Kirigami.Theme.disabledTextColor
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: setupRoot.discoveredIp !== "" && !setupRoot.discovering
                        text: "Found bridge at " + setupRoot.discoveredIp
                        font.pixelSize: 12
                        color: Kirigami.Theme.positiveTextColor
                        wrapMode: Text.Wrap
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: setupRoot.discoverError !== "" && !setupRoot.discovering
                        text: setupRoot.discoverError
                        font.pixelSize: 12
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.Wrap
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Bridge IP address:"
                        font.pixelSize: 11
                        color: Kirigami.Theme.disabledTextColor
                    }

                    TextField {
                        id: ipField
                        Layout.fillWidth: true
                        placeholderText: "e.g. 192.168.1.100"
                        font.pixelSize: 13
                        text: setupRoot.discoveredIp
                        color: Kirigami.Theme.textColor
                        background: Rectangle {
                            radius: Kirigami.Units.smallSpacing
                            color: Kirigami.Theme.alternateBackgroundColor
                            border.color: ipField.activeFocus ? Kirigami.Theme.highlightColor
                                                              : Qt.alpha(Kirigami.Theme.textColor, 0.2)
                            border.width: 1
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.preferredWidth: retryText.implicitWidth + 24
                            height: 30; radius: Kirigami.Units.smallSpacing
                            color: retryArea.containsMouse
                                   ? Qt.alpha(Kirigami.Theme.textColor, 0.15)
                                   : Qt.alpha(Kirigami.Theme.textColor, 0.08)
                            MouseArea {
                                id: retryArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: setupRoot.startDiscovery()
                            }
                            Text {
                                id: retryText; anchors.centerIn: parent
                                text: "Re-scan"
                                font.pixelSize: 12; color: Kirigami.Theme.textColor
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            Layout.preferredWidth: nextText.implicitWidth + 24
                            height: 30; radius: Kirigami.Units.smallSpacing
                            color: nextArea.containsMouse
                                   ? Qt.alpha(Kirigami.Theme.highlightColor, 0.9)
                                   : Kirigami.Theme.highlightColor
                            opacity: ipField.text.trim() !== "" ? 1.0 : 0.4
                            MouseArea {
                                id: nextArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                enabled: ipField.text.trim() !== ""
                                onClicked: { setupRoot.step = 2 }
                            }
                            Text {
                                id: nextText; anchors.centerIn: parent
                                text: "Next"
                                font.pixelSize: 12; font.bold: true
                                color: Kirigami.Theme.highlightedTextColor
                            }
                        }
                    }
                }

                // ── Step 2: Pair ────────────────────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    visible: setupRoot.step === 2

                    Text {
                        Layout.fillWidth: true
                        text: "Step 2 — Pair with bridge"
                        font.pixelSize: 13; font.bold: true
                        color: Kirigami.Theme.textColor
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Press the physical button on your Hue Bridge, then click Connect."
                        font.pixelSize: 12
                        color: Kirigami.Theme.textColor
                        wrapMode: Text.Wrap
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Connecting to " + ipField.text.trim() + "..."
                        font.pixelSize: 12
                        color: Kirigami.Theme.disabledTextColor
                        visible: setupRoot.pairing
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: setupRoot.pairError !== "" && !setupRoot.pairing
                        text: setupRoot.pairError
                        font.pixelSize: 12
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.Wrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.preferredWidth: backText.implicitWidth + 24
                            height: 30; radius: Kirigami.Units.smallSpacing
                            color: backArea.containsMouse
                                   ? Qt.alpha(Kirigami.Theme.textColor, 0.15)
                                   : Qt.alpha(Kirigami.Theme.textColor, 0.08)
                            MouseArea {
                                id: backArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { setupRoot.step = 1; setupRoot.pairError = "" }
                            }
                            Text {
                                id: backText; anchors.centerIn: parent
                                text: "Back"
                                font.pixelSize: 12; color: Kirigami.Theme.textColor
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            Layout.preferredWidth: connectText.implicitWidth + 24
                            height: 30; radius: Kirigami.Units.smallSpacing
                            color: connectArea.containsMouse
                                   ? Qt.alpha(Kirigami.Theme.highlightColor, 0.9)
                                   : Kirigami.Theme.highlightColor
                            opacity: setupRoot.pairing ? 0.5 : 1.0
                            MouseArea {
                                id: connectArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                enabled: !setupRoot.pairing
                                onClicked: setupRoot.startPairing()
                            }
                            Text {
                                id: connectText; anchors.centerIn: parent
                                text: "Connect"
                                font.pixelSize: 12; font.bold: true
                                color: Kirigami.Theme.highlightedTextColor
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    // ── Normal (configured) view component ──────────────────────────────────

    Component {
        id: normalComponent

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing * 2
            spacing: Kirigami.Units.smallSpacing

            // Header
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "HUE // CTRL"
                    font.pixelSize: 15; font.bold: true; font.family: "monospace"
                    color: Kirigami.Theme.textColor
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: root.lightsOn + "/" + root.lightsTotal + " on"
                    font.pixelSize: 11
                    color: root.lightsOn > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                }

                // Reset / gear button
                Rectangle {
                    width: 22; height: 22; radius: 11
                    color: gearArea.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.12) : "transparent"
                    MouseArea {
                        id: gearArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.resetSettings()
                    }
                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        source: "configure"
                        color: Kirigami.Theme.disabledTextColor
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // Room list
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                ListView {
                    id: roomList
                    model: roomModel
                    spacing: Kirigami.Units.smallSpacing
                    delegate: roomDelegate
                }
            }

            // All Off button
            Rectangle {
                Layout.fillWidth: true
                height: 34; radius: Kirigami.Units.smallSpacing
                color: abkArea.containsMouse
                       ? Qt.alpha(Kirigami.Theme.negativeTextColor, 0.85)
                       : Qt.alpha(Kirigami.Theme.negativeTextColor, 0.7)
                MouseArea {
                    id: abkArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.allOff()
                }
                Text {
                    anchors.centerIn: parent
                    text: "All Off"
                    font.pixelSize: 12; font.bold: true
                    color: "white"
                }
            }
        }
    }

    // ── Room card delegate ────────────────────────────────────────────────────

    Component {
        id: roomDelegate

        Item {
            id: card
            readonly property string gid:  model.groupId
            readonly property string rnam: model.roomName
            readonly property bool   raon: model.anyOn

            width:  ListView.view ? ListView.view.width : 300
            height: 8 + 28 + inner.lightsHeight + 8

            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
                radius: Kirigami.Units.smallSpacing
                border.color: card.raon ? Kirigami.Theme.highlightColor : Qt.alpha(Kirigami.Theme.textColor, 0.12)
                border.width: 1
            }

            // Room header
            Item {
                x: 8; y: 8
                width: parent.width - 16; height: 28

                Text {
                    anchors { left: parent.left; right: gToggle.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: card.rnam
                    color: card.raon ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                    font.pixelSize: 13; font.bold: true
                    elide: Text.ElideRight
                }

                Rectangle {
                    id: gToggle
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    width: 40; height: 22; radius: 11
                    color: card.raon ? Kirigami.Theme.highlightColor : Qt.alpha(Kirigami.Theme.textColor, 0.15)
                    Rectangle {
                        width: 16; height: 16; radius: 8
                        color: card.raon ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                        x: card.raon ? parent.width - width - 3 : 3
                        anchors.verticalCenter: parent.verticalCenter
                        Behavior on x { NumberAnimation { duration: 150 } }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleRoom(card.gid, !card.raon)
                    }
                }
            }

            // Individual lights
            Column {
                id: inner
                x: 8; y: 8 + 28 + 4
                width: parent.width - 16
                spacing: 4
                property int lightsHeight: childrenRect.height + (children.length > 0 ? 4 : 0)

                Repeater {
                    model: roomLights

                    Column {
                        id: lightRow
                        width: inner.width
                        spacing: 2

                        property string lid:   lightId
                        property string lnam:  lightName
                        property bool   lon:   isOn
                        property int    lbri:  bri
                        property bool   lhbri: hasBri
                        property bool   lrch:  reachable

                        Item {
                            width: parent.width; height: 24

                            Rectangle {
                                id: ldot
                                width: 6; height: 6; radius: 3
                                anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
                                color: lightRow.lon ? Kirigami.Theme.positiveTextColor : Qt.alpha(Kirigami.Theme.textColor, 0.25)
                            }

                            Text {
                                anchors {
                                    left: ldot.right; leftMargin: 6
                                    right: ltog.left; rightMargin: 6
                                    verticalCenter: parent.verticalCenter
                                }
                                text: lightRow.lnam
                                color: lightRow.lon ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: ltog
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                width: 32; height: 18; radius: 9
                                color: lightRow.lon ? Kirigami.Theme.highlightColor : Qt.alpha(Kirigami.Theme.textColor, 0.15)
                                opacity: lightRow.lrch ? 1.0 : 0.4
                                Rectangle {
                                    width: 12; height: 12; radius: 6
                                    color: lightRow.lon ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                                    x: lightRow.lon ? parent.width - width - 3 : 3
                                    anchors.verticalCenter: parent.verticalCenter
                                    Behavior on x { NumberAnimation { duration: 120 } }
                                }
                                MouseArea {
                                    anchors.fill: parent; enabled: lightRow.lrch; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleLight(lightRow.lid, !lightRow.lon)
                                }
                            }
                        }

                        Slider {
                            id: briSlider
                            width:   parent.width
                            height:  (lightRow.lhbri && lightRow.lon) ? 18 : 0
                            visible: lightRow.lhbri && lightRow.lon
                            from: 1; to: 254; stepSize: 1
                            value: lightRow.lbri

                            onPressedChanged: {
                                root.sliderBusy = pressed
                                if (!pressed) Qt.callLater(root.buildModel)
                            }
                            onMoved: {
                                debounce.url  = "/lights/" + lightRow.lid + "/state"
                                debounce.body = JSON.stringify({bri: Math.round(value)})
                                debounce.restart()
                            }

                            background: Rectangle {
                                x: parent.leftPadding
                                y: parent.topPadding + parent.availableHeight / 2 - height / 2
                                width: parent.availableWidth; height: 3; radius: 2
                                color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
                                Rectangle {
                                    width: parent.width * briSlider.visualPosition
                                    height: parent.height; radius: 2
                                    color: Kirigami.Theme.highlightColor
                                }
                            }
                            handle: Rectangle {
                                x: parent.leftPadding + parent.visualPosition * parent.availableWidth - width / 2
                                y: parent.topPadding + parent.availableHeight / 2 - height / 2
                                width: 14; height: 14; radius: 7
                                color: Kirigami.Theme.highlightColor
                                border.color: Kirigami.Theme.highlightedTextColor; border.width: 1
                            }
                        }
                    }
                }
            }
        }
    }
}
