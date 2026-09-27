import QtQuick
import QtQuick.Layouts
import QtCore as QtCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    readonly property string bridgeIp: Plasmoid.configuration.bridgeIp
    readonly property string apiKey:   Plasmoid.configuration.apiKey
    readonly property string apiBase:  "http://" + bridgeIp + "/api/" + apiKey
    readonly property bool configured: bridgeIp !== "" && apiKey !== ""

    property var    lights:      ({})
    property var    groups:      ({})
    property bool   hasData:     false
    property bool   polledOnce:  false
    property bool   reachable:   false   // last poll got a valid answer from the bridge
    property bool   rejected:    false   // bridge answered, but refused the API key
    property string pollError:   ""      // why the last poll failed
    property string actionError: ""      // last failed switch/brightness command
    property int    lightsOn:    0
    property int    lightsTotal: 0
    property bool   fetching:    false
    property bool   sliderBusy:  false
    property int    localGen:    0       // bumped on every local change; poll results started before it are dropped
    property string structureKey: ""     // room/light ids currently in roomModel
    property var    pendingBri:  ({})    // lightId -> bri, flushed by briDebounce

    switchWidth:  Kirigami.Units.gridUnit * 22
    switchHeight: Kirigami.Units.gridUnit * 28

    // The bridge is only reachable in the home network. Anywhere else the widget
    // stays quiet: dimmed icon, passive status (hidden when placed in the system
    // tray), slow polling, no error colours.
    readonly property bool away: configured && polledOnce && !reachable && !rejected

    Plasmoid.status: away ? PlasmaCore.Types.PassiveStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: "Hue Dashboard"
    toolTipSubText: !configured ? i18n("Not set up")
                  : rejected ? pollError
                  : away ? i18n("Not in the home network")
                  : i18n("%1 / %2 on", lightsOn, lightsTotal)

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("All Off")
            icon.name: "system-shutdown"
            enabled: root.reachable && root.lightsOn > 0
            onTriggered: root.allOff()
        }
    ]

    // Credentials used to live in Qt.labs.settings (~/.config/kde.org/plasmashell.conf, [hue]).
    // Move them into the applet configuration once, then blank the old entries.
    QtCore.Settings {
        id: legacySettings
        category: "hue"
    }

    Component.onCompleted: {
        var oldKey = legacySettings.value("apiKey", "")
        if (Plasmoid.configuration.apiKey === "" && oldKey !== "") {
            Plasmoid.configuration.bridgeIp = legacySettings.value("bridgeIp", "")
            Plasmoid.configuration.apiKey   = oldKey
            legacySettings.setValue("bridgeIp", "")
            legacySettings.setValue("apiKey", "")
        }
    }

    // New IP or key: forget the old bridge's state and ask the new one right away.
    onApiBaseChanged: function() {
        clearState()
        root.fetchState()
    }
    onExpandedChanged: function() { if (root.expanded) root.fetchState() }

    // ── Timers ────────────────────────────────────────────────────────────────

    // Fast polling only while the popup is open; the tray dot and tooltip can lag a bit.
    // Away from home just check now and then whether we are back.
    Timer {
        id: pollTimer
        interval: root.expanded ? (root.away ? 10000 : 2000)
                                : (root.away ? 120000 : 30000)
        running: root.configured
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchState()
    }

    // After a local change the bridge needs a moment before it reports the new state.
    Timer {
        id: pollLock
        interval: 3000
    }

    Timer {
        id: briDebounce
        interval: 250
        onTriggered: root.flushBrightness()
    }

    Component {
        id: timeoutComponent
        Timer { interval: 5000 }
    }

    // ── API ───────────────────────────────────────────────────────────────────

    function bridgeError(e) {
        switch (e.type) {
        case 1:   return i18n("The bridge rejected the API key. Pair again in the widget settings.")
        case 101: return i18n("Link button not pressed. Press the button on the bridge, then try again.")
        default:  return e.description || i18n("Bridge error %1", e.type)
        }
    }

    // cb(errorText, data); errorText is "" on success.
    function request(method, url, body, cb) {
        var xhr = new XMLHttpRequest()
        var timer = timeoutComponent.createObject(root)
        var done = false

        function finish(err, data) {
            if (done) return
            done = true
            timer.destroy()
            if (cb) cb(err, data)
        }

        timer.triggered.connect(function() {
            finish(i18n("Bridge at %1 is not responding.", root.bridgeIp || url))
            xhr.abort()
        })

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 0) { finish(i18n("Cannot reach %1.", url.split("/")[2])); return }
            if (xhr.status !== 200) { finish(i18n("HTTP error %1.", xhr.status)); return }
            var data
            try { data = JSON.parse(xhr.responseText) } catch (e) { finish(i18n("Invalid response.")); return }
            if (Array.isArray(data) && data.length > 0 && data[0].error) {
                finish(bridgeError(data[0].error), data)
                return
            }
            finish("", data)
        }

        xhr.open(method, url)
        if (body !== null) {
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(body)
        } else {
            xhr.send()
        }
        timer.start()
    }

    function fetchState() {
        if (!configured || fetching || pollLock.running || sliderBusy) return
        fetching = true
        var gen = localGen, base = apiBase
        var result = {}, pending = 2, firstErr = "", bridgeRefused = false

        function collect(key) {
            return function(err, data) {
                if (err !== "" && firstErr === "") {
                    firstErr = err
                    bridgeRefused = Array.isArray(data)   // error came from the bridge itself
                }
                result[key] = data
                if (--pending > 0) return
                fetching = false
                if (base !== apiBase) { fetchState(); return }   // IP or key changed meanwhile
                polledOnce = true
                pollError  = firstErr
                reachable  = firstErr === ""
                rejected   = bridgeRefused
                if (!reachable || gen !== localGen) return
                actionError = ""
                lights  = result.lights
                groups  = result.groups
                hasData = true
                updateModel()
            }
        }
        request("GET", base + "/lights", null, collect("lights"))
        request("GET", base + "/groups", null, collect("groups"))
    }

    function sendState(path, obj) {
        request("PUT", apiBase + path, JSON.stringify(obj), function(err) {
            if (err === "") return
            actionError = err
            pollLock.stop()
            fetchState()                              // resync with what the bridge really did
        })
    }

    // ── Model ─────────────────────────────────────────────────────────────────

    ListModel { id: roomModel }

    function setIfDiff(model, index, role, value) {
        if (model.get(index)[role] !== value) model.setProperty(index, role, value)
    }

    function updateModel() {
        if (sliderBusy) return
        var on = 0, total = 0, entries = []
        var gids = Object.keys(groups)
        for (var ri = 0; ri < gids.length; ri++) {
            var gid = gids[ri], g = groups[gid]
            if (g.type !== "Room") continue
            var llist = [], anyOn = false
            var lids = g.lights || []
            for (var li = 0; li < lids.length; li++) {
                var lid = lids[li], l = lights[lid]
                if (!l) continue
                var st = l.state || {}
                total++
                if (st.on) { on++; anyOn = true }
                llist.push({
                    lightId:   lid,
                    lightName: l.name || i18n("Light %1", lid),
                    isOn:      !!st.on,
                    bri:       st.bri !== undefined ? st.bri : 254,
                    hasBri:    st.bri !== undefined,
                    reachable: st.reachable !== false
                })
            }
            entries.push({ groupId: gid, roomName: g.name || i18n("Room %1", gid), anyOn: anyOn, roomLights: llist })
        }
        lightsOn = on
        lightsTotal = total

        // Rebuild only when rooms or their lights change; otherwise update in place
        // so delegates, focus and scroll position survive.
        var key = entries.map(function(e) {
            return e.groupId + ":" + e.roomLights.map(function(x) { return x.lightId }).join(",")
        }).join("|")
        if (key !== structureKey) {
            structureKey = key
            roomModel.clear()
            for (var i = 0; i < entries.length; i++) roomModel.append(entries[i])
            return
        }
        for (var r = 0; r < entries.length; r++) {
            setIfDiff(roomModel, r, "roomName", entries[r].roomName)
            setIfDiff(roomModel, r, "anyOn", entries[r].anyOn)
            var lm = roomModel.get(r).roomLights
            var src = entries[r].roomLights
            for (var j = 0; j < src.length; j++) {
                setIfDiff(lm, j, "lightName", src[j].lightName)
                setIfDiff(lm, j, "isOn",      src[j].isOn)
                setIfDiff(lm, j, "bri",       src[j].bri)
                setIfDiff(lm, j, "hasBri",    src[j].hasBri)
                setIfDiff(lm, j, "reachable", src[j].reachable)
            }
        }
    }

    function openSettings() {
        expanded = false        // otherwise the next click on the icon only "closes" the hidden popup
        Plasmoid.internalAction("configure").trigger()
    }

    function clearState() {
        lights = {}
        groups = {}
        hasData = false
        polledOnce = false
        reachable = false
        rejected = false
        pollError = ""
        actionError = ""
        lightsOn = 0
        lightsTotal = 0
        structureKey = ""
        roomModel.clear()
    }

    // ── Optimistic local changes ──────────────────────────────────────────────

    function markLocalChange() {
        localGen++
        pollLock.restart()
    }

    function patchLight(lid, st) {
        var l = lights[lid]
        if (!l || !l.state) return
        for (var k in st) l.state[k] = st[k]
    }

    function setLightOn(lid, on) {
        patchLight(lid, { on: on })
        markLocalChange()
        updateModel()
        sendState("/lights/" + lid + "/state", { on: on })
    }

    function setRoomOn(gid, on) {
        var g = groups[gid]
        var lids = (g && g.lights) || []
        for (var i = 0; i < lids.length; i++) patchLight(lids[i], { on: on })
        markLocalChange()
        updateModel()
        sendState("/groups/" + gid + "/action", { on: on })
    }

    function allOff() {
        var lids = Object.keys(lights)
        for (var i = 0; i < lids.length; i++) patchLight(lids[i], { on: false })
        markLocalChange()
        updateModel()
        sendState("/groups/0/action", { on: false })   // group 0 = every light on the bridge
    }

    function setBrightness(lid, bri, immediate) {
        patchLight(lid, { bri: bri })
        markLocalChange()
        pendingBri[lid] = bri
        if (immediate) flushBrightness()
        else briDebounce.restart()
    }

    function flushBrightness() {
        briDebounce.stop()
        var p = pendingBri
        pendingBri = {}
        for (var lid in p) sendState("/lights/" + lid + "/state", { bri: p[lid] })
    }

    // ── Compact (tray icon) ───────────────────────────────────────────────────

    compactRepresentation: MouseArea {
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "user-home"
            active: parent.containsMouse
            opacity: root.away ? 0.4 : 1
        }

        // Dot: green when any light is on, red when the bridge refuses the API key
        Rectangle {
            anchors { right: parent.right; bottom: parent.bottom; margins: 1 }
            width: Math.round(parent.height / 4); height: width; radius: width / 2
            visible: root.rejected || (root.reachable && root.lightsOn > 0)
            color: root.rejected ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
            border.color: Kirigami.Theme.backgroundColor
            border.width: 1
        }
    }

    // ── Full (popup) ──────────────────────────────────────────────────────────

    fullRepresentation: PlasmaExtras.Representation {
        Layout.preferredWidth:  Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 28
        Layout.minimumWidth:    Kirigami.Units.gridUnit * 18
        Layout.minimumHeight:   Kirigami.Units.gridUnit * 16

        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: root.configured ? "HUE // CTRL" : "HUE // SETUP"
                    level: 3
                    font.family: "monospace"
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Label {
                    visible: root.hasData && root.reachable
                    text: i18n("%1/%2 on", root.lightsOn, root.lightsTotal)
                    color: root.lightsOn > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "configure"
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    text: i18n("Configure…")
                    onClicked: root.openSettings()
                    PlasmaComponents3.ToolTip.text: text
                    PlasmaComponents3.ToolTip.visible: hovered
                    PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }
        }

        contentItem: Loader {
            sourceComponent: root.configured ? mainComponent : setupComponent
        }
    }

    // ── Setup flow ────────────────────────────────────────────────────────────

    Component {
        id: setupComponent

        Item {
            id: setupRoot

            property int step: 1                  // 1 = discover, 2 = pair
            property bool discovering: false
            property string discoverInfo: ""
            property bool discoverFailed: false
            property bool pairing: false
            property string pairError: ""

            Component.onCompleted: startDiscovery()

            function startDiscovery() {
                discovering = true
                discoverInfo = ""
                root.request("GET", "https://discovery.meethue.com", null, function(err, data) {
                    discovering = false
                    if (err === "" && Array.isArray(data) && data.length > 0 && data[0].internalipaddress) {
                        ipField.text = data[0].internalipaddress
                        discoverFailed = false
                        discoverInfo = i18n("Found bridge at %1", ipField.text)
                    } else {
                        discoverFailed = true
                        discoverInfo = err !== "" ? i18n("Discovery failed: %1 Enter the IP manually.", err)
                                                  : i18n("No bridge found. Enter the IP manually.")
                    }
                })
            }

            function startPairing() {
                var ip = ipField.text.trim()
                if (ip === "") return
                pairing = true
                pairError = ""
                root.request("POST", "http://" + ip + "/api", JSON.stringify({ devicetype: "hue-dashboard#plasma" }), function(err, data) {
                    pairing = false
                    if (err !== "") { pairError = err; return }
                    if (data && data[0] && data[0].success && data[0].success.username) {
                        Plasmoid.configuration.bridgeIp = ip
                        Plasmoid.configuration.apiKey   = data[0].success.username
                    } else {
                        pairError = i18n("Unexpected response from bridge.")
                    }
                })
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing

                Item { Layout.fillHeight: true }

                // Step 1: discover
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: setupRoot.step === 1
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Heading {
                        Layout.fillWidth: true
                        level: 4
                        text: i18n("Step 1 — Find your bridge")
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: setupRoot.discovering ? i18n("Searching…") : setupRoot.discoverInfo
                        color: setupRoot.discovering ? Kirigami.Theme.disabledTextColor
                             : setupRoot.discoverFailed ? Kirigami.Theme.negativeTextColor
                             : Kirigami.Theme.positiveTextColor
                    }
                    PlasmaComponents3.TextField {
                        id: ipField
                        Layout.fillWidth: true
                        placeholderText: i18n("Bridge IP address, e.g. 192.168.1.100")
                        onAccepted: if (text.trim() !== "") setupRoot.step = 2
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Button {
                            text: i18n("Re-scan")
                            icon.name: "view-refresh"
                            enabled: !setupRoot.discovering
                            onClicked: setupRoot.startDiscovery()
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents3.Button {
                            text: i18n("Next")
                            icon.name: "go-next"
                            enabled: ipField.text.trim() !== ""
                            onClicked: setupRoot.step = 2
                        }
                    }
                }

                // Step 2: pair
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: setupRoot.step === 2
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Heading {
                        Layout.fillWidth: true
                        level: 4
                        text: i18n("Step 2 — Pair with bridge")
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: i18n("Press the button on your Hue Bridge at %1, then click Connect within 30 seconds.", ipField.text.trim())
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        visible: setupRoot.pairError !== "" && !setupRoot.pairing
                        text: setupRoot.pairError
                        color: Kirigami.Theme.negativeTextColor
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Button {
                            text: i18n("Back")
                            icon.name: "go-previous"
                            onClicked: { setupRoot.step = 1; setupRoot.pairError = "" }
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents3.BusyIndicator {
                            visible: setupRoot.pairing
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        }
                        PlasmaComponents3.Button {
                            text: i18n("Connect")
                            icon.name: "network-connect"
                            enabled: !setupRoot.pairing
                            onClicked: setupRoot.startPairing()
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    // ── Main view ─────────────────────────────────────────────────────────────

    Component {
        id: mainComponent

        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                type: Kirigami.MessageType.Error
                visible: root.reachable && root.actionError !== ""
                text: root.actionError
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                contentWidth: availableWidth - contentItem.leftMargin - contentItem.rightMargin
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: roomList
                    model: root.reachable ? roomModel : null
                    spacing: Kirigami.Units.smallSpacing
                    topMargin: Kirigami.Units.smallSpacing
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    bottomMargin: Kirigami.Units.smallSpacing
                    reuseItems: false
                    delegate: roomDelegate

                    PlasmaExtras.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.gridUnit * 2
                        visible: roomList.count === 0
                        iconName: root.rejected ? "dialog-error"
                                : root.away ? "network-disconnect" : ""
                        text: root.rejected ? i18n("Bridge refused access")
                            : root.away ? i18n("Not in the home network")
                            : root.polledOnce ? i18n("No rooms on this bridge")
                            : i18n("Loading…")
                        explanation: root.rejected ? root.pollError
                                   : root.away ? i18n("The Hue bridge at %1 cannot be reached. The widget checks again every couple of minutes, and immediately when you open it.", root.bridgeIp)
                                   : ""
                        helpfulAction: Kirigami.Action {
                            enabled: root.away || root.rejected
                            text: root.rejected ? i18n("Configure…") : i18n("Retry")
                            icon.name: root.rejected ? "configure" : "view-refresh"
                            onTriggered: root.rejected ? root.openSettings() : root.fetchState()
                        }
                    }
                }
            }

            PlasmaComponents3.Button {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                text: i18n("All Off")
                icon.name: "system-shutdown"
                enabled: root.reachable && root.lightsOn > 0
                onClicked: root.allOff()
            }
        }
    }

    // ── Room card ─────────────────────────────────────────────────────────────

    Component {
        id: roomDelegate

        Rectangle {
            id: card

            readonly property string groupId: model.groupId
            readonly property bool anyOn: model.anyOn

            width: ListView.view ? ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin : 0
            implicitHeight: cardColumn.implicitHeight + Kirigami.Units.largeSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
            border.width: 1
            border.color: anyOn ? Kirigami.Theme.highlightColor : Qt.alpha(Kirigami.Theme.textColor, 0.12)

            ColumnLayout {
                id: cardColumn
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    margins: Kirigami.Units.largeSpacing
                }
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Heading {
                        Layout.fillWidth: true
                        level: 4
                        text: model.roomName
                        elide: Text.ElideRight
                        opacity: card.anyOn ? 1 : 0.6
                    }
                    PlasmaComponents3.Switch {
                        checked: card.anyOn
                        Accessible.name: i18n("%1: all lights", model.roomName)
                        onToggled: root.setRoomOn(card.groupId, checked)
                    }
                }

                Repeater {
                    model: roomLights

                    ColumnLayout {
                        id: lightRow
                        Layout.fillWidth: true
                        spacing: 0

                        readonly property string lightId: model.lightId

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: model.reachable ? model.lightName
                                                      : i18n("%1 (unreachable)", model.lightName)
                                elide: Text.ElideRight
                                color: model.isOn && model.reachable ? Kirigami.Theme.textColor
                                                                     : Kirigami.Theme.disabledTextColor
                            }
                            PlasmaComponents3.Switch {
                                checked: model.isOn
                                enabled: model.reachable
                                Accessible.name: model.lightName
                                onToggled: root.setLightOn(lightRow.lightId, checked)
                            }
                        }

                        PlasmaComponents3.Slider {
                            Layout.fillWidth: true
                            visible: model.hasBri && model.isOn && model.reachable
                            from: 1; to: 254; stepSize: 1
                            value: model.bri
                            Accessible.name: i18n("%1 brightness", model.lightName)

                            onMoved: root.setBrightness(lightRow.lightId, Math.round(value), false)
                            onPressedChanged: {
                                if (pressed) {
                                    root.sliderBusy = true
                                    return
                                }
                                root.setBrightness(lightRow.lightId, Math.round(value), true)
                                root.sliderBusy = false
                                root.updateModel()
                            }
                        }
                    }
                }
            }
        }
    }
}
