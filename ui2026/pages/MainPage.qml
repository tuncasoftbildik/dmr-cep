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
    FontLoader { id: faFont; source: "qrc:/DroidStar/fontawesome-webfont.ttf" }

    property var modeComboBoxRef: null
    property var hostComboBoxRef: null

    readonly property bool isTgMode: !!(appState && (appState.mode === "DMR" || appState.mode === "P25" || appState.mode === "NXDN"))
    // Private call only exists in DMR; the destination is still appState.dmrtgid.
    readonly property bool isPc: !!(appState && appState.privateCall && appState.mode === "DMR")
    readonly property bool connected: !!(appState && appState.connected)
    readonly property bool connecting: !!(appState && appState.connecting)
    readonly property bool onAir: !!(appState && appState.txActive)
    readonly property bool receiving: connected && !onAir && !!(appState && appState.data1 !== "")
    // Link quality bars are measured by the DMR (HomeBrew) protocol only.
    readonly property var linkQuality: (appState && appState.linkQuality) ? appState.linkQuality : ({ bars: -1 })
    readonly property bool showLinkQuality: connected && !!(appState && appState.mode === "DMR")

    function lqValue(v, unit) { return (v === undefined || v < 0) ? "–" : (v + " " + unit) }
    // Loss shown next to the bars: last received transmission if measured, else ping loss.
    readonly property int lossPct: {
        var q = linkQuality
        if (!q) return -1
        if (q.rxLoss !== undefined && q.rxLoss >= 0) return Math.max(q.rxLoss, q.pingLoss >= 0 ? q.pingLoss : 0)
        return (q.pingLoss !== undefined) ? q.pingLoss : -1
    }

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
        function onDmrtgidChanged() { page.lookupCurrentName() }
        function onPrivateCallChanged() { page.lookupCurrentName() }
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
        if (droidstarRef && droidstarRef.get_auto_connect()) autoConnectTimer.start()
        refreshLastHeardFromLog()
        Qt.callLater(refreshFavorites)
        if (appState) Qt.callLater(lookupCurrentName)
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

    // Lookup status per TG: "loading" | "ok" | "missing" (BM 404 / no name) | "error" (network)
    property var tgLookupState: ({})

    function _setTgState(tg, st) { var s = tgLookupState; s[tg] = st; tgLookupState = s }

    function lookupTgName(tg) {
        tg = ("" + tg).trim()
        if (!/^[0-9]+$/.test(tg) || !appState || appState.mode !== "DMR") return
        // Retry after a network error; otherwise one request per TG.
        if (tgNames[tg] !== undefined && tgLookupState[tg] !== "error") return
        var cache = tgNames; cache[tg] = ""; tgNames = cache
        _setTgState(tg, "loading")
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var r = JSON.parse(xhr.responseText)
                    if (r && r.Name) {
                        var c = page.tgNames; c[tg] = r.Name; page.tgNames = c
                        page._setTgState(tg, "ok")
                        return
                    }
                } catch (e) {}
                page._setTgState(tg, "missing")
            } else if (xhr.status === 404) {
                page._setTgState(tg, "missing")
            } else {
                page._setTgState(tg, "error")
            }
        }
        xhr.open("GET", "https://api.brandmeister.network/v2/talkgroup/" + tg, true)
        xhr.send()
    }

    // ---- DMR user IDs (local DMRIDs.dat first, then radioid.net, cached) ----
    // id -> "CALL - Name"; "" = not found; key absent = not looked up yet.
    property var dmrIdNames: ({})
    property var dmrIdLookupState: ({})

    function _setDmrIdState(id, st) { var s = dmrIdLookupState; s[id] = st; dmrIdLookupState = s }
    function _setDmrIdName(id, nm) { var c = dmrIdNames; c[id] = nm; dmrIdNames = c }

    function lookupDmrUser(id) {
        id = ("" + id).trim()
        if (!/^[0-9]+$/.test(id)) return
        if (dmrIdNames[id] !== undefined && dmrIdLookupState[id] !== "error") return
        var local = droidstarRef && droidstarRef.lookupDmrId ? droidstarRef.lookupDmrId(parseInt(id)) : ""
        if (local) { _setDmrIdName(id, local); _setDmrIdState(id, "ok"); return }
        _setDmrIdName(id, "")
        _setDmrIdState(id, "loading")
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200) { page._setDmrIdState(id, xhr.status === 404 ? "missing" : "error"); return }
            try {
                var r = JSON.parse(xhr.responseText)
                if (r && r.results && r.results.length > 0) {
                    var u = r.results[0]
                    var nm = (u.fname || u.name || "").trim()
                    page._setDmrIdName(id, (u.callsign || "") + (nm ? " - " + nm : ""))
                    page._setDmrIdState(id, "ok")
                    return
                }
            } catch (e) {}
            page._setDmrIdState(id, "missing")
        }
        xhr.open("GET", "https://radioid.net/api/users?id=" + id, true)
        xhr.send()
    }

    // Callsign part of a "CALL - Name" entry.
    function dmrIdCallsign(id) {
        var v = dmrIdNames["" + id] || ""
        var i = v.indexOf(" - ")
        return i >= 0 ? v.substring(0, i) : v
    }

    // ---- Saved channels: talkgroups ("FavoriteTGs/list") and private-call contacts ("FavoritePCs/list") ----
    // favoriteTgs: [{tg, name}], favoritePcs: [{id, name}], in the user's order.
    property var favoriteTgs: []
    property var favoritePcs: []

    // Chip row / saved list model: talkgroups first, then contacts (DMR only).
    // Each entry: { kind: "tg" | "pc", id, name, idx (position in its own list), count }
    readonly property var channels: {
        var out = []
        var i
        for (i = 0; i < favoriteTgs.length; ++i)
            out.push({ kind: "tg", id: favoriteTgs[i].tg, name: favoriteTgs[i].name, idx: i, count: favoriteTgs.length })
        if (appState && appState.mode === "DMR") {
            for (i = 0; i < favoritePcs.length; ++i)
                out.push({ kind: "pc", id: favoritePcs[i].id, name: favoritePcs[i].name, idx: i, count: favoritePcs.length })
        }
        return out
    }

    // Is what the LCD shows (TG in group mode, ID in private call) saved?
    readonly property bool currentIsSaved: {
        if (!appState) return false
        var id = "" + appState.dmrtgid
        var list = isPc ? favoritePcs : favoriteTgs
        for (var i = 0; i < list.length; ++i)
            if ((isPc ? list[i].id : list[i].tg) === id) return true
        return false
    }

    function refreshFavorites() {
        if (!droidstarRef) return
        favoriteTgs = droidstarRef.loadFavoriteTGs()
        favoritePcs = droidstarRef.loadFavoritePCs()
    }
    // Kept for older call sites.
    function refreshFavoriteTgs() { refreshFavorites() }

    function savedName(kind, id) {
        id = "" + id
        var list = kind === "pc" ? favoritePcs : favoriteTgs
        for (var i = 0; i < list.length; ++i)
            if ((kind === "pc" ? list[i].id : list[i].tg) === id) return list[i].name || ""
        return ""
    }
    function isSaved(kind, id) {
        id = "" + id
        var list = kind === "pc" ? favoritePcs : favoriteTgs
        for (var i = 0; i < list.length; ++i)
            if ((kind === "pc" ? list[i].id : list[i].tg) === id) return true
        return false
    }

    // Saved contact name first, then the DMR ID database ("CALL - Name").
    function pcName(id) {
        id = "" + id
        return savedName("pc", id) || dmrIdNames[id] || ""
    }
    // Name for what the LCD currently shows.
    function currentName() {
        if (!appState) return ""
        return isPc ? pcName(appState.dmrtgid) : tgName(appState.dmrtgid)
    }
    function lookupCurrentName() {
        if (!appState) return
        if (isPc) lookupDmrUser(appState.dmrtgid)
        else lookupTgName(appState.dmrtgid)
    }

    // Automatic name suggestion: BrandMeister name for a TG, "CALL Firstname" for a DMR ID.
    function suggestName(kind, id) {
        id = "" + id
        if (kind === "pc") return (dmrIdNames[id] || "").replace(" - ", " ")
        return tgNames[id] || ""
    }
    function lookupFor(kind, id) {
        if (kind === "pc") lookupDmrUser(id)
        else lookupTgName(id)
    }
    // "" | "loading" | "ok" | "missing" | "error"
    function lookupState(kind, id) {
        id = "" + id
        return (kind === "pc" ? dmrIdLookupState[id] : tgLookupState[id]) || ""
    }

    function isActive(kind, id) {
        if (!appState || ("" + appState.dmrtgid) !== ("" + id)) return false
        return kind === "pc" ? isPc : !isPc
    }

    // Saved entries whose name was empty when saved; filled once the lookup answers.
    // Only an empty saved name is filled, so a name the user typed is never replaced.
    property var pendingAutoNames: []

    function queueAutoName(kind, id) {
        if (!appState || appState.mode !== "DMR") return
        var p = pendingAutoNames
        p.push({ kind: kind, id: "" + id })
        pendingAutoNames = p
        lookupFor(kind, id)
        resolvePendingNames()
    }

    function resolvePendingNames() {
        if (pendingAutoNames.length === 0 || !droidstarRef) return
        var keep = []
        var changed = false
        for (var i = 0; i < pendingAutoNames.length; ++i) {
            var p = pendingAutoNames[i]
            var st = lookupState(p.kind, p.id)
            if (st === "" || st === "loading") { keep.push(p); continue }
            var nm = suggestName(p.kind, p.id)
            if (nm === "") continue
            if (isSaved(p.kind, p.id) && savedName(p.kind, p.id) === "") {
                if (p.kind === "pc") droidstarRef.addFavoritePC(p.id, nm)
                else droidstarRef.addFavoriteTG(p.id, nm)
                changed = true
            }
            nameDialog.offerAutoName(p.kind, p.id, nm)
        }
        pendingAutoNames = keep
        if (changed) refreshFavorites()
    }
    onTgLookupStateChanged: resolvePendingNames()
    onDmrIdLookupStateChanged: resolvePendingNames()

    // Add or edit (rename and/or renumber) a saved channel. oldId "" = new entry.
    // An empty name is filled with the automatic name once it is known.
    function saveChannel(kind, oldId, newId, name) {
        if (!droidstarRef) return false
        newId = ("" + newId).trim()
        if (!/^[0-9]+$/.test(newId) || parseInt(newId) <= 0) return false
        name = ("" + name).trim()
        var from = (oldId && ("" + oldId) !== "") ? ("" + oldId) : newId
        var ok = kind === "pc" ? droidstarRef.updateFavoritePC(from, newId, name)
                               : droidstarRef.updateFavoriteTG(from, newId, name)
        refreshFavorites()
        if (ok && name === "") queueAutoName(kind, newId)
        return ok
    }
    function removeChannel(kind, id) {
        if (!droidstarRef) return
        if (kind === "pc") droidstarRef.removeFavoritePC(id)
        else droidstarRef.removeFavoriteTG(id)
        refreshFavorites()
    }
    function moveChannel(kind, from, to) {
        if (!droidstarRef) return
        if (kind === "pc") droidstarRef.moveFavoritePC(from, to)
        else droidstarRef.moveFavoriteTG(from, to)
        refreshFavorites()
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
    }

    // Pick a saved channel: a talkgroup switches to group call, a contact to private call.
    function selectChannel(kind, id) {
        if (!appState || !droidstarRef) return
        var pc = kind === "pc"
        if (!!appState.privateCall !== pc) {
            appState.privateCall = pc
            droidstarRef.set_dmr_pc(pc ? 1 : 0)
        }
        selectTg(id)
    }

    // The star on the LCD: save what is shown (TG in group mode, contact in private call)
    // and offer to name it right away; a second tap removes it.
    function toggleCurrentFavorite() {
        if (!appState || !droidstarRef) return
        var id = ("" + appState.dmrtgid).trim()
        if (!/^[0-9]+$/.test(id)) return
        var kind = isPc ? "pc" : "tg"
        if (isSaved(kind, id)) {
            removeChannel(kind, id)
            return
        }
        var auto = suggestName(kind, id)
        saveChannel(kind, "", id, auto)   // an empty name is queued for the auto name
        nameDialog.openFor(kind, id, auto)
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

        applyConnectionSettings()
        droidstarRef.process_connect()
    }

    // Push the current identity, host and TG to the backend before a connect.
    // Shared by the Connect button and the launch auto-connect.
    function applyConnectionSettings() {
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
    }

    // ---- Auto-connect on launch ----
    // ~1 s after the page first shows (audio session, PTT framework and network settle), connect
    // to the last server/TG like the Connect button would. The backend allows this once per
    // launch and never after the user has connected, cancelled or disconnected themselves.
    property bool autoConnecting: false
    property int _autoConnectTries: 0

    function autoConnectReady() {
        return !!appState && !!appState.selectedHost && appState.selectedHost !== ""
            && !!appState.callsign && appState.callsign !== ""
            && parseInt(appState.dmrid || "0") > 0
    }

    Timer {
        id: autoConnectTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (!page.droidstarRef || !page.appState) { stop(); return }
            // Hosts or identity may still be loading; give them a few more seconds.
            if (!page.autoConnectReady()) {
                if (++page._autoConnectTries >= 5) {
                    console.log("Auto-connect: skipped, no saved server/callsign/DMR ID")
                    stop()
                }
                return
            }
            stop()
            if (page.connected || page.connecting || !page.droidstarRef.take_launch_auto_connect()) return
            console.log("Auto-connect: connecting to " + page.appState.selectedHost)
            page.autoConnecting = true
            page.applyConnectionSettings()
            page.droidstarRef.process_auto_connect()
        }
    }

    Connections {
        target: page.appState
        enabled: page.autoConnecting
        function onConnectStatusChanged() {
            if (page.appState.connectStatus !== 1) page.autoConnecting = false
        }
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
        if (connecting) return autoConnecting ? qsTr("Auto-connecting…") : qsTr("Connecting…")
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
                z: 1   // above the LCD's tap area; only the signal bars and the star take touches

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    // Radio-style signal bars: network link quality. Tap for details.
                    SignalBars {
                        id: lqBars
                        visible: page.showLinkQuality
                        bars: page.linkQuality.bars
                        Layout.alignment: Qt.AlignVCenter
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -12   // comfortable touch target around the small bars
                            onClicked: lqPopup.open()
                            onPressAndHold: lqPopup.open()
                        }
                    }
                    Label {
                        visible: page.showLinkQuality && page.lossPct >= 0
                        text: qsTr("Loss %1%").arg(page.lossPct)
                        color: page.lossPct >= 5 ? "#8A1208" : t.lcdInk
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        opacity: 0.85
                        Layout.alignment: Qt.AlignVCenter
                        MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: lqPopup.open() }
                    }
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
                        // Private call: the contact's saved name, else the DMR ID lookup.
                        readonly property string nm: {
                            var a = page.dmrIdNames, b = page.tgNames, c = page.favoritePcs, d = page.favoriteTgs
                            return page.currentName()
                        }
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
                        text: page.currentIsSaved ? "★" : "☆"
                        font.pixelSize: 24
                        contentItem: Label { text: parent.text; color: t.lcdInk; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Item {}
                        Accessible.name: page.currentIsSaved ? qsTr("Remove from saved channels") : qsTr("Save channel")
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

            // Link quality details, dropped down from the signal bars.
            Popup {
                id: lqPopup
                x: 8
                y: lcdCol.y + lqBars.y + lqBars.height + 10
                padding: 14
                modal: false
                focus: true
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                background: Rectangle { radius: t.rSm; color: t.surface2; border.color: t.stroke; border.width: 1 }

                GridLayout {
                    columns: 2
                    columnSpacing: 16
                    rowSpacing: 4
                    Label {
                        Layout.columnSpan: 2
                        Layout.bottomMargin: 4
                        text: qsTr("Link quality: %1").arg(lqBars.label(page.linkQuality.bars))
                        color: t.text
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    Label { text: qsTr("Round trip"); color: t.textMuted; font.pixelSize: 13 }
                    Label {
                        text: page.linkQuality.rtt >= 0
                              ? qsTr("%1 ms (avg %2 ms)").arg(page.linkQuality.rtt).arg(page.linkQuality.rttAvg)
                              : "–"
                        color: t.text; font.pixelSize: 13
                    }
                    Label { text: qsTr("Ping loss"); color: t.textMuted; font.pixelSize: 13 }
                    Label { text: page.lqValue(page.linkQuality.pingLoss, "%"); color: t.text; font.pixelSize: 13 }
                    Label { text: qsTr("Last RX frame loss"); color: t.textMuted; font.pixelSize: 13 }
                    Label { text: page.lqValue(page.linkQuality.rxLoss, "%"); color: t.text; font.pixelSize: 13 }
                    Label { text: qsTr("RX jitter"); color: t.textMuted; font.pixelSize: 13 }
                    Label { text: page.lqValue(page.linkQuality.jitter, "ms"); color: t.text; font.pixelSize: 13 }
                }
            }
        }

        // ── Channel presets: saved talkgroups and private-call contacts. ──
        // Tap = switch to it (a contact switches to private call). Long press = reorder, rename, remove.
        // The button at the end opens the saved channels sheet ("+ Save channel" while the list is empty).
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            visible: page.isTgMode
            spacing: 8

            ListView {
                id: chipRow
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                visible: count > 0
                orientation: ListView.Horizontal
                spacing: 8
                clip: true
                model: page.channels
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool isContact: modelData.kind === "pc"
                    readonly property bool active: page.isActive(modelData.kind, modelData.id)
                    readonly property color tint: isContact ? t.accent : t.lcd
                    readonly property string subtitle: {
                        var dn = page.dmrIdNames
                        if (modelData.name) return modelData.name
                        return isContact ? page.dmrIdCallsign(modelData.id) : ""
                    }
                    height: 48
                    width: Math.max(64, Math.min(Math.max(chipNum.implicitWidth, chipSub.implicitWidth) + 28, 180))
                    radius: 12
                    color: active ? Qt.rgba(tint.r, tint.g, tint.b, 0.16)
                                  : (isContact ? Qt.rgba(t.accent.r, t.accent.g, t.accent.b, 0.07) : t.surface)
                    border.color: active ? tint : (isContact ? Qt.rgba(t.accent.r, t.accent.g, t.accent.b, 0.45) : t.stroke)
                    border.width: active ? 2 : 1

                    Column {
                        id: chipCol
                        anchors.centerIn: parent
                        width: parent.width - 20
                        Row {
                            id: chipNum
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 5
                            Label {
                                visible: chip.isContact
                                text: "\uf007"   // person
                                font.family: faFont.name
                                font.pixelSize: 12
                                color: t.accent
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Label {
                                text: chip.modelData.id
                                color: chip.active ? chip.tint : t.text
                                font.pixelSize: 15
                                font.weight: Font.Bold
                            }
                        }
                        Label {
                            id: chipSub
                            width: parent.width
                            visible: chip.subtitle !== ""
                            text: chip.subtitle
                            color: t.textMuted
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: page.selectChannel(chip.modelData.kind, chip.modelData.id)
                        onPressAndHold: chipMenu.openFor(chip.modelData)
                    }
                }
            }

            Rectangle {
                id: editChip
                Layout.preferredHeight: 48
                Layout.preferredWidth: chipRow.count > 0 ? 48 : editRow.implicitWidth + 32
                Layout.fillWidth: chipRow.count === 0
                radius: 12
                color: editArea.pressed ? t.surface2 : "transparent"
                border.color: t.stroke
                border.width: 1
                Accessible.name: qsTr("Saved channels")
                Row {
                    id: editRow
                    anchors.centerIn: parent
                    spacing: 8
                    Label {
                        text: chipRow.count > 0 ? "\uf03a" : "\uf067"   // list / plus
                        font.family: faFont.name
                        font.pixelSize: 16
                        color: t.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Label {
                        visible: chipRow.count === 0
                        text: qsTr("Save channel")
                        color: t.textMuted
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: editArea
                    anchors.fill: parent
                    onClicked: channelsSheet.openFor(page.isPc ? "pc" : "tg")
                }
            }
        }

        Menu {
            id: chipMenu
            property string kind: "tg"
            property string chId: ""
            property string chName: ""
            property int idx: -1
            property int chCount: 0
            function openFor(ch) {
                kind = ch.kind; chId = ch.id; chName = ch.name || ""; idx = ch.idx; chCount = ch.count
                popup()
            }
            MenuItem { text: qsTr("Rename"); onTriggered: nameDialog.openFor(chipMenu.kind, chipMenu.chId, chipMenu.chName, true) }
            MenuItem { text: qsTr("Move left"); enabled: chipMenu.idx > 0; onTriggered: page.moveChannel(chipMenu.kind, chipMenu.idx, chipMenu.idx - 1) }
            MenuItem { text: qsTr("Move right"); enabled: chipMenu.idx >= 0 && chipMenu.idx < chipMenu.chCount - 1; onTriggered: page.moveChannel(chipMenu.kind, chipMenu.idx, chipMenu.idx + 1) }
            MenuItem { text: qsTr("Edit list"); onTriggered: channelsSheet.openFor(chipMenu.kind) }
            MenuItem { text: qsTr("Remove %1").arg(chipMenu.chId); onTriggered: page.removeChannel(chipMenu.kind, chipMenu.chId) }
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

            // DMR Talker Alias the other station sends (e.g. "TB1BDL Tunca"), when it differs
            // from the callsign shown above.
            Label {
                Layout.fillWidth: true
                readonly property string alias: (page.appState && page.receiving && page.appState.mode === "DMR") ? page.appState.data6 : ""
                visible: alias !== "" && alias !== page.appState.data1.split(" - ")[0]
                text: "“" + alias + "”"
                color: t.text
                font.pixelSize: 17
                font.weight: Font.Medium
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
                    if (page.onAir) return page.currentName()
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
                excludeOwn: true
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
                        text: appState ? ((page.isPc ? "PC " : "TG ") + appState.dmrtgid) : ""
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

        readonly property bool isDmr: !!(appState && appState.mode === "DMR")
        readonly property bool pcMode: isDmr && pcSwitch.checked
        // Debounced copy of tgField.text; the preview only resolves this value.
        property string previewId: ""
        readonly property string typedId: tgField.text.trim()
        readonly property bool previewPending: typedId !== previewId

        function refreshPreview() {
            previewId = typedId
            if (!/^[0-9]+$/.test(previewId)) return
            if (pcMode) {
                page.lookupDmrUser(previewId)
            } else {
                page.lookupTgName(previewId)
                // 7 digits in group mode: probably a DMR user ID typed by mistake.
                if (isDmr && previewId.length === 7) page.lookupDmrUser(previewId)
            }
        }

        // Preview line: { kind: "" | "loading" | "ok" | "unknown" | "error", text }
        readonly property var preview: {
            var id = previewId
            // Touch the caches so the binding re-evaluates when lookups finish.
            var tn = page.tgNames, ts = page.tgLookupState, dn = page.dmrIdNames, ds = page.dmrIdLookupState
            if (id === "" || previewPending || !/^[0-9]+$/.test(id)) return { kind: "", text: "" }
            if (pcMode) {
                var st = ds[id]
                if (st === "ok") return { kind: "ok", text: dn[id] }
                if (st === "loading") return { kind: "loading", text: qsTr("Looking up…") }
                if (st === "missing") return { kind: "unknown", text: qsTr("Unknown DMR ID") }
                if (st === "error") return { kind: "error", text: qsTr("Could not check DMR ID (offline?)") }
                return { kind: "", text: "" }
            }
            var fav = page.tgName(id)
            if (fav !== "") return { kind: "ok", text: fav }
            if (!isDmr) return { kind: "", text: "" }
            var s2 = ts[id]
            if (s2 === "loading") return { kind: "loading", text: qsTr("Looking up…") }
            if (s2 === "missing") return { kind: "unknown", text: qsTr("Unknown talkgroup") }
            if (s2 === "error") return { kind: "error", text: qsTr("Could not check talkgroup (offline?)") }
            return { kind: "", text: "" }
        }

        // Callsign when a 7-digit group-call number resolves as a DMR user ID.
        readonly property string dmrIdHintCall: {
            var ds = page.dmrIdLookupState, dn = page.dmrIdNames
            if (!isDmr || pcMode || previewPending || previewId.length !== 7) return ""
            return ds[previewId] === "ok" ? page.dmrIdCallsign(previewId) : ""
        }

        Timer {
            id: tgPreviewTimer
            interval: 400
            onTriggered: tgDialog.refreshPreview()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            TextField {
                id: tgField
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhDigitsOnly
                placeholderText: tgDialog.pcMode ? qsTr("DMR ID") : qsTr("Talkgroup ID")
                font.family: segFont.name
                font.pixelSize: 30
                horizontalAlignment: Text.AlignRight
                onAccepted: tgDialog.accept()
                onTextChanged: tgPreviewTimer.restart()
            }
            // Live name preview; reserves its height so the dialog does not jump while typing.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(36, previewLabel.implicitHeight + 16)
                radius: t.rSm
                color: tgDialog.preview.kind === "unknown" ? Qt.rgba(t.warning.r, t.warning.g, t.warning.b, 0.14) : t.surface2
                border.width: tgDialog.preview.kind === "unknown" ? 1 : 0
                border.color: t.warning
                opacity: tgDialog.preview.kind === "" ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Label {
                    id: previewLabel
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.Wrap
                    text: (tgDialog.preview.kind === "unknown" ? "⚠ " : "") + tgDialog.preview.text
                    color: tgDialog.preview.kind === "ok" ? t.lcd
                         : tgDialog.preview.kind === "unknown" ? t.warning
                         : t.textMuted
                    font.pixelSize: tgDialog.preview.kind === "ok" || tgDialog.preview.kind === "unknown" ? 16 : 13
                    font.bold: tgDialog.preview.kind === "ok" || tgDialog.preview.kind === "unknown"
                    font.italic: tgDialog.preview.kind === "loading"
                }
            }
            // "Looks like a DMR ID" hint with a one-tap switch to private call.
            Rectangle {
                Layout.fillWidth: true
                visible: tgDialog.dmrIdHintCall !== ""
                implicitHeight: hintRow.implicitHeight + 16
                radius: t.rSm
                color: Qt.rgba(t.warning.r, t.warning.g, t.warning.b, 0.14)
                border.width: 1
                border.color: t.warning
                RowLayout {
                    id: hintRow
                    anchors.fill: parent
                    anchors.margins: 8
                    anchors.leftMargin: 12
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("This looks like a DMR ID (%1). Private call?").arg(tgDialog.dmrIdHintCall)
                        color: t.warning
                        wrapMode: Text.Wrap
                        font.pixelSize: 13
                    }
                    Button {
                        text: qsTr("Private call")
                        highlighted: true
                        onClicked: {
                            pcSwitch.checked = true
                            if (appState) appState.privateCall = true
                            droidstarRef.set_dmr_pc(true)
                            tgDialog.refreshPreview()
                        }
                    }
                }
            }
            // Saved channels: tap to switch straight to one (contacts switch to private call).
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label {
                    Layout.fillWidth: true
                    text: page.channels.length > 0 ? qsTr("Saved") : qsTr("No saved channels yet")
                    color: t.textMuted
                    font.pixelSize: 12
                }
                Button {
                    flat: true
                    padding: 4
                    text: page.channels.length > 0 ? qsTr("Manage") : qsTr("+ Save channel")
                    font.pixelSize: 12
                    onClicked: {
                        var k = tgDialog.pcMode ? "pc" : "tg"
                        tgDialog.close()
                        channelsSheet.openFor(k)
                    }
                }
            }
            Flickable {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(savedFlow.implicitHeight, 132)
                visible: page.channels.length > 0
                contentHeight: savedFlow.implicitHeight
                clip: true
                Flow {
                    id: savedFlow
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: page.channels
                        delegate: Button {
                            id: savedBtn
                            required property var modelData
                            readonly property bool isContact: modelData.kind === "pc"
                            flat: true
                            highlighted: page.isActive(modelData.kind, modelData.id)
                            contentItem: Column {
                                spacing: 0
                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 4
                                    Label {
                                        visible: savedBtn.isContact
                                        text: "\uf007"
                                        font.family: faFont.name
                                        font.pixelSize: 11
                                        color: t.accent
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Label {
                                        text: savedBtn.modelData.id
                                        font.family: segFont.name
                                        font.pixelSize: 15
                                        color: savedBtn.isContact ? t.accent : t.lcd
                                    }
                                }
                                Label {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: !!savedBtn.modelData.name
                                    text: savedBtn.modelData.name || ""
                                    width: Math.min(implicitWidth, 120)
                                    elide: Text.ElideRight
                                    horizontalAlignment: Text.AlignHCenter
                                    font.pixelSize: 10
                                    color: t.textMuted
                                }
                            }
                            onClicked: {
                                page.selectChannel(modelData.kind, modelData.id)
                                tgDialog.close()
                            }
                        }
                    }
                }
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
                        id: recentBtn
                        required property var modelData
                        readonly property string nm: {
                            var tn = page.tgNames, dn = page.dmrIdNames
                            return page.tgName(modelData) || dn["" + modelData] || ""
                        }
                        flat: true
                        contentItem: Column {
                            spacing: 0
                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: recentBtn.modelData
                                font.family: segFont.name
                                font.pixelSize: 15
                                color: t.text
                            }
                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: recentBtn.nm !== ""
                                text: recentBtn.nm
                                width: Math.min(implicitWidth, 120)
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: 10
                                color: t.textMuted
                            }
                        }
                        onClicked: { tgField.text = modelData; tgDialog.refreshPreview() }
                    }
                }
            }
            RowLayout {
                visible: tgDialog.isDmr
                Label { text: qsTr("Private call"); color: t.text; Layout.fillWidth: true }
                Switch {
                    id: pcSwitch
                    checked: appState ? appState.privateCall : false
                    onToggled: {
                        if (appState) appState.privateCall = checked
                        droidstarRef.set_dmr_pc(checked)
                        tgDialog.refreshPreview()
                    }
                }
            }
        }
        onOpened: {
            pcSwitch.checked = appState ? appState.privateCall : false
            tgField.forceActiveFocus()
            tgField.selectAll()
            tgPreviewTimer.stop()
            refreshPreview()
            // Resolve names for the recent buttons.
            var rec = appState && appState.recentTgids ? appState.recentTgids : []
            for (var i = 0; i < rec.length; ++i) {
                page.lookupTgName(rec[i])
                if (isDmr && ("" + rec[i]).length === 7) page.lookupDmrUser(rec[i])
            }
        }
    }

    // ── Name a saved channel (right after ★, or "Rename" on a chip) ──
    Dialog {
        id: nameDialog
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.min(page.width - 32, 360)
        title: rename ? (kind === "pc" ? qsTr("Rename contact") : qsTr("Rename talkgroup"))
                      : (kind === "pc" ? qsTr("Contact saved") : qsTr("Talkgroup saved"))

        property string kind: "tg"
        property string chId: ""
        property bool rename: false
        // Set once the user types, so a late automatic name never replaces their text.
        property bool userEdited: false

        function openFor(k, id, name, isRename) {
            kind = k
            chId = "" + id
            rename = !!isRename
            userEdited = false
            nameEdit.text = name || ""
            open()
        }
        // Called when an automatic name arrives after the dialog opened.
        function offerAutoName(k, id, name) {
            if (!visible || k !== kind || ("" + id) !== chId || userEdited || nameEdit.text !== "") return
            nameEdit.text = name
        }

        onOpened: { nameEdit.forceActiveFocus(); nameEdit.selectAll() }
        onAccepted: page.saveChannel(kind, chId, chId, nameEdit.text)

        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: nameDialog.kind === "pc" ? "\uf007" : ""
                    visible: nameDialog.kind === "pc"
                    font.family: faFont.name
                    font.pixelSize: 16
                    color: t.accent
                }
                Label {
                    text: nameDialog.chId
                    font.family: segFont.name
                    font.pixelSize: 24
                    color: nameDialog.kind === "pc" ? t.accent : t.lcd
                }
                Item { Layout.fillWidth: true }
            }
            TextField {
                id: nameEdit
                Layout.fillWidth: true
                placeholderText: nameDialog.kind === "pc" ? qsTr("Name, e.g. Ahmet (TA1ABC)") : qsTr("Name, e.g. Club net")
                font.pixelSize: 17
                onTextEdited: nameDialog.userEdited = true
                onAccepted: nameDialog.accept()
            }
            Label {
                Layout.fillWidth: true
                text: qsTr("Give it any name you like. Leave it empty to use the automatic name.")
                color: t.textMuted
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }

        footer: DialogButtonBox {
            Button { text: qsTr("Cancel", "name dialog"); flat: true; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            Button { text: qsTr("Save"); highlighted: true; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
    }

    // ── Saved channels: manage talkgroups and private-call contacts ──
    ChannelsSheet {
        id: channelsSheet
        host: page
        width: page.width
        height: page.height * 0.88
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
                    Label { text: qsTr("Voice tone"); color: t.textMuted; font.pixelSize: 13; Layout.fillWidth: true }
                    ComboBox {
                        Layout.preferredWidth: 190
                        model: [qsTr("Natural"), qsTr("Thin (300 Hz)"), qsTr("Very thin (500 Hz)")]
                        currentIndex: droidstarRef ? droidstarRef.get_tx_tone() : 1
                        onActivated: function(index) { droidstarRef.set_tx_tone(index) }
                    }
                }

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
