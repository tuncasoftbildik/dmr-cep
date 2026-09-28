/*
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

import "../theme"

// Saved channels sheet: the user's own talkgroup list and private-call contact list,
// each entry with a name the user chooses. Storage and name lookups live in the host
// (MainPage): saveChannel / removeChannel / moveChannel / selectChannel / suggestName ...
Drawer {
    id: root
    edge: Qt.BottomEdge
    modal: true

    property var host: null
    // "tg" = talkgroups, "pc" = private-call contacts
    property string kind: "tg"

    // Add / edit form; editId "" = adding a new entry.
    property bool formOpen: false
    property string editId: ""
    // Row whose delete button was tapped once (second tap deletes).
    property string armedDeleteId: ""

    Tokens { id: t }
    FontLoader { id: segFont; source: "qrc:/DroidStar/fonts/DSEG7Classic-Bold.ttf" }
    FontLoader { id: faFont; source: "qrc:/DroidStar/fontawesome-webfont.ttf" }

    background: Rectangle { color: t.surface; radius: 20 }

    readonly property var items: {
        if (!host) return []
        if (kind === "pc") return host.favoritePcs
        var out = []
        for (var i = 0; i < host.favoriteTgs.length; ++i)
            out.push({ id: host.favoriteTgs[i].tg, name: host.favoriteTgs[i].name })
        return out
    }
    readonly property int tgCount: host ? host.favoriteTgs.length : 0
    readonly property int pcCount: host ? host.favoritePcs.length : 0

    function openFor(k) {
        kind = (k === "pc") ? "pc" : "tg"
        closeForm()
        armedDeleteId = ""
        open()
    }

    function openForm(id, name) {
        armedDeleteId = ""
        editId = id || ""
        numField.text = editId
        nameField.text = name || ""
        lookupId = ""
        formOpen = true
        lookupTimer.stop()
        refreshLookup()
        if (editId === "") numField.forceActiveFocus()
        else nameField.forceActiveFocus()
    }

    function closeForm() {
        formOpen = false
        editId = ""
        numField.text = ""
        nameField.text = ""
        lookupId = ""
        numField.focus = false
        nameField.focus = false
    }

    function saveForm() {
        var id = numField.text.trim()
        if (!validNumber) return
        var name = nameField.text.trim()
        if (name === "") name = suggestion
        if (host.saveChannel(kind, editId, id, name)) closeForm()
    }

    // ---- Name suggestion while typing the number (debounced) ----
    property string lookupId: ""
    readonly property string typedId: numField.text.trim()
    readonly property bool validNumber: /^[0-9]+$/.test(typedId) && parseInt(typedId) > 0

    function refreshLookup() {
        lookupId = validNumber ? typedId : ""
        if (lookupId !== "" && host) host.lookupFor(kind, lookupId)
    }

    Timer { id: lookupTimer; interval: 400; onTriggered: root.refreshLookup() }

    readonly property string suggestion: {
        if (!host || lookupId === "" || lookupId !== typedId) return ""
        var a = host.tgNames, b = host.dmrIdNames
        return host.suggestName(kind, lookupId)
    }
    readonly property string suggestionState: {
        if (!host || lookupId === "" || lookupId !== typedId) return ""
        var a = host.tgLookupState, b = host.dmrIdLookupState
        return host.lookupState(kind, lookupId)
    }
    // Number already saved as another entry: saving updates that entry instead.
    readonly property bool duplicate: {
        if (!host || !validNumber || typedId === editId) return false
        var a = host.favoriteTgs, b = host.favoritePcs
        return host.isSaved(kind, typedId)
    }

    onClosed: { closeForm(); armedDeleteId = "" }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.topMargin: 10
        anchors.bottomMargin: 16 + (Qt.platform.os === "ios" ? 18 : 0)
        spacing: 12

        Rectangle { Layout.alignment: Qt.AlignHCenter; width: 40; height: 5; radius: 3; color: t.stroke }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label {
                Layout.fillWidth: true
                text: qsTr("Saved channels")
                color: t.text
                font.pixelSize: 20
                font.weight: Font.Bold
            }
            Button {
                visible: !root.formOpen
                text: qsTr("+ Add")
                highlighted: true
                onClicked: root.openForm("", "")
            }
        }

        // Segments: talkgroups / private-call contacts
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 40
            radius: 12
            color: t.bg
            border.color: t.stroke
            border.width: 1
            RowLayout {
                anchors.fill: parent
                anchors.margins: 3
                spacing: 3
                Repeater {
                    model: [
                        { k: "tg", label: qsTr("Talkgroups"), icon: "\uf0c0" },
                        { k: "pc", label: qsTr("Private call"), icon: "\uf007" }
                    ]
                    delegate: Rectangle {
                        id: seg
                        required property var modelData
                        readonly property bool selected: root.kind === modelData.k
                        readonly property color tint: modelData.k === "pc" ? t.accent : t.lcd
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 9
                        color: selected ? Qt.rgba(tint.r, tint.g, tint.b, 0.18) : "transparent"
                        border.color: selected ? tint : "transparent"
                        border.width: 1
                        Row {
                            anchors.centerIn: parent
                            spacing: 7
                            Label {
                                text: seg.modelData.icon
                                font.family: faFont.name
                                font.pixelSize: 13
                                color: seg.selected ? seg.tint : t.textMuted
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Label {
                                text: seg.modelData.label + "  " + (seg.modelData.k === "pc" ? root.pcCount : root.tgCount)
                                color: seg.selected ? t.text : t.textMuted
                                font.pixelSize: 14
                                font.weight: seg.selected ? Font.DemiBold : Font.Normal
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (root.kind === seg.modelData.k) return
                                root.closeForm()
                                root.armedDeleteId = ""
                                root.kind = seg.modelData.k
                            }
                        }
                    }
                }
            }
        }

        // ---- Add / edit form ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.formOpen
            implicitHeight: formCol.implicitHeight + 24
            radius: t.rSm
            color: t.surface2
            border.color: root.kind === "pc" ? Qt.rgba(t.accent.r, t.accent.g, t.accent.b, 0.5) : Qt.rgba(t.lcd.r, t.lcd.g, t.lcd.b, 0.5)
            border.width: 1

            ColumnLayout {
                id: formCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 8

                Label {
                    text: root.editId !== ""
                          ? (root.kind === "pc" ? qsTr("Edit contact") : qsTr("Edit talkgroup"))
                          : (root.kind === "pc" ? qsTr("New contact") : qsTr("New talkgroup"))
                    color: t.text
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }

                TextField {
                    id: numField
                    Layout.fillWidth: true
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,9}/ }
                    placeholderText: root.kind === "pc" ? qsTr("DMR ID") : qsTr("Talkgroup ID")
                    // 7-segment digits; the placeholder stays in the normal font so it is readable.
                    font.family: text.length > 0 ? segFont.name : root.font.family
                    font.pixelSize: text.length > 0 ? 26 : 17
                    horizontalAlignment: Text.AlignRight
                    onTextChanged: lookupTimer.restart()
                    onAccepted: nameField.forceActiveFocus()
                }

                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    placeholderText: root.suggestion !== "" ? root.suggestion : qsTr("Name (optional)")
                    font.pixelSize: 17
                    onAccepted: root.saveForm()
                }

                // Suggestion from BrandMeister (TG) or the DMR ID database (contact).
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: {
                            if (root.duplicate) return qsTr("Already saved; saving updates that entry.")
                            var st = root.suggestionState
                            if (st === "loading") return qsTr("Looking up…")
                            if (st === "missing") return root.kind === "pc" ? qsTr("Unknown DMR ID") : qsTr("Unknown talkgroup")
                            if (st === "error") return qsTr("Could not look up a name (offline?)")
                            if (root.suggestion !== "" && nameField.text.trim() === "") return qsTr("Leave empty to use this name")
                            return ""
                        }
                        color: root.duplicate || root.suggestionState === "missing" ? t.warning : t.textMuted
                        font.pixelSize: 12
                        font.italic: root.suggestionState === "loading"
                        wrapMode: Text.Wrap
                    }
                    Button {
                        visible: root.suggestion !== "" && nameField.text.trim() !== "" && nameField.text.trim() !== root.suggestion
                        flat: true
                        padding: 4
                        font.pixelSize: 12
                        text: qsTr("Use “%1”").arg(root.suggestion.length > 22 ? root.suggestion.substring(0, 21) + "…" : root.suggestion)
                        onClicked: nameField.text = root.suggestion
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.fillWidth: true }
                    Button {
                        text: qsTr("Cancel")
                        flat: true
                        onClicked: root.closeForm()
                    }
                    Button {
                        text: qsTr("Save")
                        highlighted: true
                        enabled: root.validNumber
                        onClicked: root.saveForm()
                    }
                }
            }
        }

        // ---- The list ----
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.items.length > 0
            clip: true
            spacing: 6
            model: root.items
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool isContact: root.kind === "pc"
                readonly property color tint: isContact ? t.accent : t.lcd
                readonly property bool active: root.host ? root.host.isActive(root.kind, modelData.id) : false
                readonly property bool armed: root.armedDeleteId === modelData.id
                readonly property string fallbackName: {
                    if (modelData.name || !root.host) return ""
                    var a = root.host.dmrIdNames, b = root.host.tgNames
                    return root.host.suggestName(root.kind, modelData.id)
                }

                width: ListView.view.width
                height: 62
                radius: 12
                color: active ? Qt.rgba(tint.r, tint.g, tint.b, 0.14) : t.bg
                border.color: active ? tint : t.stroke
                border.width: active ? 2 : 1

                // Tap the row = switch to this channel.
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.armedDeleteId = ""
                        if (!root.host) return
                        root.host.selectChannel(root.kind, row.modelData.id)
                        root.close()
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 4
                    spacing: 8

                    // Name on top (it is what the user chose), the number below in 7-segment digits.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Label {
                            Layout.fillWidth: true
                            text: row.modelData.name ? row.modelData.name
                                                     : (row.fallbackName !== "" ? row.fallbackName : qsTr("No name"))
                            color: row.modelData.name ? t.text : t.textMuted
                            font.italic: !row.modelData.name
                            font.pixelSize: 16
                            font.weight: row.modelData.name ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }
                        Row {
                            spacing: 6
                            Label {
                                visible: row.isContact
                                text: "\uf007"
                                font.family: faFont.name
                                font.pixelSize: 11
                                color: t.accent
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Label {
                                text: row.modelData.id
                                font.family: segFont.name
                                font.pixelSize: 14
                                color: row.active ? row.tint : Qt.rgba(row.tint.r, row.tint.g, row.tint.b, 0.8)
                            }
                        }
                    }

                    // Reorder: two small arrows stacked
                    Column {
                        spacing: 0
                        ToolButton {
                            width: 30; height: 26; padding: 0
                            enabled: row.index > 0
                            contentItem: Label { text: "\uf077"; font.family: faFont.name; font.pixelSize: 12; color: parent.enabled ? t.textMuted : Qt.rgba(t.textMuted.r, t.textMuted.g, t.textMuted.b, 0.25); horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            background: Item {}
                            Accessible.name: qsTr("Move up")
                            onClicked: { root.armedDeleteId = ""; root.host.moveChannel(root.kind, row.index, row.index - 1) }
                        }
                        ToolButton {
                            width: 30; height: 26; padding: 0
                            enabled: row.index < root.items.length - 1
                            contentItem: Label { text: "\uf078"; font.family: faFont.name; font.pixelSize: 12; color: parent.enabled ? t.textMuted : Qt.rgba(t.textMuted.r, t.textMuted.g, t.textMuted.b, 0.25); horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            background: Item {}
                            Accessible.name: qsTr("Move down")
                            onClicked: { root.armedDeleteId = ""; root.host.moveChannel(root.kind, row.index, row.index + 1) }
                        }
                    }
                    ToolButton {
                        implicitWidth: 40; implicitHeight: 44
                        visible: !row.armed
                        contentItem: Label { text: "\uf040"; font.family: faFont.name; font.pixelSize: 16; color: t.textMuted; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Item {}
                        Accessible.name: qsTr("Edit")
                        onClicked: root.openForm(row.modelData.id, row.modelData.name)
                    }
                    ToolButton {
                        implicitWidth: row.armed ? deleteLabel.implicitWidth + 20 : 40
                        implicitHeight: 44
                        contentItem: Label {
                            id: deleteLabel
                            text: row.armed ? qsTr("Delete") : "\uf1f8"
                            font.family: row.armed ? root.font.family : faFont.name
                            font.pixelSize: row.armed ? 14 : 16
                            font.weight: row.armed ? Font.DemiBold : Font.Normal
                            color: row.armed ? "white" : t.textMuted
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle { visible: row.armed; radius: 10; color: t.danger }
                        Accessible.name: qsTr("Delete")
                        onClicked: {
                            if (row.armed) {
                                root.armedDeleteId = ""
                                root.host.removeChannel(root.kind, row.modelData.id)
                            } else {
                                root.armedDeleteId = row.modelData.id
                            }
                        }
                    }
                }
            }
        }

        // ---- Empty state ----
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.items.length === 0
            spacing: 10

            Item { Layout.fillHeight: true; Layout.maximumHeight: 40 }
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.kind === "pc" ? "\uf007" : "\uf0c0"
                font.family: faFont.name
                font.pixelSize: 40
                color: root.kind === "pc" ? t.accent : t.lcd
                opacity: 0.8
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.kind === "pc" ? qsTr("No saved contacts yet") : qsTr("No saved talkgroups yet")
                color: t.text
                font.pixelSize: 17
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.kind === "pc"
                      ? qsTr("Save the DMR IDs you call privately, with the names you know them by. One tap then starts a private call.")
                      : qsTr("Save the talkgroups you use, with your own names. They appear as buttons on the main screen.")
                color: t.textMuted
                font.pixelSize: 14
                wrapMode: Text.Wrap
            }
            Button {
                Layout.alignment: Qt.AlignHCenter
                visible: !root.formOpen
                text: root.kind === "pc" ? qsTr("+ Add contact") : qsTr("+ Add talkgroup")
                highlighted: true
                onClicked: root.openForm("", "")
            }
            Item { Layout.fillHeight: true }
        }
    }
}
