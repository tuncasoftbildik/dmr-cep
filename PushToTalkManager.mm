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

#import "PushToTalkManager.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PushToTalk/PushToTalk.h>

static PTTSystemCallback g_beginTx = NULL;
static PTTSystemCallback g_endTx = NULL;
static PTTStatusCallback g_status = NULL;

static void ptt_status(NSString *msg)
{
    NSLog(@"[PTT] %@", msg);
    if (g_status) g_status(msg.UTF8String);
}

API_AVAILABLE(ios(16.0))
@interface DSPushToTalk : NSObject <PTChannelManagerDelegate, PTChannelRestorationDelegate>
@property (nonatomic, strong) PTChannelManager *manager;
@property (nonatomic, strong) NSUUID *channelUUID;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic) BOOL joined;
@property (nonatomic) BOOL joinPending;
// YES while the app itself owns TX (in-app button). System begin/end echoes are ignored then.
@property (nonatomic) BOOL appTransmitting;
// YES while TX was started by the system (lock screen / handsfree) and handed to the app.
@property (nonatomic) BOOL systemTransmitting;
+ (instancetype)shared;
@end

@implementation DSPushToTalk

+ (instancetype)shared
{
    static DSPushToTalk *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DSPushToTalk new]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        // One stable channel per install so restoration after relaunch finds it.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *u = [d stringForKey:@"DSPTTChannelUUID"];
        if (!u) {
            u = [NSUUID UUID].UUIDString;
            [d setObject:u forKey:@"DSPTTChannelUUID"];
        }
        _channelUUID = [[NSUUID alloc] initWithUUIDString:u];
        _channelName = @"DroidStar";
    }
    return self;
}

- (PTChannelDescriptor *)descriptor
{
    return [[PTChannelDescriptor alloc] initWithName:self.channelName image:nil];
}

// The manager must exist before any join; creating it also restores a channel that
// survived an app relaunch (we leave that one, the app always joins on Connect).
- (void)withManager:(void (^)(PTChannelManager *m))block
{
    if (self.manager) { block(self.manager); return; }
    [PTChannelManager channelManagerWithDelegate:self restorationDelegate:self completionHandler:^(PTChannelManager *m, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!m) {
                ptt_status([NSString stringWithFormat:@"Push-to-Talk unavailable: %@", error.localizedDescription]);
                return;
            }
            self.manager = m;
            block(m);
        });
    }];
}

- (void)join
{
    self.joinPending = YES;
    [self withManager:^(PTChannelManager *m) {
        if (self.joined) {
            [m setChannelDescriptor:[self descriptor] forChannelUUID:self.channelUUID completionHandler:nil];
            return;
        }
        [m requestJoinChannelWithUUID:self.channelUUID descriptor:[self descriptor]];
    }];
}

- (void)leave
{
    self.joinPending = NO;
    if (self.manager && self.joined) {
        [self.manager leaveChannelWithUUID:self.channelUUID];
    }
}

#pragma mark - PTChannelManagerDelegate

- (void)channelManager:(PTChannelManager *)channelManager didJoinChannelWithUUID:(NSUUID *)channelUUID reason:(PTChannelJoinReason)reason
{
    if (reason == PTChannelJoinReasonChannelRestoration && !self.joinPending) {
        // Left over from a previous run: the app is not connected, so don't keep a dead PTT button around.
        [channelManager leaveChannelWithUUID:channelUUID];
        return;
    }
    self.joined = YES;
    [channelManager setTransmissionMode:PTTransmissionModeHalfDuplex forChannelUUID:channelUUID completionHandler:nil];
    if (@available(iOS 17.0, *)) {
        [channelManager setAccessoryButtonEventsEnabled:YES forChannelUUID:channelUUID completionHandler:nil];
    }
    ptt_status(@"Push-to-Talk channel joined");
}

- (void)channelManager:(PTChannelManager *)channelManager didLeaveChannelWithUUID:(NSUUID *)channelUUID reason:(PTChannelLeaveReason)reason
{
    self.joined = NO;
    if (self.systemTransmitting) {
        self.systemTransmitting = NO;
        if (g_endTx) g_endTx();
    }
    ptt_status(reason == PTChannelLeaveReasonUserRequest ? @"Push-to-Talk channel closed by user" : @"Push-to-Talk channel left");
}

- (void)channelManager:(PTChannelManager *)channelManager channelUUID:(NSUUID *)channelUUID didBeginTransmittingFromSource:(PTChannelTransmitRequestSource)source
{
    if (self.appTransmitting || source == PTChannelTransmitRequestSourceDeveloperRequest) {
        return; // echo of our own requestBeginTransmitting
    }
    self.systemTransmitting = YES;
    if (g_beginTx) g_beginTx();
}

- (void)channelManager:(PTChannelManager *)channelManager channelUUID:(NSUUID *)channelUUID didEndTransmittingFromSource:(PTChannelTransmitRequestSource)source
{
    if (!self.systemTransmitting) {
        return; // app-owned TX (or already ended)
    }
    self.systemTransmitting = NO;
    if (g_endTx) g_endTx();
}

- (void)channelManager:(PTChannelManager *)channelManager receivedEphemeralPushToken:(NSData *)pushToken
{
    // No PTT push server: audio arrives over the already open network link.
}

- (PTPushResult *)incomingPushResultForChannelManager:(PTChannelManager *)channelManager channelUUID:(NSUUID *)channelUUID pushPayload:(NSDictionary<NSString *,id> *)pushPayload
{
    return PTPushResult.leaveChannelPushResult;
}

- (void)channelManager:(PTChannelManager *)channelManager didActivateAudioSession:(AVAudioSession *)audioSession
{
    NSLog(@"[PTT] audio session activated by system");
}

- (void)channelManager:(PTChannelManager *)channelManager didDeactivateAudioSession:(AVAudioSession *)audioSession
{
    NSLog(@"[PTT] audio session deactivated by system");
}

- (void)channelManager:(PTChannelManager *)channelManager failedToJoinChannelWithUUID:(NSUUID *)channelUUID error:(NSError *)error
{
    self.joinPending = NO;
    ptt_status([NSString stringWithFormat:@"Push-to-Talk join failed: %@", error.localizedDescription]);
}

- (void)channelManager:(PTChannelManager *)channelManager failedToBeginTransmittingInChannelWithUUID:(NSUUID *)channelUUID error:(NSError *)error
{
    NSLog(@"[PTT] begin transmitting failed: %@", error);
}

#pragma mark - PTChannelRestorationDelegate

- (PTChannelDescriptor *)channelDescriptorForRestoredChannelUUID:(NSUUID *)channelUUID
{
    return [self descriptor];
}

@end

#pragma mark - C bridge

extern "C" bool ptt_is_available(void)
{
    if (@available(iOS 16.0, *)) return true;
    return false;
}

extern "C" void ptt_set_callbacks(PTTSystemCallback beginTx, PTTSystemCallback endTx, PTTStatusCallback status)
{
    g_beginTx = beginTx;
    g_endTx = endTx;
    g_status = status;
}

extern "C" void ptt_join(const char *channelName)
{
    if (@available(iOS 16.0, *)) {
        NSString *name = channelName ? [NSString stringWithUTF8String:channelName] : @"DroidStar";
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPushToTalk *p = [DSPushToTalk shared];
            p.channelName = name.length ? name : @"DroidStar";
            [p join];
        });
    }
}

extern "C" void ptt_update_name(const char *channelName)
{
    if (@available(iOS 16.0, *)) {
        NSString *name = channelName ? [NSString stringWithUTF8String:channelName] : @"DroidStar";
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPushToTalk *p = [DSPushToTalk shared];
            p.channelName = name;
            if (p.joined) {
                [p.manager setChannelDescriptor:[p descriptor] forChannelUUID:p.channelUUID completionHandler:nil];
            }
        });
    }
}

extern "C" void ptt_leave(void)
{
    if (@available(iOS 16.0, *)) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[DSPushToTalk shared] leave]; });
    }
}

extern "C" bool ptt_is_joined(void)
{
    if (@available(iOS 16.0, *)) return [DSPushToTalk shared].joined;
    return false;
}

extern "C" void ptt_app_tx(bool transmitting)
{
    if (@available(iOS 16.0, *)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPushToTalk *p = [DSPushToTalk shared];
            if (!p.joined || !p.manager) return;
            if (p.systemTransmitting) {
                // TX came from the system; the app is only mirroring it (e.g. UI button state).
                if (!transmitting) {
                    p.systemTransmitting = NO;
                    [p.manager stopTransmittingWithChannelUUID:p.channelUUID];
                }
                return;
            }
            p.appTransmitting = transmitting;
            if (transmitting) {
                [p.manager requestBeginTransmittingWithChannelUUID:p.channelUUID];
            } else {
                [p.manager stopTransmittingWithChannelUUID:p.channelUUID];
            }
        });
    }
}

extern "C" void ptt_set_remote_talker(const char *name)
{
    if (@available(iOS 16.0, *)) {
        NSString *n = (name && name[0]) ? [NSString stringWithUTF8String:name] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPushToTalk *p = [DSPushToTalk shared];
            if (!p.joined || !p.manager) return;
            PTParticipant *who = n ? [[PTParticipant alloc] initWithName:n image:nil] : nil;
            [p.manager setActiveRemoteParticipant:who forChannelUUID:p.channelUUID completionHandler:^(NSError *error) {
                if (error) NSLog(@"[PTT] setActiveRemoteParticipant failed: %@", error);
            }];
        });
    }
}
