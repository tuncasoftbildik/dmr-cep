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
import QtQuick.Controls.Material

QtObject {
    // DMR Cep: graphite radio body + amber LCD. Green = receiving, red = on air.
    readonly property color bg: "#15171B"          // graphite body
    readonly property color surface: "#1E2127"
    readonly property color surface2: "#252932"
    readonly property color stroke: "#343B46"
    readonly property color text: "#ECEDEF"
    readonly property color textMuted: "#9AA1AC"
    readonly property color accent: "#5AA2F8"      // antenna-wave blue from the icon
    readonly property color success: "#3DD68C"     // RX / connected
    readonly property color danger: "#FF5147"      // TX / on air
    readonly property color warning: "#F4A62A"     // amber

    // Amber LCD panel
    readonly property color lcd: "#F4A62A"
    readonly property color lcdHi: "#FFC45C"
    readonly property color lcdInk: "#2B1702"
    readonly property color lcdGhost: "#DB9223"     // unlit 7-segment "8"s behind the digits
    readonly property color lcdBorder: "#B8761A"
    // Receiving: the backlight turns green, like a handheld with an RX-lit display.
    readonly property color lcdRx: "#5CCB6E"
    readonly property color lcdRxHi: "#9BEAA4"
    readonly property color lcdRxGhost: "#4DB45E"
    readonly property color lcdRxBorder: "#2F8A3F"

    // Link quality bars (radio-style RSSI indicator on the LCD)
    readonly property real lqBarWidth: 4
    readonly property real lqBarGap: 2
    readonly property real lqBarHeight: 14
    readonly property real lqBarUnlitOpacity: 0.2

    readonly property int rSm: 12
    readonly property int rMd: 16
    readonly property int rLg: 22

    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 20
    readonly property int s6: 24
}

