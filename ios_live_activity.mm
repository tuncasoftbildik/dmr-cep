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

#include "ios_live_activity.h"

#include <QtGlobal>

#if defined(Q_OS_IOS)

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// LiveActivityManager is a Swift class compiled into the main target (DroidStar.pro adds
// the .swift files to Compile Sources). It is looked up at runtime so this file needs no
// generated Swift header and still links on iOS < 16.1.
static inline Class liveActivityManagerClass(void)
{
    Class cls = NSClassFromString(@"LiveActivityManager"); // @objc(LiveActivityManager)
    if (!cls) cls = NSClassFromString(@"DroidStar.LiveActivityManager");
    if (!cls) {
        static bool logged = false;
        if (!logged) {
            logged = true;
            NSLog(@"[DroidStar][LiveActivity] LiveActivityManager class not found. "
                  @"Make sure LiveActivityManager.swift is part of the MAIN app target.");
        }
    }
    return cls;
}

static id liveActivityManager(void)
{
    Class cls = liveActivityManagerClass();
    if (!cls) return nil;
    SEL sharedSel = NSSelectorFromString(@"shared");
    if (![cls respondsToSelector:sharedSel]) {
        NSLog(@"[DroidStar][LiveActivity] LiveActivityManager missing selector +shared");
        return nil;
    }
    typedef id (*MsgSendId)(id, SEL);
    return ((MsgSendId)objc_msgSend)((id)cls, sharedSel);
}

static inline NSString *ns(const char *s)
{
    if (!s) return @"";
    return [NSString stringWithUTF8String:s] ?: @"";
}

bool ios_live_activity_is_available(void)
{
    if (@available(iOS 16.1, *)) {
        Class cls = liveActivityManagerClass();
        if (!cls) return false;

        SEL sel = NSSelectorFromString(@"isDynamicIslandAvailable");
        if (![cls respondsToSelector:sel]) {
            NSLog(@"[DroidStar][LiveActivity] LiveActivityManager missing selector isDynamicIslandAvailable");
            return false;
        }
        typedef BOOL (*MsgSendBool)(id, SEL);
        return ((MsgSendBool)objc_msgSend)((id)cls, sel);
    }
    return false;
}

void ios_live_activity_update(const char *mode,
                              const char *callsign,
                              const char *name,
                              const char *country,
                              const char *tg,
                              const char *status,
                              const char *station,
                              double since_epoch_sec)
{
    if (@available(iOS 16.1, *)) {
        id mgr = liveActivityManager();
        if (!mgr) return;
        SEL sel = NSSelectorFromString(@"updateWithMode:callsign:name:country:tg:status:station:since:");
        if (![mgr respondsToSelector:sel]) {
            NSLog(@"[DroidStar][LiveActivity] LiveActivityManager missing selector %@", NSStringFromSelector(sel));
            return;
        }
        typedef void (*MsgSendUpdate)(id, SEL, NSString *, NSString *, NSString *, NSString *,
                                      NSString *, NSString *, NSString *, double);
        ((MsgSendUpdate)objc_msgSend)(mgr, sel, ns(mode), ns(callsign), ns(name), ns(country),
                                      ns(tg), ns(status), ns(station), since_epoch_sec);
    }
}

void ios_live_activity_start_or_update(const char *mode,
                                       const char *callsign,
                                       const char *handle,
                                       const char *country,
                                       const char *tgid)
{
    ios_live_activity_update(mode, callsign, handle, country, tgid, "", "", 0);
}

static void callVoid(NSString *selName)
{
    if (@available(iOS 16.1, *)) {
        id mgr = liveActivityManager();
        if (!mgr) return;
        SEL sel = NSSelectorFromString(selName);
        if (![mgr respondsToSelector:sel]) {
            NSLog(@"[DroidStar][LiveActivity] LiveActivityManager missing selector %@", selName);
            return;
        }
        typedef void (*MsgSendVoid)(id, SEL);
        ((MsgSendVoid)objc_msgSend)(mgr, sel);
    }
}

void ios_live_activity_end(void)
{
    callVoid(@"endLiveActivity");
}

void ios_live_activity_end_all(void)
{
    callVoid(@"endAllActivities");
}

#else

bool ios_live_activity_is_available(void) { return false; }
void ios_live_activity_update(const char *, const char *, const char *, const char *, const char *,
                              const char *, const char *, double) {}
void ios_live_activity_start_or_update(const char *, const char *, const char *, const char *, const char *) {}
void ios_live_activity_end(void) {}
void ios_live_activity_end_all(void) {}

#endif
