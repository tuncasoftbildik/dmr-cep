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

#import "HardwareButtonPTT.h"
#import "PushToTalkManager.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#include <math.h>

// ---------------------------------------------------------------------------------------------
// Volume buttons as PTT
//
// iOS has no public API for volume-button key events outside a camera capture session
// (AVCaptureEventInteraction only fires while the camera is in use). What an audio app can see
// is the system output volume changing: AVAudioSession.outputVolume is KVO-observable while
// our audio session is active, which it is for the whole time we are connected (the silent
// keep-alive player in AudioSessionManager.mm), also in the background / on the lock screen.
//
// One press of a volume button moves the volume by one step (1/16). We classify a change as a
// button press when it is (about) one step; anything else (dragging the Control Center slider)
// is taken as a deliberate volume change and becomes the new baseline. After a press on an
// assigned button the volume is put back to the baseline through a hidden MPVolumeView slider;
// the echo of that write is recognised (same value, within kEchoWindow) and ignored, so there
// is no feedback loop. Presses on a button that is not assigned keep changing the volume.
//
// There is no key-up event. Holding a volume button makes iOS auto-repeat the step (initial
// delay, then a steady cadence), and since we keep resetting the volume the repeats keep coming.
// Heuristics (all logged with their timing so device tests can tune them):
//   * events of the same button closer than kSeqGap belong to one physical press/hold
//   * toggle mode: the first event of a sequence toggles TX, repeats are swallowed
//   * hold mode: a second event within kHoldConfirm = held -> TX on; no event for kReleaseGap
//     = released -> TX off. A single short tap (no repeat) only stops TX if it is on.
//
// Edges: at volume 1.0 volume-up produces no change (and at 0.0 volume-down), so no event.
// While armed the baseline is kept one step away from the edge of every assigned button
// (e.g. with volume-up assigned a full volume becomes 15/16). This is the only time we change
// the user's volume on purpose, by exactly one step.
// ---------------------------------------------------------------------------------------------

static HWPTTHandler g_handler = NULL;
static HWPTTLog g_log = NULL;

// NSLog plus the app log callback, so a device test is readable from the in-app log too.
static void HWLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void HWLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[HWPTT] %@", msg);
    if (g_log) g_log(msg.UTF8String);
}

static const float kStep = 1.0f / 16.0f;          // one hardware volume step
static const float kEqualTol = 0.01f;             // "same volume"
static const NSTimeInterval kEchoWindow = 0.6;    // our own reset shows up within this time
static const NSTimeInterval kSeqGap = 0.8;        // repeats of one press/hold are closer than this
static const NSTimeInterval kHoldConfirm = 0.8;   // hold mode: 2nd event within this = button held
static const NSTimeInterval kReleaseGap = 0.5;    // hold mode: no repeat for this long = released

static const char *buttonName(int b) { return b == HWPTT_BUTTON_UP ? "volume-up" : "volume-down"; }

static int fireAction(int action, const char *source)
{
    HWLog(@"-> %s from %s", action == HWPTT_ACTION_START ? "START" : action == HWPTT_ACTION_STOP ? "STOP" : "TOGGLE", source);
    if (!g_handler) {
        HWLog(@"no handler registered");
        return -1;
    }
    int r = g_handler(action, source);
    HWLog(@"handler result: %d", r);
    return r;
}

typedef NS_ENUM(NSInteger, DSHoldState) { DSHoldIdle, DSHoldPending, DSHoldHeld };

@interface DSVolumeButtonWatcher : NSObject
@property (nonatomic) int buttons;
@property (nonatomic) int mode;
@property (nonatomic) BOOL armed;
+ (instancetype)shared;
- (void)update;
@end

@implementation DSVolumeButtonWatcher {
    BOOL _running;
    MPVolumeView *_volumeView;
    float _baseline;
    float _lastObserved;
    float _resetTarget;
    NSTimeInterval _resetUntil;
    NSTimeInterval _lastEvent[3];      // index = HWPTT_BUTTON_*
    NSTimeInterval _lastAnyEvent;
    DSHoldState _holdState;
    int _holdButton;
    NSUInteger _holdGen;
}

+ (instancetype)shared
{
    static DSVolumeButtonWatcher *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DSVolumeButtonWatcher new]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

static NSTimeInterval now_s(void) { return [NSProcessInfo processInfo].systemUptime; }

- (void)update
{
    BOOL want = self.armed && self.buttons != 0;
    if (want && !_running) [self start];
    else if (!want && _running) [self stop];
    else if (_running) [self keepAwayFromEdges];
}

- (UIWindow *)hostWindow
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *w = ((UIWindowScene *)scene).windows.firstObject;
        if (w) return w;
    }
    return nil;
}

// The MPVolumeView must be in a window: that is what gives us a working slider and, in the
// foreground, keeps the system volume HUD from popping up on every press.
- (void)attachVolumeView
{
    if (!_volumeView) {
        _volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-200, -200, 40, 40)];
        _volumeView.alpha = 0.0001;
        _volumeView.userInteractionEnabled = NO;
        _volumeView.isAccessibilityElement = NO;
        _volumeView.accessibilityElementsHidden = YES;
    }
    UIWindow *w = [self hostWindow];
    if (w && _volumeView.window != w) {
        [_volumeView removeFromSuperview];
        [w addSubview:_volumeView];
        HWLog(@"volume view attached to window");
    } else if (!w) {
        HWLog(@"no window yet, volume view will attach when the app becomes active");
    }
}

- (UISlider *)slider
{
    for (UIView *v in _volumeView.subviews) {
        if ([v isKindOfClass:[UISlider class]]) return (UISlider *)v;
    }
    return nil;
}

- (void)start
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];
    _running = YES;
    _baseline = _lastObserved = session.outputVolume;
    _resetUntil = 0;
    _holdState = DSHoldIdle;
    [self attachVolumeView];
    HWLog(@"volume buttons armed: buttons=%d mode=%s volume=%.4f", self.buttons,
          self.mode == HWPTT_MODE_HOLD ? "hold" : "toggle", _baseline);
    // Give the fresh MPVolumeView a moment to build its slider before an edge nudge.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_running) [self keepAwayFromEdges];
    });
}

- (void)stop
{
    @try {
        [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
    } @catch (NSException *e) {
        HWLog(@"removeObserver: %@", e.reason);
    }
    _running = NO;
    [_volumeView removeFromSuperview];
    _volumeView = nil;
    if (_holdState == DSHoldHeld) fireAction(HWPTT_ACTION_STOP, "volume-hold-disarmed");
    _holdState = DSHoldIdle;
    _holdGen++;
    HWLog(@"volume buttons disarmed");
}

- (void)appDidBecomeActive
{
    if (!_running) return;
    [self attachVolumeView];
    float v = [AVAudioSession sharedInstance].outputVolume;
    if (fabsf(v - _lastObserved) > kEqualTol) {
        HWLog(@"volume changed while inactive: %.4f -> %.4f (new baseline)", _lastObserved, v);
        _baseline = _lastObserved = v;
    }
    [self keepAwayFromEdges];
}

- (void)restoreTo:(float)target
{
    UISlider *s = [self slider];
    if (!s) {
        [self attachVolumeView];
        s = [self slider];
    }
    if (!s) {
        HWLog(@"no volume slider, cannot restore %.4f", target);
        return;
    }
    _resetTarget = target;
    _resetUntil = now_s() + kEchoWindow;
    [s setValue:target animated:NO];
    [s sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)keepAwayFromEdges
{
    float target = _baseline;
    if ((self.buttons & HWPTT_BUTTON_DOWN) && _baseline < kStep * 0.5f) target = kStep;
    if ((self.buttons & HWPTT_BUTTON_UP) && _baseline > 1.0f - kStep * 0.5f) target = 1.0f - kStep;
    if (fabsf(target - _baseline) > kEqualTol) {
        HWLog(@"volume %.4f at the edge of an assigned button, moving one step to %.4f", _baseline, target);
        _baseline = target;
        [self restoreTo:target];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    float v = [change[NSKeyValueChangeNewKey] floatValue];
    dispatch_async(dispatch_get_main_queue(), ^{ [self volumeChanged:v]; });
}

- (void)volumeChanged:(float)v
{
    if (!_running) return;
    NSTimeInterval t = now_s();

    if (t < _resetUntil && fabsf(v - _resetTarget) < kEqualTol) {
        _lastObserved = v;   // echo of our own reset
        return;
    }
    float d = v - _lastObserved;
    _lastObserved = v;
    if (fabsf(d) < kEqualTol) return;

    float steps = d / kStep;
    float n = roundf(steps);
    BOOL inSeq = (t - _lastAnyEvent) < kSeqGap;
    BOOL isStep = fabsf(steps - n) < 0.25f && (fabsf(n) == 1.0f || (inSeq && fabsf(n) >= 1.0f && fabsf(n) <= 3.0f));
    if (!isStep) {
        HWLog(@"volume %.4f (delta %.4f) is not a button step: user volume change, new baseline", v, d);
        _baseline = v;
        [self keepAwayFromEdges];
        return;
    }
    int button = d > 0 ? HWPTT_BUTTON_UP : HWPTT_BUTTON_DOWN;
    if (!(self.buttons & button)) {
        // Not assigned: the button keeps its normal job.
        _baseline = v;
        [self keepAwayFromEdges];
        return;
    }
    [self restoreTo:_baseline];
    _lastAnyEvent = t;
    [self pressed:button at:t delta:d];
}

- (void)pressed:(int)button at:(NSTimeInterval)t delta:(float)d
{
    NSTimeInterval dt = _lastEvent[button] > 0 ? t - _lastEvent[button] : -1;
    _lastEvent[button] = t;
    BOOL inSeq = dt >= 0 && dt < kSeqGap;
    HWLog(@"%s press (delta %+.4f, %.0f ms since previous, %s)", buttonName(button), d,
          dt < 0 ? -1.0 : dt * 1000.0, inSeq ? "repeat" : "new");

    if (self.mode != HWPTT_MODE_HOLD) {
        if (inSeq) return;   // auto-repeat of a held button: one toggle per physical press
        fireAction(HWPTT_ACTION_TOGGLE, button == HWPTT_BUTTON_UP ? "volume-up" : "volume-down");
        return;
    }

    if (_holdState == DSHoldIdle || _holdButton != button) {
        if (_holdState == DSHoldHeld) fireAction(HWPTT_ACTION_STOP, "volume-hold-switch");
        _holdState = DSHoldPending;
        _holdButton = button;
        NSUInteger gen = ++_holdGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHoldConfirm * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_holdGen != gen || self->_holdState != DSHoldPending) return;
            self->_holdState = DSHoldIdle;
            HWLog(@"%s short tap (no auto-repeat within %.0f ms)", buttonName(button), kHoldConfirm * 1000.0);
            fireAction(HWPTT_ACTION_STOP, "volume-tap");
        });
        return;
    }
    if (_holdState == DSHoldPending) {
        _holdState = DSHoldHeld;
        HWLog(@"%s held", buttonName(button));
        fireAction(HWPTT_ACTION_START, button == HWPTT_BUTTON_UP ? "volume-up-hold" : "volume-down-hold");
    }
    [self armRelease:button];
}

- (void)armRelease:(int)button
{
    NSUInteger gen = ++_holdGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReleaseGap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_holdGen != gen || self->_holdState != DSHoldHeld) return;
        self->_holdState = DSHoldIdle;
        HWLog(@"%s released (no repeat for %.0f ms)", buttonName(button), kReleaseGap * 1000.0);
        fireAction(HWPTT_ACTION_STOP, "volume-release");
    });
}

@end

// ---------------------------------------------------------------------------------------------
// App Intents bridge (PttIntents.swift finds this class with NSClassFromString, so no bridging
// header is needed). Called on the main actor.
// ---------------------------------------------------------------------------------------------

@interface DSHardwarePTT : NSObject
@end

@implementation DSHardwarePTT

// action: HWPTT_ACTION_*; returns the TX state after the action (1/0) or -1 = not connected.
+ (NSNumber *)performIntentAction:(NSNumber *)action
{
    int a = action.intValue;
    if (a < HWPTT_ACTION_STOP || a > HWPTT_ACTION_TOGGLE) a = HWPTT_ACTION_TOGGLE;
    HWLog(@"App Intent (Action Button / Shortcuts) action %d, app state %ld", a,
          (long)[UIApplication sharedApplication].applicationState);
    return @(fireAction(a, "action-button-intent"));
}

// 0 = system PTT channel not joined, 1 = joined and idle, 2 = joined and transmitting.
+ (NSNumber *)systemPTTState
{
    if (!ptt_is_joined()) return @0;
    return ptt_is_transmitting() ? @2 : @1;
}

@end

// ---------------------------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------------------------

extern "C" void hwptt_set_handler(HWPTTHandler handler)
{
    g_handler = handler;
}

extern "C" void hwptt_set_log(HWPTTLog log)
{
    g_log = log;
}

extern "C" void hwptt_configure(int buttons, int mode)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        DSVolumeButtonWatcher *w = [DSVolumeButtonWatcher shared];
        w.buttons = buttons & (HWPTT_BUTTON_DOWN | HWPTT_BUTTON_UP);
        w.mode = mode == HWPTT_MODE_HOLD ? HWPTT_MODE_HOLD : HWPTT_MODE_TOGGLE;
        HWLog(@"configure buttons=%d mode=%d", w.buttons, w.mode);
        [w update];
    });
}

extern "C" void hwptt_set_armed(bool armed)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        DSVolumeButtonWatcher *w = [DSVolumeButtonWatcher shared];
        if (w.armed == armed) return;
        w.armed = armed;
        [w update];
    });
}
