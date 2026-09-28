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
import QtMultimedia

import "../theme"

// Received transmissions saved by the DMR mode (RxRecorder), newest first.
// maxItems: 1 on the main page ("replay last"), 0 = show all.
ColumnLayout {
    id: root

    required property var droidstarRef
    property int maxItems: 0
    property bool excludeOwn: false      // main screen: only other stations
    property bool allowDelete: maxItems === 0

    property var recordings: []
    property string playingUrl: ""

    Tokens { id: t }
    spacing: 6

    function refresh() {
        if (!droidstarRef) return
        var all = droidstarRef.loadRecordings()
        if (excludeOwn) all = all.filter(function(r) { return !r.own })
        recordings = (maxItems > 0) ? all.slice(0, maxItems) : all
    }

    function toggle(url) {
        if (playingUrl === url && player.playbackState === MediaPlayer.PlayingState) {
            player.stop()
            return
        }
        player.stop()
        playingUrl = url
        player.source = url
        player.play()
    }

    function fmtTime(ms) {
        var d = new Date(ms)
        return Qt.formatTime(d, "HH:mm:ss")
    }

    Component.onCompleted: refresh()
    onVisibleChanged: if (visible) refresh()

    Connections {
        target: root.droidstarRef
        function onRecordings_changed() { root.refresh() }
    }

    MediaPlayer {
        id: player
        audioOutput: AudioOutput {}
        onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState) root.playingUrl = ""
    }

    Label {
        visible: root.maxItems === 0 && root.recordings.length === 0
        text: qsTr("No recordings yet. Received transmissions longer than 1 s are kept (last 30).")
        opacity: 0.6
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }

    Repeater {
        model: root.recordings
        delegate: ColumnLayout {
            id: recRow
            required property var modelData
            // Subtitle saved with the recording (<file>.json from the live subtitles), if any.
            readonly property string subMain: recRow.modelData.subTr ? recRow.modelData.subTr : (recRow.modelData.subEn || "")
            readonly property string subOrig: (recRow.modelData.subTr && recRow.modelData.subEn) ? recRow.modelData.subEn : ""
            property bool subOpen: false
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                id: recLine
                readonly property bool playing: root.playingUrl === recRow.modelData.url
                Layout.fillWidth: true
                spacing: 8

                RoundButton {
                    id: playBtn
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    onClicked: root.toggle(recRow.modelData.url)
                    contentItem: Label {
                        text: recLine.playing ? "■" : "▶"
                        color: t.text
                        font.pixelSize: 18
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: width / 2
                        color: recLine.playing ? Qt.rgba(t.success.r, t.success.g, t.success.b, 0.25) : t.surface2
                        border.color: recLine.playing ? t.success : t.stroke
                        border.width: 1
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label {
                        text: (root.maxItems > 0 ? qsTr("Replay last: ") : "")
                              + (recRow.modelData.own ? qsTr("You (as heard by others)") : recRow.modelData.callsign)
                        color: recRow.modelData.own ? t.warning : t.text
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Label {
                        text: "TG " + recRow.modelData.dst + " · " + root.fmtTime(recRow.modelData.time) + " · " + recRow.modelData.seconds + " s"
                        font.pixelSize: 11
                        opacity: 0.6
                        Layout.fillWidth: true
                    }
                }

                ToolButton {
                    visible: root.allowDelete
                    text: "✕"
                    onClicked: {
                        if (recLine.playing) player.stop()
                        root.droidstarRef.deleteRecording(recRow.modelData.file)
                    }
                }
            }

            // Tap to expand: Turkish subtitle, then the original English.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 52
                Layout.bottomMargin: 4
                visible: recRow.subMain !== ""
                spacing: 2
                Label {
                    Layout.fillWidth: true
                    text: "“" + recRow.subMain + "”"
                    color: t.text
                    font.pixelSize: 13
                    opacity: 0.9
                    wrapMode: Text.Wrap
                    maximumLineCount: recRow.subOpen ? 1000 : 2
                    elide: Text.ElideRight
                }
                Label {
                    Layout.fillWidth: true
                    visible: recRow.subOpen && recRow.subOrig !== ""
                    text: recRow.subOrig
                    color: t.textMuted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                TapHandler { onTapped: recRow.subOpen = !recRow.subOpen }
            }
        }
    }
}
