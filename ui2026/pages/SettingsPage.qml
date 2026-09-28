/*
    Copyright (C) 2025 Rohith Namboothiri

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

import "../theme"

// Settings, grouped by what the user wants to do (most used first):
// identity, push-to-talk, audio, location; then the rarely touched groups.
Page {
    id: page
    title: qsTr("Settings")
    padding: 0

    required property var droidstarRef
    required property var appState

    Tokens { id: t }

    // ─────────────────────────────────────────────────────────────────────
    // Building blocks (inline components: no extra files / .pro entries)
    // Inline components do not see the page's ids, so each carries its own
    // Tokens instance.
    // ─────────────────────────────────────────────────────────────────────

    // A group: bare header on the graphite body, rows on one surface block.
    // An open group gets the amber left edge, like the selected drawer item.
    component Section: ColumnLayout {
        id: sec
        property string title: ""
        property string summary: ""
        property bool expanded: false
        default property alias body: bodyCol.data
        readonly property Tokens tk: Tokens {}

        Layout.fillWidth: true
        spacing: 4

        ItemDelegate {
            id: head
            Layout.fillWidth: true
            implicitHeight: 60
            leftPadding: 18
            rightPadding: 12
            onClicked: sec.expanded = !sec.expanded
            Accessible.name: sec.title

            background: Rectangle {
                radius: 12
                color: head.down ? sec.tk.surface : "transparent"
                Rectangle {
                    visible: sec.expanded
                    width: 4
                    height: parent.height - 22
                    radius: 2
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: sec.tk.lcd
                }
            }

            contentItem: RowLayout {
                spacing: 10
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label {
                        Layout.fillWidth: true
                        text: sec.title
                        color: sec.tk.text
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: !sec.expanded && sec.summary !== ""
                        text: sec.summary
                        color: sec.tk.textMuted
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }
                Label {
                    text: ""
                    font.family: "FontAwesome"
                    font.pixelSize: 13
                    color: sec.tk.textMuted
                    rotation: sec.expanded ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.bottomMargin: 10
            visible: sec.expanded
            implicitHeight: bodyCol.implicitHeight + 8
            radius: 14
            color: sec.tk.surface
            border.color: sec.tk.stroke
            border.width: 1

            ColumnLayout {
                id: bodyCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 4
                spacing: 0
            }
        }
    }

    // One setting: title + optional hint on the left, control on the right.
    // stacked: control goes under the text at full width (chips, combos).
    component SettingRow: Item {
        id: row
        property string title: ""
        property string hint: ""
        property bool stacked: false
        default property alias control: slot.data
        readonly property Tokens tk: Tokens {}

        Layout.fillWidth: true
        implicitHeight: Math.max(58, grid.implicitHeight + 24)

        GridLayout {
            id: grid
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 16
            anchors.rightMargin: 12
            columns: row.stacked ? 1 : 2
            columnSpacing: 12
            rowSpacing: 10

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Label {
                    Layout.fillWidth: true
                    text: row.title
                    color: row.tk.text
                    font.pixelSize: 16
                    wrapMode: Text.WordWrap
                }
                Label {
                    Layout.fillWidth: true
                    visible: row.hint !== ""
                    text: row.hint
                    color: row.tk.textMuted
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }
            }

            RowLayout {
                id: slot
                Layout.fillWidth: row.stacked
                Layout.rightMargin: row.stacked ? 4 : 0
                spacing: 8
            }
        }
    }

    // Hairline between rows inside a group.
    component Rule: Rectangle {
        readonly property Tokens tk: Tokens {}
        Layout.fillWidth: true
        Layout.leftMargin: 16
        implicitHeight: 1
        color: tk.stroke
        opacity: 0.7
    }

    // Caption + input stacked, padded to line up with SettingRow text.
    component FieldBlock: ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 16
        Layout.rightMargin: 16
        Layout.topMargin: 10
        Layout.bottomMargin: 8
        spacing: 2
    }

    component Caption: Label {
        readonly property Tokens tk: Tokens {}
        color: tk.textMuted
        font.pixelSize: 13
    }

    // Material's outlined field floats the placeholder into its border, which
    // would collide with the Caption above; show the hint only while empty.
    component Input: TextField {
        id: inp
        property string hint: ""
        readonly property Tokens tk: Tokens {}
        placeholderText: (inp.text.length === 0 && !inp.activeFocus) ? inp.hint : ""
        Layout.fillWidth: true
        color: tk.text
        font.pixelSize: 16
    }

    // Eye toggle for password fields.
    component RevealButton: ToolButton {
        id: rb
        readonly property Tokens tk: Tokens {}
        checkable: true
        implicitWidth: 44
        implicitHeight: 44
        text: checked ? "" : ""
        font.family: "FontAwesome"
        font.pixelSize: 17
        Accessible.name: checked ? qsTr("Hide password") : qsTr("Show password")
        contentItem: Label {
            text: rb.text
            font: rb.font
            color: rb.checked ? rb.tk.lcd : rb.tk.textMuted
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Single choice as wrap-around chips; the selected one lights amber like
    // the active talkgroup on the main screen.
    component Chips: Flow {
        id: chips
        property var options: []
        property int current: 0
        signal picked(int index)
        readonly property Tokens tk: Tokens {}

        Layout.fillWidth: true
        spacing: 8

        Repeater {
            model: chips.options
            delegate: AbstractButton {
                id: chip
                required property int index
                required property string modelData
                readonly property bool sel: chips.current === index
                implicitHeight: 44
                implicitWidth: chipLabel.implicitWidth + 30
                Accessible.name: modelData
                onClicked: { chips.current = index; chips.picked(index) }

                background: Rectangle {
                    radius: 12
                    color: chip.sel ? Qt.rgba(chips.tk.lcd.r, chips.tk.lcd.g, chips.tk.lcd.b, 0.16)
                                    : (chip.down ? chips.tk.surface : chips.tk.surface2)
                    border.color: chip.sel ? chips.tk.lcd : chips.tk.stroke
                    border.width: 1
                }
                contentItem: Label {
                    id: chipLabel
                    text: chip.modelData
                    color: chip.sel ? chips.tk.lcd : chips.tk.text
                    font.pixelSize: 15
                    font.weight: chip.sel ? Font.DemiBold : Font.Normal
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    component ActionButton: Button {
        id: ab
        readonly property Tokens tk: Tokens {}
        implicitHeight: 48
        font.pixelSize: 15
        contentItem: Label {
            text: ab.text
            font: ab.font
            color: ab.enabled ? ab.tk.text : ab.tk.textMuted
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: 12
            color: ab.down ? ab.tk.surface : ab.tk.surface2
            border.color: ab.tk.stroke
            border.width: 1
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────

    // iOS keyboard/focus can skip onEditingFinished; debounce commits instead.
    Timer {
        id: commitTimer
        interval: 350
        repeat: false
        property var fn: null
        onTriggered: { if (fn) fn(); fn = null }
    }
    function scheduleCommit(f) {
        commitTimer.fn = f
        commitTimer.restart()
    }

    // Section expansion (kept while the page lives)
    property bool identityExpanded: true
    property bool pttExpanded: true
    property bool audioExpanded: false
    property bool subtitlesExpanded: false

    // Live subtitles (SubtitleController, droidStar.subtitles)
    readonly property var subs: (droidstarRef && droidstarRef.subtitles) ? droidstarRef.subtitles : null
    function subsModelText() {
        var s = page.subs
        if (!s || !s.supported) return qsTr("Needs iOS 26 or later")
        switch (s.modelStatus) {
        case "ready": return qsTr("Speech model ready (on this phone)")
        case "downloading": return qsTr("Downloading subtitle model… %1%").arg(Math.round(s.modelProgress * 100))
        case "checking": return qsTr("Checking speech model…")
        case "unsupported": return qsTr("Speech recognition for this language is not available on this phone")
        case "failed": return qsTr("Speech model download failed; it is retried when you turn subtitles on")
        default: return s.enabled ? qsTr("Checking speech model…") : qsTr("Off")
        }
    }
    function subsTranslationText() {
        var s = page.subs
        if (!s) return ""
        switch (s.translationStatus) {
        case "installed": return qsTr("English → Turkish pack installed")
        case "supported": return qsTr("English → Turkish pack not downloaded: subtitles stay in English")
        case "unsupported": return qsTr("Translation to Turkish is not available on this phone")
        default: return qsTr("Checking translation…")
        }
    }
    property bool locationExpanded: false
    property bool profileExpanded: false
    property bool languageExpanded: false
    property bool networkExpanded: false
    property bool dstarExpanded: false
    property bool modemExpanded: false
    property bool maintenanceExpanded: false
    property bool ttsExpanded: false

    // Models (legacy parity)
    readonly property var essidModel: (function(){
        var ids = ["None"];
        for (var i = 0; i < 100; i++) ids.push(i.toString().padStart(2, "0"));
        return ids;
    })()

    readonly property var rogerBeepOptions: [qsTr("Off"), qsTr("End only"), qsTr("Start and end"), qsTr("5-tone ANI (ZVEI)"), qsTr("Police radio (CCIR)")]
    readonly property var voiceToneOptions: [qsTr("Natural"), qsTr("Thin (300 Hz)"), qsTr("Very thin (500 Hz)")]
    // Index = DroidStar::set_hw_ptt_buttons value (bit 1 volume down, bit 2 volume up).
    readonly property var hwPttButtonOptions: [qsTr("Off"), qsTr("Volume down"), qsTr("Volume up"), qsTr("Both")]
    readonly property var hwPttModeOptions: [qsTr("Toggle"), qsTr("Hold to talk")]
    readonly property bool isIos: Qt.platform.os === "ios"

    // Phone GPS: the backend API may not exist yet in this build, so every
    // call is guarded and the page degrades to manual coordinates only.
    readonly property bool gpsApi: !!page.droidstarRef
                                   && typeof page.droidstarRef.get_use_phone_gps === "function"
                                   && typeof page.droidstarRef.set_use_phone_gps === "function"
    property bool usePhoneGps: false
    property string gpsStatus: ""
    function refreshGps() {
        if (!page.gpsApi) return
        page.usePhoneGps = !!page.droidstarRef.get_use_phone_gps()
        page.gpsStatus = (typeof page.droidstarRef.get_gps_status === "function")
                         ? String(page.droidstarRef.get_gps_status() || "") : ""
    }
    Component.onCompleted: refreshGps()

    Connections {
        target: page.gpsApi ? page.droidstarRef : null
        ignoreUnknownSignals: true
        function onGps_status_changed() { page.refreshGps() }
    }

    background: Rectangle { color: t.bg }

    // ─────────────────────────────────────────────────────────────────────
    // Page
    // ─────────────────────────────────────────────────────────────────────
    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentLayout.implicitHeight + 48
        clip: true

        ColumnLayout {
            id: contentLayout
            x: 16
            y: 12
            width: flick.width - 32
            spacing: 2

            // Station strip: the amber LCD from the main screen, showing who
            // this phone transmits as. Read-only; edit it in Identity below.
            Rectangle {
                Layout.fillWidth: true
                Layout.bottomMargin: 10
                implicitHeight: stationCol.implicitHeight + 24
                radius: 16
                gradient: Gradient {
                    GradientStop { position: 0.0; color: t.lcdHi }
                    GradientStop { position: 1.0; color: t.lcd }
                }

                ColumnLayout {
                    id: stationCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 0

                    Label {
                        text: qsTr("This station")
                        color: t.lcdInk
                        opacity: 0.75
                        font.pixelSize: 13
                    }
                    Label {
                        Layout.fillWidth: true
                        text: (page.appState && page.appState.callsign !== "") ? page.appState.callsign : qsTr("No callsign")
                        color: t.lcdInk
                        font.pixelSize: 30
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        text: {
                            if (!page.appState) return ""
                            var id = page.appState.dmrid !== "" ? page.appState.dmrid : "-"
                            var s = qsTr("DMR ID %1").arg(id)
                            if (page.appState.essid && page.appState.essid !== "None")
                                s += "  ·  " + qsTr("ESSID %1").arg(page.appState.essid)
                            return s
                        }
                        color: t.lcdInk
                        font.pixelSize: 15
                        font.family: "Menlo"
                        elide: Text.ElideRight
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // 1. IDENTITY
            // ─────────────────────────────────────────────────────────
            Section {
                title: qsTr("Identity")
                summary: page.appState ? (page.appState.callsign + "  ·  " + page.appState.dmrid) : ""
                expanded: page.identityExpanded
                onExpandedChanged: page.identityExpanded = expanded

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    FieldBlock {
                        Layout.rightMargin: 6
                        Caption { text: qsTr("Callsign") }
                        Input {
                            text: page.appState ? page.appState.callsign : ""
                            font.capitalization: Font.AllUppercase
                            inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhNoPredictiveText
                            hint: qsTr("e.g. W1AW")
                            onTextEdited: {
                                if (!page.appState) return
                                page.appState.callsign = text.toUpperCase()
                                page.scheduleCommit(function(){ page.droidstarRef.set_callsign(page.appState.callsign) })
                            }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.callsign = text.toUpperCase()
                                page.droidstarRef.set_callsign(page.appState.callsign)
                            }
                        }
                    }

                    FieldBlock {
                        Layout.leftMargin: 6
                        Caption { text: qsTr("DMR ID") }
                        Input {
                            text: page.appState ? page.appState.dmrid : ""
                            inputMethodHints: Qt.ImhDigitsOnly
                            hint: qsTr("7 digits")
                            onTextEdited: {
                                if (!page.appState) return
                                page.appState.dmrid = text
                                page.scheduleCommit(function(){ page.droidstarRef.set_dmrid(page.appState.dmrid) })
                            }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.dmrid = text
                                page.droidstarRef.set_dmrid(text)
                            }
                        }
                    }
                }

                Rule {}

                SettingRow {
                    title: qsTr("ESSID")
                    hint: qsTr("Suffix when you run more than one station on the same DMR ID")
                    ComboBox {
                        Layout.preferredWidth: 110
                        model: page.essidModel
                        currentIndex: page.appState ? Math.max(0, model.indexOf(page.appState.essid)) : 0
                        onActivated: {
                            if (!page.appState) return
                            page.appState.essid = currentText
                            page.droidstarRef.set_essid(currentText)
                        }
                    }
                }

                Rule {}

                SettingRow {
                    id: talkerAliasRow
                    property bool on: page.droidstarRef ? page.droidstarRef.get_talker_alias_on() : true
                    title: qsTr("Send talker alias")
                    hint: qsTr("Other radios show this text instead of only your DMR ID")
                    Switch {
                        checked: talkerAliasRow.on
                        onToggled: {
                            page.droidstarRef.set_talker_alias_on(checked)
                            talkerAliasRow.on = checked
                        }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    visible: talkerAliasRow.on
                    Caption { text: qsTr("Talker alias") }
                    Input {
                        text: page.droidstarRef ? page.droidstarRef.get_talker_alias() : ""
                        maximumLength: 27
                        inputMethodHints: Qt.ImhNoPredictiveText
                        hint: page.appState ? page.appState.callsign : ""
                        onEditingFinished: {
                            if (!page.droidstarRef) return
                            page.droidstarRef.set_talker_alias(text)
                        }
                    }
                }

                Rule {}

                FieldBlock {
                    Caption { text: qsTr("BrandMeister password") }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Input {
                            echoMode: bmReveal.checked ? TextInput.Normal : TextInput.Password
                            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                            text: page.appState ? page.appState.bmPass : ""
                            hint: qsTr("Brandmeister")
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.bmPass = text
                                page.droidstarRef.set_bm_password(text)
                            }
                        }
                        RevealButton { id: bmReveal }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("TGIF password") }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Input {
                            echoMode: tgifReveal.checked ? TextInput.Normal : TextInput.Password
                            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                            text: page.appState ? page.appState.tgifPass : ""
                            hint: qsTr("TGIF")
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.tgifPass = text
                                page.droidstarRef.set_tgif_password(text)
                            }
                        }
                        RevealButton { id: tgifReveal }
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // 2. PUSH-TO-TALK
            // ─────────────────────────────────────────────────────────
            Section {
                title: qsTr("Push-to-talk")
                summary: {
                    var s = (page.appState && page.appState.toggleTx) ? qsTr("Tap to talk") : qsTr("Hold to talk")
                    return s + "  ·  " + qsTr("Roger beep: %1").arg(page.rogerBeepOptions[rogerChips.current] || "")
                }
                expanded: page.pttExpanded
                onExpandedChanged: page.pttExpanded = expanded

                // Apple PushToTalk (iOS 16+)
                SettingRow {
                    id: pttRow
                    property bool on: page.droidstarRef ? page.droidstarRef.get_ptt_framework() : false
                    visible: !!(page.droidstarRef && page.droidstarRef.ptt_framework_available())
                    title: qsTr("System Push-to-Talk")
                    hint: qsTr("PTT button on lock screen & Dynamic Island, Bluetooth PTT accessories, shows who is talking")
                    Switch {
                        checked: pttRow.on
                        onToggled: {
                            page.droidstarRef.set_ptt_framework(checked)
                            pttRow.on = checked
                        }
                    }
                }
                Rule { visible: pttRow.visible }

                SettingRow {
                    id: headphoneRow
                    property bool on: page.droidstarRef ? page.droidstarRef.get_headphone_ptt() : false
                    title: qsTr("Headphone button keys TX")
                    hint: qsTr("Play/pause on headphones or lock screen toggles TX. Off = a tap on AirPods can't put you on air")
                    Switch {
                        checked: headphoneRow.on
                        onToggled: {
                            page.droidstarRef.set_headphone_ptt(checked)
                            headphoneRow.on = checked
                        }
                    }
                }
                Rule {}

                // Physical side buttons (iOS): volume keys as PTT while connected.
                SettingRow {
                    stacked: true
                    visible: page.isIos
                    title: qsTr("Side button keys TX")
                    hint: qsTr("While connected, the chosen volume button keys TX instead of changing the volume. Use Control Center for the volume meanwhile")
                    Chips {
                        id: hwButtonChips
                        options: page.hwPttButtonOptions
                        current: page.droidstarRef ? page.droidstarRef.get_hw_ptt_buttons() : 0
                        onPicked: function(index) { page.droidstarRef.set_hw_ptt_buttons(index) }
                    }
                }
                SettingRow {
                    stacked: true
                    visible: page.isIos && hwButtonChips.current > 0
                    title: qsTr("Side button mode")
                    hint: qsTr("Toggle: press once to talk, again to stop. Hold to talk: TX starts about half a second after you press and ends about half a second after you let go")
                    Chips {
                        options: page.hwPttModeOptions
                        current: page.droidstarRef ? page.droidstarRef.get_hw_ptt_mode() : 0
                        onPicked: function(index) { page.droidstarRef.set_hw_ptt_mode(index) }
                    }
                }
                SettingRow {
                    visible: page.isIos
                    title: qsTr("Action Button")
                    hint: qsTr("Settings → Action Button → Shortcut → DMR Cep: Bas-konuş. Works on the lock screen when System Push-to-Talk is on")
                }
                Rule { visible: page.isIos }

                SettingRow {
                    title: qsTr("Toggle TX mode")
                    hint: qsTr("Tap to toggle instead of hold-to-talk")
                    Switch {
                        checked: page.appState ? page.appState.toggleTx : false
                        onToggled: {
                            if (!page.appState) return
                            page.appState.toggleTx = checked
                            page.droidstarRef.set_toggletx(checked)
                        }
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("TX timeout")
                    hint: qsTr("Stops transmitting after this many seconds")
                    Input {
                        Layout.fillWidth: false
                        Layout.preferredWidth: 72
                        horizontalAlignment: Text.AlignRight
                        text: page.appState ? page.appState.txTimeout : ""
                        inputMethodHints: Qt.ImhDigitsOnly
                        onEditingFinished: {
                            page.appState.txTimeout = text
                            page.droidstarRef.set_txtimeout(text)
                        }
                    }
                    Caption { text: qsTr("s") }
                }
                Rule {}

                // Roger beep sent over the air
                SettingRow {
                    stacked: true
                    title: qsTr("Roger beep")
                    hint: qsTr("Short tone sent to the other side when you start and stop talking")
                    Chips {
                        id: rogerChips
                        options: page.rogerBeepOptions
                        current: page.droidstarRef ? page.droidstarRef.get_roger_beep() : 2
                        onPicked: function(index) { page.droidstarRef.set_roger_beep(index) }
                    }
                }
                Rule {}

                // TX voice tone (high-pass corner before the vocoder)
                SettingRow {
                    stacked: true
                    title: qsTr("Voice tone")
                    hint: qsTr("Cuts the low end of your voice before it is sent. Thinner sounds clearer on radios")
                    Chips {
                        options: page.voiceToneOptions
                        current: page.droidstarRef ? page.droidstarRef.get_tx_tone() : 1
                        onPicked: function(index) { page.droidstarRef.set_tx_tone(index) }
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // 3. AUDIO
            // ─────────────────────────────────────────────────────────
            Section {
                title: qsTr("Audio")
                summary: vocoderCombo.currentText !== "" ? qsTr("Vocoder: %1").arg(vocoderCombo.currentText) : ""
                expanded: page.audioExpanded
                onExpandedChanged: page.audioExpanded = expanded

                FieldBlock {
                    Caption { text: qsTr("Playback") }
                    ComboBox {
                        id: playbackCombo
                        Layout.fillWidth: true
                        model: page.droidstarRef.get_playbacks()
                        onActivated: {
                            page.droidstarRef.setPlaybackDevice(currentText)
                            page.droidstarRef.set_playback(currentText)
                        }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("Capture") }
                    ComboBox {
                        id: captureCombo
                        Layout.fillWidth: true
                        model: page.droidstarRef.get_captures()
                        onActivated: {
                            page.droidstarRef.setCaptureDevice(currentText)
                            page.droidstarRef.set_capture(currentText)
                        }
                    }
                }

                Rule {}

                FieldBlock {
                    Caption { text: qsTr("Vocoder") }
                    ComboBox {
                        id: vocoderCombo
                        Layout.fillWidth: true
                        model: page.droidstarRef.get_vocoders()
                        onActivated: page.droidstarRef.set_vocoder(currentText)
                    }
                    Caption {
                        Layout.fillWidth: true
                        text: page.appState && page.appState.ambestatus ? page.appState.ambestatus : ""
                        wrapMode: Text.WordWrap
                        visible: !!(page.appState && page.appState.ambestatus && page.appState.ambestatus !== "")
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // SUBTITLES (live captions of received overs, on-device)
            // ─────────────────────────────────────────────────────────
            Section {
                title: qsTr("Subtitles")
                summary: {
                    var s = page.subs
                    if (!s || !s.supported) return qsTr("Needs iOS 26 or later")
                    if (!s.enabled) return qsTr("Off")
                    return qsTr("TG %1").arg(s.talkgroups) + "  ·  "
                           + (s.language === "tr" ? qsTr("Turkish") : (s.translate && s.translationStatus === "installed" ? qsTr("English → Turkish") : qsTr("English")))
                }
                expanded: page.subtitlesExpanded
                onExpandedChanged: {
                    page.subtitlesExpanded = expanded
                    if (expanded && page.subs) page.subs.refreshStatus()
                }

                SettingRow {
                    title: qsTr("Live subtitles")
                    hint: page.subsModelText()
                    Switch {
                        enabled: !!(page.subs && page.subs.supported)
                        checked: !!(page.subs && page.subs.enabled)
                        onToggled: if (page.subs) page.subs.enabled = checked
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !!(page.subs && page.subs.supported && page.subs.enabled)
                    spacing: 0

                    Rule {}

                    FieldBlock {
                        Caption { text: qsTr("Talkgroups with subtitles") }
                        Input {
                            text: page.subs ? page.subs.talkgroups : "91"
                            inputMethodHints: Qt.ImhFormattedNumbersOnly | Qt.ImhNoPredictiveText
                            hint: qsTr("e.g. 91, 2862")
                            onEditingFinished: if (page.subs) { page.subs.talkgroups = text; text = page.subs.talkgroups }
                        }
                        Caption {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("Comma separated. Received overs on these talkgroups are transcribed on this phone; nothing is sent anywhere.")
                        }
                    }

                    Rule {}

                    SettingRow {
                        stacked: true
                        title: qsTr("Speech language")
                        hint: qsTr("English is translated to Turkish; Turkish is shown as spoken")
                        Chips {
                            options: [qsTr("English"), qsTr("Turkish")]
                            current: (page.subs && page.subs.language === "tr") ? 1 : 0
                            onPicked: function(i) { if (page.subs) page.subs.language = (i === 1 ? "tr" : "en") }
                        }
                    }

                    Rule {}

                    SettingRow {
                        visible: !!(page.subs && page.subs.language === "en")
                        title: qsTr("Translate to Turkish")
                        hint: page.subsTranslationText()
                        Switch {
                            checked: !!(page.subs && page.subs.translate)
                            onToggled: if (page.subs) page.subs.translate = checked
                        }
                    }

                    FieldBlock {
                        Layout.topMargin: 0
                        visible: !!(page.subs && page.subs.language === "en" && page.subs.translate
                                    && page.subs.translationStatus !== "installed" && page.subs.translationStatus !== "unsupported")
                        ActionButton {
                            Layout.fillWidth: true
                            text: qsTr("Download Turkish translation pack")
                            onClicked: page.subs.openTranslationDownload()
                        }
                    }

                    Rule { visible: !!(page.subs && page.subs.language === "en") }

                    SettingRow {
                        visible: !!(page.subs && page.subs.language === "en")
                        title: qsTr("Show original")
                        hint: qsTr("Small English text under the Turkish subtitle")
                        Switch {
                            checked: !!(page.subs && page.subs.showOriginal)
                            onToggled: if (page.subs) page.subs.showOriginal = checked
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // 4. LOCATION
            // ─────────────────────────────────────────────────────────
            Section {
                title: qsTr("Location")
                summary: page.usePhoneGps
                         ? (page.gpsStatus !== "" ? page.gpsStatus : qsTr("Phone location"))
                         : ((page.appState && page.appState.location !== "") ? page.appState.location : qsTr("Manual"))
                expanded: page.locationExpanded
                onExpandedChanged: page.locationExpanded = expanded

                SettingRow {
                    title: qsTr("Use phone location")
                    hint: page.gpsApi
                          ? (page.gpsStatus !== "" ? page.gpsStatus
                                                   : qsTr("Sends your position from the phone's GPS instead of the fields below"))
                          : qsTr("Not available in this version")
                    Switch {
                        enabled: page.gpsApi
                        checked: page.usePhoneGps
                        onToggled: {
                            if (!page.gpsApi) return
                            page.droidstarRef.set_use_phone_gps(checked)
                            page.usePhoneGps = checked
                            page.refreshGps()
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !page.usePhoneGps
                    spacing: 0

                    Rule {}

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        FieldBlock {
                            Layout.rightMargin: 6
                            Caption { text: qsTr("Latitude") }
                            Input {
                                text: page.appState ? page.appState.latitude : ""
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                hint: qsTr("e.g. 40.7128")
                                onEditingFinished: {
                                    page.appState.latitude = text
                                    page.droidstarRef.set_latitude(text)
                                }
                            }
                        }

                        FieldBlock {
                            Layout.leftMargin: 6
                            Caption { text: qsTr("Longitude") }
                            Input {
                                text: page.appState ? page.appState.longitude : ""
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                hint: qsTr("e.g. -74.0060")
                                onEditingFinished: {
                                    page.appState.longitude = text
                                    page.droidstarRef.set_longitude(text)
                                }
                            }
                        }
                    }

                    FieldBlock {
                        Layout.topMargin: 0
                        Caption { text: qsTr("Location") }
                        Input {
                            text: page.appState ? page.appState.location : ""
                            hint: qsTr("City, State/Country")
                            onEditingFinished: {
                                page.appState.location = text
                                page.droidstarRef.set_location(text)
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // Rarely changed
            // ─────────────────────────────────────────────────────────
            Label {
                Layout.topMargin: 18
                Layout.bottomMargin: 2
                Layout.leftMargin: 18
                text: qsTr("More")
                color: t.textMuted
                font.pixelSize: 14
            }

            // 5. STATION PROFILE
            Section {
                title: qsTr("Station profile")
                summary: qsTr("Description, URL, DMR options")
                expanded: page.profileExpanded
                onExpandedChanged: page.profileExpanded = expanded

                FieldBlock {
                    Caption { text: qsTr("Description") }
                    Input {
                        text: page.appState ? page.appState.description : ""
                        onEditingFinished: {
                            if (!page.appState) return
                            page.appState.description = text
                            page.droidstarRef.set_description(text)
                        }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("URL") }
                    Input {
                        text: page.appState ? page.appState.url : ""
                        inputMethodHints: Qt.ImhUrlCharactersOnly
                        hint: qsTr("https://...")
                        onEditingFinished: {
                            page.appState.url = text
                            page.droidstarRef.set_url(text)
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    FieldBlock {
                        Layout.topMargin: 0
                        Layout.rightMargin: 6
                        Caption { text: qsTr("SWID") }
                        Input {
                            text: page.appState ? page.appState.swid : ""
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.swid = text
                                page.droidstarRef.set_swid(text)
                            }
                        }
                    }

                    FieldBlock {
                        Layout.topMargin: 0
                        Layout.leftMargin: 6
                        Caption { text: qsTr("PKGID") }
                        Input {
                            text: page.appState ? page.appState.pkgid : ""
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.pkgid = text
                                page.droidstarRef.set_pkgid(text)
                            }
                        }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("DMR options") }
                    Input {
                        text: page.appState ? page.appState.dmrOptions : ""
                        onEditingFinished: {
                            page.appState.dmrOptions = text
                            page.droidstarRef.set_dmr_options(text)
                        }
                    }
                }

                Rule {}

                SettingRow {
                    stacked: true
                    title: qsTr("M17 / YSF rate")
                    Chips {
                        options: [qsTr("Voice Full"), qsTr("Voice/Data")]
                        current: 0
                        onPicked: function(index) { page.droidstarRef.m17_rate_changed(index === 0) }
                    }
                }
            }

            // 6. LANGUAGE (Turkish default, English optional) — applied live
            Section {
                title: qsTr("Language")
                summary: (typeof languageManager !== "undefined" && languageManager.language === "en") ? "English" : "Türkçe"
                expanded: page.languageExpanded
                onExpandedChanged: page.languageExpanded = expanded

                SettingRow {
                    stacked: true
                    title: qsTr("App language")
                    Chips {
                        options: ["Türkçe", "English"]
                        current: (typeof languageManager !== "undefined" && languageManager.language === "en") ? 1 : 0
                        onPicked: function(index) {
                            if (typeof languageManager !== "undefined") languageManager.setLanguage(index === 1 ? "en" : "tr")
                        }
                    }
                }
            }

            // 7. NETWORK
            Section {
                title: qsTr("Network")
                summary: {
                    var parts = []
                    if (autoConnectRow.on) parts.push(qsTr("Auto-connect"))
                    if (page.appState && page.appState.ipv6) parts.push(qsTr("IPv6"))
                    if (page.appState && page.appState.xrf2ref) parts.push(qsTr("XRF→REF"))
                    return parts.join("  ·  ")
                }
                expanded: page.networkExpanded
                onExpandedChanged: page.networkExpanded = expanded

                SettingRow {
                    id: autoConnectRow
                    property bool on: page.droidstarRef ? page.droidstarRef.get_auto_connect() : true
                    title: qsTr("Auto-connect on launch")
                    hint: qsTr("Connects to the last server and talk group when the app opens")
                    Switch {
                        checked: autoConnectRow.on
                        onToggled: {
                            page.droidstarRef.set_auto_connect(checked)
                            autoConnectRow.on = checked
                        }
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("IPv6")
                    hint: qsTr("Prefer IPv6 addresses when a server has one")
                    Switch {
                        checked: page.appState ? page.appState.ipv6 : false
                        onToggled: {
                            if (!page.appState) return
                            page.appState.ipv6 = checked
                            page.droidstarRef.set_ipv6(checked)
                        }
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("XRF→REF")
                    hint: qsTr("Reach XRF reflectors through their REF port")
                    Switch {
                        checked: page.appState ? page.appState.xrf2ref : false
                        onToggled: {
                            if (!page.appState) return
                            page.appState.xrf2ref = checked
                            page.droidstarRef.set_xrf2ref(checked)
                        }
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("Server list")
                    hint: qsTr("Download the latest host files")
                    ActionButton {
                        text: qsTr("Update Hosts")
                        onClicked: page.droidstarRef.update_host_files()
                    }
                }
            }

            // 8. D-STAR / ROUTING
            Section {
                title: qsTr("D-STAR routing")
                summary: qsTr("MYCALL, URCALL, repeaters, user text")
                expanded: page.dstarExpanded
                onExpandedChanged: page.dstarExpanded = expanded

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    FieldBlock {
                        Layout.rightMargin: 6
                        Caption { text: qsTr("MYCALL") }
                        Input {
                            id: mycallField
                            text: ""
                            font.capitalization: Font.AllUppercase
                            Component.onCompleted: { if (page.appState) text = page.appState.mycall }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.mycall = text.toUpperCase()
                                page.droidstarRef.set_mycall(page.appState.mycall)
                            }
                        }
                    }

                    FieldBlock {
                        Layout.leftMargin: 6
                        Caption { text: qsTr("URCALL") }
                        Input {
                            id: urcallField
                            text: ""
                            font.capitalization: Font.AllUppercase
                            Component.onCompleted: { if (page.appState) text = page.appState.urcall }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.urcall = text.toUpperCase()
                                page.droidstarRef.set_urcall(page.appState.urcall)
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    FieldBlock {
                        Layout.topMargin: 0
                        Layout.rightMargin: 6
                        Caption { text: qsTr("RPTR1") }
                        Input {
                            id: rptr1Field
                            text: ""
                            font.capitalization: Font.AllUppercase
                            Component.onCompleted: { if (page.appState) text = page.appState.rptr1 }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.rptr1 = text.toUpperCase()
                                page.droidstarRef.set_rptr1(page.appState.rptr1)
                            }
                        }
                    }

                    FieldBlock {
                        Layout.topMargin: 0
                        Layout.leftMargin: 6
                        Caption { text: qsTr("RPTR2") }
                        Input {
                            id: rptr2Field
                            text: ""
                            font.capitalization: Font.AllUppercase
                            Component.onCompleted: { if (page.appState) text = page.appState.rptr2 }
                            onEditingFinished: {
                                if (!page.appState) return
                                page.appState.rptr2 = text.toUpperCase()
                                page.droidstarRef.set_rptr2(page.appState.rptr2)
                            }
                        }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("User text") }
                    Input {
                        id: usrtxtField
                        text: ""
                        Component.onCompleted: { if (page.appState) text = page.appState.usrtxt }
                        onEditingFinished: {
                            if (!page.appState) return
                            page.appState.usrtxt = text
                            page.droidstarRef.set_usrtxt(text)
                        }
                    }
                }

                // Legacy parity: keep fields updated from backend signals.
                // Use explicit assignment so edits don't break live updates.
                Connections {
                    target: page.appState
                    enabled: !!page.appState
                    function onMycallChanged() { if (!mycallField.activeFocus) mycallField.text = page.appState.mycall }
                    function onUrcallChanged() { if (!urcallField.activeFocus) urcallField.text = page.appState.urcall }
                    function onRptr1Changed() { if (!rptr1Field.activeFocus) rptr1Field.text = page.appState.rptr1 }
                    function onRptr2Changed() { if (!rptr2Field.activeFocus) rptr2Field.text = page.appState.rptr2 }
                    function onUsrtxtChanged() { if (!usrtxtField.activeFocus) usrtxtField.text = page.appState.usrtxt }
                }
            }

            // 9. MODEM (advanced)
            Section {
                title: qsTr("Modem (advanced)")
                summary: qsTr("Hardware modem, MMDVM, levels and offsets")
                expanded: page.modemExpanded
                onExpandedChanged: page.modemExpanded = expanded

                FieldBlock {
                    Caption { text: qsTr("Modem") }
                    ComboBox {
                        id: modemCombo
                        Layout.fillWidth: true
                        model: page.droidstarRef.get_modems()
                        onActivated: page.droidstarRef.set_modem(currentText)
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("MMDVM Direct")
                    Switch {
                        checked: page.appState ? page.appState.mmdvmDirect : false
                        onToggled: {
                            if (!page.appState) return
                            page.appState.mmdvmDirect = checked
                            page.droidstarRef.set_mmdvm_direct(checked)
                        }
                    }
                }

                Caption {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.bottomMargin: 8
                    text: page.appState && page.appState.mmdvmstatus ? page.appState.mmdvmstatus : ""
                    wrapMode: Text.WordWrap
                    visible: !!(page.appState && page.appState.mmdvmstatus && page.appState.mmdvmstatus !== "")
                }
                Rule {}

                GridLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 6
                    Layout.bottomMargin: 8
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 0

                    Caption { text: qsTr("RX Freq") }
                    Input { text: page.appState ? page.appState.modemRxFreq : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemRxFreq=text; page.droidstarRef.set_modemRxFreq(text) } }

                    Caption { text: qsTr("TX Freq") }
                    Input { text: page.appState ? page.appState.modemTxFreq : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemTxFreq=text; page.droidstarRef.set_modemTxFreq(text) } }

                    Caption { text: qsTr("RX Offset") }
                    Input { text: page.appState ? page.appState.modemRxOffset : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemRxOffset=text; page.droidstarRef.set_modemRxOffset(text) } }

                    Caption { text: qsTr("TX Offset") }
                    Input { text: page.appState ? page.appState.modemTxOffset : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemTxOffset=text; page.droidstarRef.set_modemTxOffset(text) } }

                    Caption { text: qsTr("RX DC Offset") }
                    Input { text: page.appState ? page.appState.modemRxDCOffset : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemRxDCOffset=text; page.droidstarRef.set_modemRxDCOffset(text) } }

                    Caption { text: qsTr("TX DC Offset") }
                    Input { text: page.appState ? page.appState.modemTxDCOffset : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemTxDCOffset=text; page.droidstarRef.set_modemTxDCOffset(text) } }

                    Caption { text: qsTr("RX Level") }
                    Input { text: page.appState ? page.appState.modemRxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemRxLevel=text; page.droidstarRef.set_modemRxLevel(text) } }

                    Caption { text: qsTr("TX Level") }
                    Input { text: page.appState ? page.appState.modemTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemTxLevel=text; page.droidstarRef.set_modemTxLevel(text) } }

                    Caption { text: qsTr("RF Level") }
                    Input { text: page.appState ? page.appState.modemRFLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemRFLevel=text; page.droidstarRef.set_modemRFLevel(text) } }

                    Caption { text: qsTr("TX Delay") }
                    Input { text: page.appState ? page.appState.modemTxDelay : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemTxDelay=text; page.droidstarRef.set_modemTxDelay(text) } }

                    Caption { text: qsTr("CWID TX Level") }
                    Input { text: page.appState ? page.appState.modemCWIdTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemCWIdTxLevel=text; page.droidstarRef.set_modemCWIdTxLevel(text) } }

                    Caption { text: qsTr("D-STAR TX Level") }
                    Input { text: page.appState ? page.appState.modemDstarTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemDstarTxLevel=text; page.droidstarRef.set_modemDstarTxLevel(text) } }

                    Caption { text: qsTr("DMR TX Level") }
                    Input { text: page.appState ? page.appState.modemDMRTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemDMRTxLevel=text; page.droidstarRef.set_modemDMRTxLevel(text) } }

                    Caption { text: qsTr("YSF TX Level") }
                    Input { text: page.appState ? page.appState.modemYSFTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemYSFTxLevel=text; page.droidstarRef.set_modemYSFTxLevel(text) } }

                    Caption { text: qsTr("P25 TX Level") }
                    Input { text: page.appState ? page.appState.modemP25TxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemP25TxLevel=text; page.droidstarRef.set_modemP25TxLevel(text) } }

                    Caption { text: qsTr("NXDN TX Level") }
                    Input { text: page.appState ? page.appState.modemNXDNTxLevel : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemNXDNTxLevel=text; page.droidstarRef.set_modemNXDNTxLevel(text) } }

                    Caption { text: qsTr("Baud") }
                    Input { text: page.appState ? page.appState.modemBaud : ""; onEditingFinished: { if (!page.appState) return; page.appState.modemBaud=text; page.droidstarRef.set_modemBaud(text) } }
                }
            }

            // 10. MAINTENANCE
            Section {
                title: qsTr("Maintenance")
                summary: qsTr("ID files, downloads, debug")
                expanded: page.maintenanceExpanded
                onExpandedChanged: page.maintenanceExpanded = expanded

                SettingRow {
                    title: qsTr("DMR ID database")
                    hint: qsTr("Names shown for incoming callers")
                    ActionButton {
                        text: qsTr("Update ID Files")
                        onClicked: page.droidstarRef.update_dmr_ids()
                    }
                }
                Rule {}

                FieldBlock {
                    Caption { text: qsTr("Download file") }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Input {
                            id: downloadUrl
                            hint: qsTr("URL (vocoder/hosts/etc)")
                            inputMethodHints: Qt.ImhUrlCharactersOnly
                        }
                        ActionButton {
                            text: qsTr("Download")
                            enabled: downloadUrl.text !== ""
                            onClicked: page.droidstarRef.download_file(downloadUrl.text, true)
                        }
                    }
                }
                Rule {}

                SettingRow {
                    title: qsTr("Debug")
                    hint: qsTr("Extra detail in the log")
                    Switch {
                        checked: page.appState ? page.appState.debug : false
                        onToggled: {
                            if (!page.appState) return
                            page.appState.debug = checked
                            page.droidstarRef.set_debug(checked)
                        }
                    }
                }
            }

            // 11. TEXT-TO-SPEECH (only if USE_FLITE)
            Section {
                title: qsTr("Text-to-Speech")
                visible: (typeof USE_FLITE !== "undefined" && USE_FLITE)
                expanded: page.ttsExpanded
                onExpandedChanged: page.ttsExpanded = expanded

                SettingRow {
                    stacked: true
                    title: qsTr("Transmit source")
                    Chips {
                        options: [qsTr("None"), qsTr("Voice 1"), qsTr("Voice 2")]
                        current: 0
                        // Backend keys: "Mic" = microphone, "TTS1"/"TTS2" = synthetic voices.
                        onPicked: function(index) { page.droidstarRef.tts_changed(["Mic", "TTS1", "TTS2"][index]) }
                    }
                }

                FieldBlock {
                    Layout.topMargin: 0
                    Caption { text: qsTr("TTS Text") }
                    Input {
                        hint: qsTr("Text to speak")
                        onEditingFinished: page.droidstarRef.tts_text_changed(text)
                    }
                }
            }
        }
    }
}
