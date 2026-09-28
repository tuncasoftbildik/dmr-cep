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
    property bool allowDelete: maxItems === 0

    property var recordings: []
    property string playingUrl: ""

    Tokens { id: t }
    spacing: 6

    function refresh() {
        if (!droidstarRef) return
        var all = droidstarRef.loadRecordings()
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
        delegate: RowLayout {
            required property var modelData
            readonly property bool playing: root.playingUrl === modelData.url
            Layout.fillWidth: true
            spacing: 8

            Button {
                text: parent.playing ? "■" : "▶"
                Layout.preferredWidth: 44
                onClicked: root.toggle(modelData.url)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    text: (root.maxItems > 0 ? qsTr("Replay last: ") : "") + modelData.callsign
                    font.pixelSize: 13
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Label {
                    text: "TG " + modelData.dst + " · " + root.fmtTime(modelData.time) + " · " + modelData.seconds + " s"
                    font.pixelSize: 11
                    opacity: 0.6
                    Layout.fillWidth: true
                }
            }

            ToolButton {
                visible: root.allowDelete
                text: "✕"
                onClicked: {
                    if (parent.playing) player.stop()
                    root.droidstarRef.deleteRecording(modelData.file)
                }
            }
        }
    }
}
