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
import QtQuick.Controls.Material

import "../theme"

// Navigation row: icon + label; the current page gets an amber edge like the radio LCD.
ItemDelegate {
    id: root

    property alias iconText: iconItem.text
    property alias iconFont: iconItem.font.family

    Tokens { id: t }

    width: ListView.view ? ListView.view.width : implicitWidth
    height: 52

    contentItem: Row {
        spacing: 16
        leftPadding: 6
        anchors.verticalCenter: parent.verticalCenter

        Text {
            id: iconItem
            font.pointSize: 16
            color: root.highlighted ? t.lcd : t.textMuted
            width: 24
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
        }

        Label {
            text: root.text
            color: root.highlighted ? t.text : Qt.rgba(t.text.r, t.text.g, t.text.b, 0.85)
            font.pixelSize: 17
            font.weight: root.highlighted ? Font.DemiBold : Font.Normal
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    background: Rectangle {
        radius: 12
        color: root.highlighted ? Qt.rgba(t.lcd.r, t.lcd.g, t.lcd.b, 0.12)
                                : (root.down ? t.surface : "transparent")
        Rectangle {
            visible: root.highlighted
            width: 4
            height: parent.height - 18
            radius: 2
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: t.lcd
        }
    }
}
