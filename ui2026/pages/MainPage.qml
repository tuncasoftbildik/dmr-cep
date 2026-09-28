/*
    Copyright (C) 2025 Rohith Namboothiri
    Copyright (C) 2026 DroidStar-DMR contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "../components"
import "../theme"

// DMR Cep main screen, laid out like a handheld radio:
//   status strip  -> amber LCD (talkgroup) -> channel presets -> who is talking -> big round key.
// Everything technical (mode, host, slot, CC, mic) lives in the "Connection & audio" sheet.
Page {
    id: page
    title: qsTr("DMR Cep")
    padding: 0

    required property var droidstarRef
    required property var appState
    required property var logHandlerRef
    property var vuidUpdaterRef: null

    Tokens { id: t }

    FontLoader { id: segFont; source: "qrc:/DroidStar/fonts/DSEG7Classic-Bold.ttf" }

    property var modeComboBoxRef: null
    property var hostComboBoxRef: null

    readonly property bool isTgMode: !!(appState && (appState.mode === "DMR" || appState.mode === "P25" || appState.mode === "NXDN"))
    readonly property bool connected: !!(appState && appState.connected)
    readonly property bool connecting: !!(appState && appState.connecting)
    readonly property bool onAir: !!(appState && appState.txActive)
    readonly property bool receiving: connected && !onAir && !!(appState && appState.data1 !== "")

    Connections {
        target: page.appState
        enabled: !!page.appState
        function onModeChanged() {
            if (page.modeComboBoxRef && page.modeComboBoxRef.loaded) page.modeComboBoxRef.updateFromState()
        }
        function onSelectedHostChanged() {
            if (page.hostComboBoxRef && page.hostComboBoxRef.loaded) page.hostComboBoxRef.updateSelection()
        }
        function onHostsModelChanged() {
            if (page.hostComboBoxRef && page.hostComboBoxRef.loaded) page.hostComboBoxRef.updateSelection()
        }
        function onData1Changed() {
            page.rxStartMs = (page.appState.data1 !== "") ? (page.rxStartMs > 0 ? page.rxStartMs : Date.now()) : 0
        }
        function onDmrtgidChanged() { page.lookupTgName(page.appState.dmrtgid) }
    }

    onVisibleChanged: {
        if (visible) {
            Qt.callLater(function() {
                if (page.modeComboBoxRef) page.modeComboBoxRef.updateFromState()
                if (page.hostComboBoxRef) page.hostComboBoxRef.updateSelection()
            })
            Qt.callLater(function() { refreshLastHeardFromLog() })
        }
    }

    function refreshLastHeardFromLog() {
        if (!page.appState || !page.logHandlerRef) return
        var saved = page.logHandlerRef.loadLog("logs.json")
        if (!saved || saved.length === undefined) return

        function fmt(entry) {
            if (!entry) return ""
            var parts = []
            if (entry.callsign) parts.push(entry.callsign)
            if (entry.fname) parts.push(entry.fname)
            if (entry.country) parts.push(entry.country)
            return parts.join(" - ")
        }

        page.appState.lastHeard1 = saved.length > 0 ? fmt(saved[0]) : ""
        page.appState.lastHeard2 = saved.length > 1 ? fmt(saved[1]) : ""
        // The main screen shows the last station other than ourselves.
        var me = (page.appState.callsign || "").toUpperCase()
        var other = ""
        for (var i = 0; i < saved.length; ++i) {
            if (saved[i] && (saved[i].callsign || "").toUpperCase() !== me) { other = fmt(saved[i]); break }
        }
        page.lastHeardOther = other
    }
    property string lastHeardOther: ""

    Component.onCompleted: {
        refreshLastHeardFromLog()
        Qt.callLater(refreshFavoriteTgs)
        if (appState) Qt.callLater(function() { page.lookupTgName(appState.dmrtgid) })
    }

    Connections {
        target: page.logHandlerRef
        enabled: !!page.logHandlerRef
        function onLogSaved(fileName) { if (fileName === "logs.json") refreshLastHeardFromLog() }
        function onLogCleared(fileName) { if (fileName === "logs.json") refreshLastHeardFromLog() }
    }

    property var modesModel: ["REF", "DCS", "XRF", "YSF", "FCS", "DMR", "P25", "NXDN", "M17", "IAX"]
    property var modulesModel: ["A", "B", "C", "D", "E", "F", "G"]
    property var slotsModel: ["Slot 1", "Slot 2"]
    property var ccsModel: ["CC1", "CC2", "CC3", "CC4", "CC5", "CC6", "CC7", "CC8", "CC9", "CC10", "CC11", "CC12", "CC13", "CC14", "CC15"]
    property var m17CanModel: ["0","1","2","3","4","5","6","7","8","9","10","11","12","13","14","15"]

    function refreshRecentTgids() {
        if (appState) appState.recentTgids = droidstarRef.loadRecentTGIDs()
    }

    // ---- Talkgroup names (favorites first, then BrandMeister lookup, cached) ----
    property var tgNames: ({})

    function tgName(tg) {
        tg = "" + tg
        for (var i = 0; i < favoriteTgs.length; ++i)
            if (favoriteTgs[i].tg === tg && favoriteTgs[i].name) return favoriteTgs[i].name
        return tgNames[tg] || ""
    }

    function lookupTgName(tg) {
        tg = ("" + tg).trim()
        if (!/^[0-9]+$/.test(tg) || tgNames[tg] !== undefined || !appState || appState.mode !== "DMR") return
        var cache = tgNames; cache[tg] = ""; tgNames = cache
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var r = JSON.parse(xhr.responseText)
                if (r && r.Name) { var c = page.tgNames; c[tg] = r.Name; page.tgNames = c }
            } catch (e) {}
        }
        xhr.open("GET", "https://api.brandmeister.network/v2/talkgroup/" + tg, true)
        xhr.send()
    }

    // ---- Favorite talkgroups ----
    property var favoriteTgs: []
    property bool currentTgIsFavorite: false

    function refreshFavoriteTgs() {
        if (!droidstarRef) return
        favoriteTgs = droidstarRef.loadFavoriteTGs()
        currentTgIsFavorite = !!(appState && droidstarRef.isFavoriteTG(appState.dmrtgid))
    }

    function selectTg(tg) {
        if (!appState || !droidstarRef) return
        tg = ("" + tg).trim()
        if (tg === "") return
        appState.dmrtgid = tg
        droidstarRef.set_dmrtgid(tg)
        droidstarRef.tgid_text_changed(tg)
        droidstarRef.addRecentTGID(tg)
        refreshRecentTgids()
        refreshFavoriteTgs()
    }

    function toggleCurrentFavorite() {
        if (!appState || !droidstarRef) return
        var tg = ("" + appState.dmrtgid).trim()
        if (!/^[0-9]+$/.test(tg)) return
        if (droidstarRef.isFavoriteTG(tg)) {
            droidstarRef.removeFavoriteTG(tg)
            refreshFavoriteTgs()
            return
        }
        droidstarRef.addFavoriteTG(tg, tgName(tg))
        refreshFavoriteTgs()
        if (appState.mode !== "DMR" || tgName(tg) !== "") return
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var r = JSON.parse(xhr.responseText)
                if (r && r.Name && droidstarRef.isFavoriteTG(tg)) {
                    droidstarRef.addFavoriteTG(tg, r.Name)
                    refreshFavoriteTgs()
                }
            } catch (e) {}
        }
        xhr.open("GET", "https://api.brandmeister.network/v2/talkgroup/" + tg, true)
        xhr.send()
    }

    // ---- Receive timer ----
    property double rxStartMs: 0
    property string rxElapsed: ""
    Timer {
        interval: 500; repeat: true; running: page.rxStartMs > 0
        onTriggered: {
            var s = Math.floor((Date.now() - page.rxStartMs) / 1000)
            page.rxElapsed = Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
        }
        onRunningChanged: if (!running) page.rxElapsed = ""
    }

    // The key flips to Cancel/Disconnect immediately, so a double tap used to cancel the
    // connection it had just started. Ignore a second tap within 1.5 s.
    property double _lastConnectTapMs: 0

    function connectOrDisconnect() {
        if (!appState || !droidstarRef) return
        var now = Date.now()
        if (now - _lastConnectTapMs < 1500) {
            console.log("Connect button: ignored double tap (" + (now - _lastConnectTapMs) + " ms)")
            return
        }
        _lastConnectTapMs = now
        console.log("Connect button tapped: connecting=" + appState.connecting + " connected=" + appState.connected)

        if (appState.connecting || appState.connected) {
            droidstarRef.process_connect()
            return
        }

        if ((!appState.selectedHost || appState.selectedHost === "") && appState.hostsModel && appState.hostsModel.length > 0) {
            appState.selectedHost = appState.hostsModel[0]
        }

        droidstarRef.set_callsign(appState.callsign)
        droidstarRef.set_dmrid(appState.dmrid)
        droidstarRef.set_protocol(appState.mode)
        droidstarRef.set_module(appState.module)
        droidstarRef.set_essid(appState.essid)
        droidstarRef.set_bm_password(appState.bmPass)
        droidstarRef.set_tgif_password(appState.tgifPass)
        droidstarRef.set_latitude(appState.latitude)
        droidstarRef.set_longitude(appState.longitude)
        droidstarRef.set_location(appState.location)
        droidstarRef.set_description(appState.description)
        droidstarRef.set_url(appState.url)
        droidstarRef.set_swid(appState.swid)
        droidstarRef.set_pkgid(appState.pkgid)
        droidstarRef.set_dmr_options(appState.dmrOptions)
        droidstarRef.set_dmrtgid(appState.dmrtgid)
        if (appState.mycall && appState.mycall !== "") droidstarRef.set_mycall(appState.mycall)
        if (appState.urcall && appState.urcall !== "") droidstarRef.set_urcall(appState.urcall)
        if (appState.rptr1 && appState.rptr1 !== "") droidstarRef.set_rptr1(appState.rptr1)
        if (appState.rptr2 && appState.rptr2 !== "") droidstarRef.set_rptr2(appState.rptr2)
        if (appState.usrtxt && appState.usrtxt !== "") droidstarRef.set_usrtxt(appState.usrtxt)
        droidstarRef.set_txtimeout(appState.txTimeout)
        droidstarRef.set_modemRxFreq(appState.modemRxFreq)
        droidstarRef.set_modemTxFreq(appState.modemTxFreq)
        droidstarRef.set_modemRxOffset(appState.modemRxOffset)
        droidstarRef.set_modemTxOffset(appState.modemTxOffset)
        droidstarRef.set_modemRxDCOffset(appState.modemRxDCOffset)
        droidstarRef.set_modemTxDCOffset(appState.modemTxDCOffset)
        droidstarRef.set_modemRxLevel(appState.modemRxLevel)
        droidstarRef.set_modemTxLevel(appState.modemTxLevel)
        droidstarRef.set_modemRFLevel(appState.modemRFLevel)
        droidstarRef.set_modemTxDelay(appState.modemTxDelay)
        droidstarRef.set_modemCWIdTxLevel(appState.modemCWIdTxLevel)
        droidstarRef.set_modemDstarTxLevel(appState.modemDstarTxLevel)
        droidstarRef.set_modemDMRTxLevel(appState.modemDMRTxLevel)
        droidstarRef.set_modemYSFTxLevel(appState.modemYSFTxLevel)
        droidstarRef.set_modemP25TxLevel(appState.modemP25TxLevel)
        droidstarRef.set_modemNXDNTxLevel(appState.modemNXDNTxLevel)
        droidstarRef.set_modemBaud(appState.modemBaud)
        droidstarRef.set_ipv6(appState.ipv6)
        droidstarRef.set_xrf2ref(appState.xrf2ref)
        droidstarRef.set_toggletx(appState.toggleTx)
        droidstarRef.set_vocoder(appState.vocoder)
        droidstarRef.set_modem(appState.modem)
        droidstarRef.set_playback(appState.playback)
        droidstarRef.set_capture(appState.capture)
        droidstarRef.set_dmr_pc(appState.privateCall ? 1 : 0)

        if (appState.selectedHost && appState.selectedHost !== "") {
            droidstarRef.set_dst(appState.selectedHost)
            droidstarRef.process_host_change(appState.selectedHost)
        }

        droidstarRef.process_connect()
    }

    // The big round key: connect when idle, PTT when connected.
    function keyPressed() {
        if (!appState) return
        if (!connected) return
        if (!appState.toggleTx) droidstarRef.press_tx()
    }
    function keyReleased() {
        if (!appState || !connected) return
        if (!appState.toggleTx) droidstarRef.release_tx()
    }
    function keyClicked() {
        if (!appState) return
        if (!connected) { connectOrDisconnect(); return }
        if (appState.toggleTx) {
            appState.txActive = !appState.txActive
            droidstarRef.click_tx(appState.txActive)
        }
    }

    function statusText() {
        if (!appState) return ""
        if (onAir) return qsTr("On air")
        if (receiving) return qsTr("Receiving") + (rxElapsed !== "" ? "  " + rxElapsed : "")
        if (connected) return qsTr("Ready")
        if (connecting) return qsTr("Connecting…")
        return qsTr("Not connected")
    }

    background: Rectangle { color: t.bg }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.topMargin: 8
        anchors.bottomMargin: 16
        spacing: 14

        // ── Status strip: link state + host. Tap opens the connection & audio sheet. ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                width: 10; height: 10; radius: 5
                color: page.connected ? t.success : (page.connecting ? t.warning : t.stroke)
                SequentialAnimation on opacity {
                    running: page.connecting; loops: Animation.Infinite
                    NumberAnimation { to: 0.25; duration: 450 }
                    NumberAnimation { to: 1.0; duration: 450 }
                    onRunningChanged: if (!running) parent.opacity = 1
                }
            }

            ItemDelegate {
                Layout.fillWidth: true
                padding: 6
                contentItem: RowLayout {
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        text: (appState && appState.selectedHost !== "") ? appState.selectedHost : qsTr("Choose a server")
                        color: t.text
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Label {
                        text: appState ? appState.mode : ""
                        color: t.textMuted
                        font.pixelSize: 13
                    }
                    Label { text: "▾"; color: t.textMuted; font.pixelSize: 14 }
                }
                background: Rectangle { radius: 10; color: parent.down ? t.surface2 : "transparent" }
                onClicked: settingsSheet.open()
            }

            Button {
                visible: page.connected || page.connecting
                text: page.connecting ? qsTr("Cancel") : qsTr("Disconnect")
                flat: true
                font.pixelSize: 13
                contentItem: Label { text: parent.text; color: t.danger; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 16; color: "transparent"; border.color: Qt.rgba(t.danger.r, t.danger.g, t.danger.b, 0.6); border.width: 1; implicitHeight: 32 }
                onClicked: page.connectOrDisconnect()
            }
        }

        // ── Amber LCD: the talkgroup, like a radio's channel display. Tap to change. ──
        Rectangle {
            id: lcd
            Layout.fillWidth: true
            implicitHeight: lcdCol.implicitHeight + 28
            radius: 18
            gradient: Gradient {
                GradientStop { position: 0.0; color: t.lcdHi }
                GradientStop { position: 1.0; color: t.lcd }
            }
            border.color: "#B8761A"
            border.width: 2
            opacity: page.connected ? 1.0 : 0.82

            ColumnLayout {
                id: lcdCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        text: page.isTgMode ? ((appState && appState.privateCall) ? qsTr("Private call") : qsTr("Talkgroup"))
                                            : (appState ? appState.mode : "")
                        color: t.lcdInk
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        opacity: 0.8
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: page.statusText()
                        color: page.onAir ? "#8A1208" : t.lcdInk
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                }

                // 7-segment number with the unlit "8"s behind it, right aligned like a radio
                Item {
                    Layout.fillWidth: true
                    implicitHeight: ghost.implicitHeight
                    Label {
                        id: ghost
                        anchors.right: parent.right
                        text: "8888888"
                        font.family: segFont.name
                        font.pixelSize: Math.min(64, lcd.width / 6.2)
                        color: t.lcdGhost
                        opacity: 0.55
                    }
                    Label {
                        anchors.right: parent.right
                        text: page.isTgMode ? ((appState && appState.dmrtgid !== "") ? appState.dmrtgid : "-------")
                                            : (appState ? appState.module : "")
                        font.family: segFont.name
                        font.pixelSize: ghost.font.pixelSize
                        color: t.lcdInk
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        readonly property string nm: page.tgName(appState ? appState.dmrtgid : "")
                        readonly property bool hasTg: !!(appState && appState.dmrtgid !== "")
                        text: page.isTgMode ? (nm !== "" ? nm : (hasTg ? qsTr("Tap to change") : qsTr("Tap to choose a talkgroup")))
                                            : ((appState && appState.selectedHost) ? appState.selectedHost : "")
                        color: t.lcdInk
                        opacity: (page.isTgMode && nm === "") ? 0.7 : 1.0
                        font.pixelSize: (page.isTgMode && nm === "") ? 14 : 17
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    ToolButton {
                        visible: page.isTgMode
                        text: page.currentTgIsFavorite ? "★" : "☆"
                        font.pixelSize: 24
                        contentItem: Label { text: parent.text; color: t.lcdInk; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Item {}
                        Accessible.name: page.currentTgIsFavorite ? qsTr("Remove from favorites") : qsTr("Add to favorites")
                        onClicked: page.toggleCurrentFavorite()
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: 56   // leave the star tappable
                enabled: page.isTgMode
                onClicked: { tgField.text = appState ? appState.dmrtgid : ""; tgDialog.open() }
            }
        }

        // ── Channel presets: favorite talkgroups. Long press to reorder or remove. ──
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            visible: page.isTgMode && page.favoriteTgs.length > 0
            orientation: ListView.Horizontal
            spacing: 8
            clip: true
            model: page.favoriteTgs
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: !!(appState && ("" + appState.dmrtgid) === modelData.tg)
                height: 48
                width: Math.min(chipCol.implicitWidth + 28, 180)
                radius: 12
                color: active ? Qt.rgba(t.lcd.r, t.lcd.g, t.lcd.b, 0.16) : t.surface
                border.color: active ? t.lcd : t.stroke
                border.width: active ? 2 : 1

                Column {
                    id: chipCol
                    anchors.centerIn: parent
                    width: parent.width - 20
                    Label {
                        width: parent.width
                        text: modelData.tg
                        color: parent.parent.active ? t.lcd : t.text
                        font.pixelSize: 15
                        font.weight: Font.Bold
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Label {
                        width: parent.width
                        visible: !!modelData.name
                        text: modelData.name || ""
                        color: t.textMuted
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: page.selectTg(modelData.tg)
                    onPressAndHold: { chipMenu.tg = modelData.tg; chipMenu.idx = index; chipMenu.popup() }
                }
            }
        }

        Menu {
            id: chipMenu
            property string tg: ""
            property int idx: -1
            MenuItem { text: qsTr("Move left"); enabled: chipMenu.idx > 0; onTriggered: { droidstarRef.moveFavoriteTG(chipMenu.idx, chipMenu.idx - 1); page.refreshFavoriteTgs() } }
            MenuItem { text: qsTr("Move right"); enabled: chipMenu.idx >= 0 && chipMenu.idx < page.favoriteTgs.length - 1; onTriggered: { droidstarRef.moveFavoriteTG(chipMenu.idx, chipMenu.idx + 1); page.refreshFavoriteTgs() } }
            MenuItem { text: qsTr("Remove %1").arg(chipMenu.tg); onTriggered: { droidstarRef.removeFavoriteTG(chipMenu.tg); page.refreshFavoriteTgs() } }
        }

        // ── Who is talking (or who was last heard) ──
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 4

            Item { Layout.fillHeight: true; Layout.maximumHeight: 24 }

            RowLayout {
                spacing: 8
                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: page.onAir ? t.danger : (page.receiving ? t.success : t.stroke)
                }
                Label {
                    text: page.onAir ? qsTr("You are on air")
                          : (page.receiving ? qsTr("Talking now") : qsTr("Last heard"))
                    color: t.textMuted
                    font.pixelSize: 13
                }
            }

            Label {
                Layout.fillWidth: true
                text: {
                    if (!appState) return ""
                    if (page.onAir) return appState.callsign
                    if (page.receiving) return appState.data1.split(" - ")[0]
                    var lh = page.lastHeardOther
                    return lh !== "" ? lh.split(" - ")[0] : "—"
                }
                color: page.onAir ? t.danger : t.text
                font.pixelSize: 40
                font.weight: Font.Bold
                font.letterSpacing: 1
                elide: Text.ElideRight
            }

            Label {
                Layout.fillWidth: true
                text: {
                    if (!appState) return ""
                    if (page.receiving) {
                        var who = [appState.fetchedFirstName, appState.fetchedCountry].filter(function(s) { return !!s }).join(", ")
                        return who
                    }
                    if (page.onAir) return page.tgName(appState.dmrtgid)
                    var p = page.lastHeardOther.split(" - ")
                    return p.slice(1).join(", ")
                }
                color: t.textMuted
                font.pixelSize: 17
                elide: Text.ElideRight
            }

            Label {
                Layout.fillWidth: true
                visible: page.receiving && appState && appState.data2 !== ""
                text: appState ? ("ID " + appState.data2 + (appState.data3 !== "" ? "   → TG " + appState.data3 : "")) : ""
                color: t.textMuted
                font.pixelSize: 13
                opacity: 0.8
            }

            ReplayList {
                Layout.fillWidth: true
                Layout.topMargin: 6
                visible: !page.receiving && !page.onAir
                droidstarRef: page.droidstarRef
                maxItems: 1
            }

            Item { Layout.fillHeight: true }
        }

        // ── The key: connect when idle, push-to-talk when connected ──
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: keySize + 34
            readonly property real keySize: Math.min(page.width * 0.56, 230)

            // Level ring: grows with the audio level while receiving or transmitting
            Rectangle {
                anchors.centerIn: key
                width: key.width + 22
                height: width
                radius: width / 2
                color: "transparent"
                border.width: 4
                border.color: page.onAir ? t.danger : (page.receiving ? t.success : (page.connected ? Qt.rgba(t.success.r, t.success.g, t.success.b, 0.35) : "transparent"))
                scale: 1.0 + Math.min(0.12, (appState ? appState.outputLevel : 0) / 32767.0 * 0.5)
                Behavior on scale { NumberAnimation { duration: 90 } }
            }

            Rectangle {
                id: key
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 11
                width: parent.keySize
                height: width
                radius: width / 2
                color: page.onAir ? t.danger
                       : (page.connected ? t.surface2
                          : (page.connecting ? t.surface : t.accent))
                border.color: page.connected ? t.stroke : "transparent"
                border.width: 2
                scale: keyArea.pressed ? 0.96 : 1.0
                Behavior on scale { NumberAnimation { duration: 80 } }
                Behavior on color { ColorAnimation { duration: 120 } }

                Column {
                    anchors.centerIn: parent
                    spacing: 2
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: page.onAir ? qsTr("On air")
                              : (page.connected ? "PTT" : (page.connecting ? qsTr("Connecting…") : qsTr("Connect")))
                        color: page.connected && !page.onAir ? t.text : "white"
                        font.pixelSize: page.connected ? 34 : 22
                        font.weight: Font.Bold
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: page.connected && !page.onAir
                        text: appState ? ("TG " + appState.dmrtgid) : ""
                        color: t.textMuted
                        font.pixelSize: 13
                    }
                }

                MouseArea {
                    id: keyArea
                    anchors.fill: parent
                    enabled: !!appState && !page.connecting
                    onPressed: page.keyPressed()
                    onReleased: page.keyReleased()
                    onCanceled: page.keyReleased()
                    onClicked: page.keyClicked()
                }
            }

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                text: !page.connected ? (page.connecting ? "" : qsTr("Tap to connect to %1").arg(appState ? appState.selectedHost : ""))
                      : ((appState && appState.toggleTx) ? qsTr("Tap to toggle TX") : qsTr("Hold to transmit (PTT)"))
                color: t.textMuted
                font.pixelSize: 12
                elide: Text.ElideRight
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ── Talkgroup entry ──
    Dialog {
        id: tgDialog
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.min(page.width - 32, 380)
        title: qsTr("Talkgroup")
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: page.selectTg(tgField.text)

        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            TextField {
                id: tgField
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhDigitsOnly
                placeholderText: qsTr("Talkgroup ID")
                font.family: segFont.name
                font.pixelSize: 30
                horizontalAlignment: Text.AlignRight
                onAccepted: tgDialog.accept()
            }
            Label {
                Layout.fillWidth: true
                text: page.tgName(tgField.text)
                visible: text !== ""
                color: t.textMuted
                font.pixelSize: 14
            }
            Label {
                visible: !!(appState && appState.recentTgids && appState.recentTgids.length > 0)
                text: qsTr("Recent")
                color: t.textMuted
                font.pixelSize: 12
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: appState ? appState.recentTgids : []
                    delegate: Button {
                        required property var modelData
                        text: modelData
                        flat: true
                        onClicked: { tgField.text = modelData; page.lookupTgName(modelData) }
                    }
                }
            }
            RowLayout {
                visible: !!(appState && appState.mode === "DMR")
                Label { text: qsTr("Private call"); color: t.text; Layout.fillWidth: true }
                Switch {
                    checked: appState ? appState.privateCall : false
                    onToggled: { if (appState) appState.privateCall = checked; droidstarRef.set_dmr_pc(checked) }
                }
            }
        }
        onOpened: { tgField.forceActiveFocus(); tgField.selectAll() }
    }

    // ── Connection & audio sheet ──
    Drawer {
        id: settingsSheet
        edge: Qt.BottomEdge
        width: page.width
        height: Math.min(page.height * 0.8, sheetCol.implicitHeight + 48)
        background: Rectangle { color: t.surface; radius: 20 }

        Flickable {
            anchors.fill: parent
            anchors.margins: 16
            contentHeight: sheetCol.implicitHeight
            clip: true

            ColumnLayout {
                id: sheetCol
                width: parent.width
                spacing: 12

                Rectangle { Layout.alignment: Qt.AlignHCenter; width: 40; height: 5; radius: 3; color: t.stroke }

                Label { text: qsTr("Connection"); color: t.text; font.pixelSize: 18; font.weight: Font.Bold }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 8

                    Label { text: qsTr("Mode"); color: t.textMuted; font.pixelSize: 12 }
                    Label { text: qsTr("Host"); color: t.textMuted; font.pixelSize: 12 }

                    ComboBox {
                        id: modeComboBox
                        Layout.fillWidth: true
                        model: page.modesModel
                        property bool loaded: false
                        property bool updatingFromState: false
                        Component.onCompleted: { loaded = true; page.modeComboBoxRef = modeComboBox; updateFromState() }
                        function updateFromState() {
                            if (!appState || !loaded || updatingFromState) return
                            updatingFromState = true
                            var idx = model.indexOf(appState.mode)
                            currentIndex = idx >= 0 ? idx : 0
                            updatingFromState = false
                        }
                        onActivated: {
                            if (!appState || !loaded || updatingFromState) return
                            appState.mode = currentText
                            droidstarRef.process_mode_change(currentText)
                        }
                    }

                    ComboBox {
                        id: hostComboBox
                        Layout.fillWidth: true
                        model: appState ? (appState.hostsModel || []) : []
                        property bool loaded: false
                        property bool updatingFromState: false
                        displayText: currentIndex === -1 ? qsTr("Host...") : currentText
                        Component.onCompleted: { page.hostComboBoxRef = hostComboBox; loaded = true; updateSelection() }
                        onModelChanged: {
                            if (loaded && !updatingFromState) Qt.callLater(function() {
                                if (hostComboBox.loaded && !hostComboBox.updatingFromState) hostComboBox.updateSelection()
                            })
                        }
                        function updateSelection() {
                            if (!appState || !loaded || updatingFromState) return
                            if (model.length === 0) { currentIndex = -1; return }
                            updatingFromState = true
                            var idx = model.indexOf(appState.selectedHost)
                            if (idx >= 0 && idx !== currentIndex) currentIndex = idx
                            else if (idx < 0 && model.length > 0) { currentIndex = 0; if (appState) appState.selectedHost = model[0] }
                            updatingFromState = false
                        }
                        onActivated: {
                            if (!appState || !loaded || updatingFromState) return
                            appState.selectedHost = currentText
                            droidstarRef.set_dst(currentText)
                            if (!droidstarRef.get_modelchange()) droidstarRef.process_host_change(currentText)
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 10
                    rowSpacing: 4
                    visible: !!(appState && (appState.mode === "REF" || appState.mode === "DCS" || appState.mode === "XRF" || appState.mode === "M17" || appState.mode === "DMR"))

                    Label { visible: !!(appState && appState.mode !== "DMR"); text: qsTr("Module"); color: t.textMuted; font.pixelSize: 12 }
                    Label { visible: !!(appState && appState.mode === "DMR"); text: qsTr("Slot"); color: t.textMuted; font.pixelSize: 12 }
                    Label { visible: !!(appState && appState.mode === "DMR"); text: qsTr("CC"); color: t.textMuted; font.pixelSize: 12 }
                    Label { visible: !!(appState && appState.mode === "M17"); text: qsTr("CAN"); color: t.textMuted; font.pixelSize: 12 }

                    ComboBox {
                        Layout.fillWidth: true
                        visible: !!(appState && appState.mode !== "DMR")
                        model: page.modulesModel
                        currentIndex: appState ? Math.max(0, model.indexOf(appState.module)) : 0
                        onActivated: { if (!appState) return; appState.module = currentText; droidstarRef.set_module(currentText) }
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        visible: !!(appState && appState.mode === "DMR")
                        model: page.slotsModel
                        currentIndex: 1
                        onActivated: droidstarRef.set_slot(currentIndex)
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        visible: !!(appState && appState.mode === "DMR")
                        model: page.ccsModel
                        onActivated: droidstarRef.set_cc(currentIndex)
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        visible: !!(appState && appState.mode === "M17")
                        model: page.m17CanModel
                        onActivated: { if (!appState) return; appState.modemM17CAN = currentText; droidstarRef.set_modemM17CAN(currentText) }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: !!(appState && appState.mode === "IAX")
                    spacing: 8
                    TextField { id: dtmfField; Layout.fillWidth: true; placeholderText: qsTr("DTMF digits") }
                    Button { text: qsTr("Send"); onClicked: droidstarRef.dtmf_send_clicked(dtmfField.text) }
                }

                Button {
                    Layout.fillWidth: true
                    text: page.connecting ? qsTr("Cancel") : (page.connected ? qsTr("Disconnect") : qsTr("Connect"))
                    highlighted: !page.connected && !page.connecting
                    onClicked: { page.connectOrDisconnect(); settingsSheet.close() }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: t.stroke; Layout.topMargin: 4 }

                Label { text: qsTr("Audio"); color: t.text; font.pixelSize: 18; font.weight: Font.Bold }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Mic"); color: t.textMuted; font.pixelSize: 13 }
                    Slider {
                        Layout.fillWidth: true
                        from: 0.0; to: 1.0
                        value: appState ? appState.micGain : 0.5
                        onMoved: droidstarRef.set_input_volume(value)
                    }
                    Label { text: Math.round((appState ? appState.micGain : 0.5) * 100) + "%"; color: t.textMuted; font.pixelSize: 13; Layout.preferredWidth: 40 }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { label: "SWTX", prop: "swtx" },
                            { label: "SWRX", prop: "swrx" },
                            { label: "AGC",  prop: "agc" }
                        ]
                        delegate: Button {
                            required property var modelData
                            Layout.fillWidth: true
                            text: modelData.label
                            checkable: true
                            checked: !!(appState && appState[modelData.prop])
                            onClicked: {
                                if (!appState) return
                                var v = !appState[modelData.prop]
                                if (modelData.prop === "swtx") droidstarRef.set_swtx(v)
                                else if (modelData.prop === "swrx") droidstarRef.set_swrx(v)
                                else droidstarRef.set_agc(v)
                            }
                        }
                    }
                }
            }
        }
    }
}
