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

#ifndef HARDWAREBUTTONPTT_H
#define HARDWAREBUTTONPTT_H

#include <stdbool.h>

// Physical-button PTT on iOS.
//
// 1. Volume buttons: observes AVAudioSession.outputVolume and puts the volume back with a hidden
//    MPVolumeView slider, so an assigned button keys TX instead of changing the volume.
//    Only armed while the app is connected (hwptt_set_armed) and a button is assigned.
// 2. Action Button / Shortcuts / Siri: App Intents in PttIntents.swift call the Objective-C class
//    DSHardwarePTT (defined in HardwareButtonPTT.mm), which forwards to the same handler.
//
// All callbacks run on the main thread (which is also the Qt GUI thread on iOS).

#ifdef __cplusplus
extern "C" {
#endif

enum {
    HWPTT_BUTTON_DOWN = 1,   // volume down
    HWPTT_BUTTON_UP   = 2    // volume up
};

enum {
    HWPTT_MODE_TOGGLE = 0,   // press = TX on, press again = TX off
    HWPTT_MODE_HOLD   = 1    // TX while the button is held (detected from auto-repeat, see .mm)
};

enum {
    HWPTT_ACTION_STOP   = 0,
    HWPTT_ACTION_START  = 1,
    HWPTT_ACTION_TOGGLE = 2
};

// Returns the TX state after the action: 1 = on air, 0 = off, -1 = not connected / no app.
typedef int (*HWPTTHandler)(int action, const char *source);

void hwptt_set_handler(HWPTTHandler handler);
// Every button event / decision is also passed here (for the app log), besides NSLog.
typedef void (*HWPTTLog)(const char *line);
void hwptt_set_log(HWPTTLog log);
// buttons: bitmask of HWPTT_BUTTON_*, 0 = volume buttons behave normally.
void hwptt_configure(int buttons, int mode);
// true while connected: only then are volume presses captured.
void hwptt_set_armed(bool armed);

#ifdef __cplusplus
}
#endif

#endif // HARDWAREBUTTONPTT_H
