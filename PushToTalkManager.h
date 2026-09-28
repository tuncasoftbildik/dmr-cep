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

#ifndef PUSHTOTALKMANAGER_H
#define PUSHTOTALKMANAGER_H

#include <stdbool.h>

// C bridge to Apple's PushToTalk framework (iOS 16+).
// While joined, the system shows a PTT button on the lock screen / Dynamic Island,
// Bluetooth PTT accessories work (iOS 17+), and the active remote talker is displayed.
//
// TX ownership: the app calls ptt_app_tx(true/false) whenever it starts/stops TX itself.
// When TX is started/stopped from the system UI or a handsfree button, the begin/end
// callbacks fire instead. Each side ignores the echo of its own request.

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*PTTSystemCallback)(void);
typedef void (*PTTStatusCallback)(const char *message);

bool ptt_is_available(void);
// audioActivated: the system activated the audio session (TX or RX); the app should (re)open audio I/O.
void ptt_set_callbacks(PTTSystemCallback beginTx, PTTSystemCallback endTx, PTTStatusCallback status, PTTSystemCallback audioActivated);
// Must be called while the app is in the foreground (user tapped Connect).
void ptt_join(const char *channelName);
void ptt_update_name(const char *channelName);
void ptt_leave(void);
bool ptt_is_joined(void);
void ptt_app_tx(bool transmitting);
// The system confirmed a transmission (didBeginTransmitting .. didEndTransmitting), any source.
bool ptt_is_transmitting(void);
// Who is talking right now; NULL or "" clears.
void ptt_set_remote_talker(const char *name);

#ifdef __cplusplus
}
#endif

#endif // PUSHTOTALKMANAGER_H
