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

pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// Four rising bars like a handheld radio's RSSI indicator, showing the network link quality.
// bars: -1 unknown (still measuring), 0 lost .. 4 excellent. Unlit bars stay faintly visible.
Item {
    id: root

    property int bars: -1
    property color color: t.lcdInk
    property real barWidth: t.lqBarWidth
    property real barGap: t.lqBarGap
    property real barHeight: t.lqBarHeight

    Tokens { id: t }

    implicitWidth: 4 * barWidth + 3 * barGap
    implicitHeight: barHeight

    // Short label for the current score (Turkish via the translation file).
    function label(b) {
        switch (b) {
        case 4: return qsTr("Excellent")
        case 3: return qsTr("Good")
        case 2: return qsTr("Fair")
        case 1: return qsTr("Weak")
        case 0: return qsTr("None")
        default: return qsTr("Measuring…")
        }
    }

    Accessible.role: Accessible.Indicator
    Accessible.name: qsTr("Link quality: %1").arg(label(bars))

    Row {
        anchors.bottom: parent.bottom
        spacing: root.barGap
        Repeater {
            model: 4
            Rectangle {
                required property int index
                anchors.bottom: parent.bottom
                width: root.barWidth
                height: root.barHeight * (0.34 + 0.22 * index)
                radius: 1
                color: root.color
                opacity: (root.bars > index) ? 1.0 : t.lqBarUnlitOpacity
            }
        }
    }
}
