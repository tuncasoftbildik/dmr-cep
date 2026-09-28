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

// iOS backend of PhoneGps (CoreLocation). Compiled with ARC.
//
// Battery: 100 m accuracy (usually Wi-Fi/cell, no continuous GPS), 100 m distance filter,
// automatic pausing, and no background location mode: iOS suspends updates while the app is
// in the background, so a connected session in the pocket costs nothing extra.

#include "phonegps.h"
#import <CoreLocation/CoreLocation.h>

@interface DSPhoneGps : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
// Not owning: PhoneGps owns this object and clears the delegate before it goes away.
@property (nonatomic, assign) PhoneGps *owner;
- (void)start;
- (void)stop;
@end

@implementation DSPhoneGps

- (instancetype)init
{
    self = [super init];
    if(self){
        _manager = [[CLLocationManager alloc] init];
        _manager.delegate = self;
        _manager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        _manager.distanceFilter = 100.0;
        _manager.pausesLocationUpdatesAutomatically = YES;
        _manager.activityType = CLActivityTypeOther;
    }
    return self;
}

// Deployment target is iOS 15, so the iOS 14 instance API is always there.
- (CLAuthorizationStatus)authStatus
{
    return self.manager.authorizationStatus;
}

- (void)report:(PhoneGps::State)s
{
    if(self.owner){
        self.owner->backend_state(s);
    }
}

- (void)apply
{
    switch([self authStatus]){
    case kCLAuthorizationStatusNotDetermined:
        [self report:PhoneGps::NeedPermission];
        [self.manager requestWhenInUseAuthorization];
        break;
    case kCLAuthorizationStatusDenied:
        // Denied is also reported when Location Services are switched off system wide.
        [self report:([CLLocationManager locationServicesEnabled] ? PhoneGps::Denied : PhoneGps::ServicesOff)];
        [self.manager stopUpdatingLocation];
        break;
    case kCLAuthorizationStatusRestricted:
        [self report:PhoneGps::Denied];
        [self.manager stopUpdatingLocation];
        break;
    default:   // when in use / always
        [self report:PhoneGps::Waiting];
        [self.manager startUpdatingLocation];
        break;
    }
}

- (void)start
{
    [self apply];
}

- (void)stop
{
    [self.manager stopUpdatingLocation];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
    (void)manager;
    if(self.owner && self.owner->active()){
        [self apply];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
    (void)manager;
    CLLocation *loc = locations.lastObject;
    if(!loc || !self.owner){
        return;
    }
    // Negative accuracy means invalid; very coarse or stale (cached) fixes are skipped.
    if((loc.horizontalAccuracy < 0) || (loc.horizontalAccuracy > 1000.0)){
        return;
    }
    if(fabs([loc.timestamp timeIntervalSinceNow]) > 600.0){
        return;
    }
    self.owner->backend_position(loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy);
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    (void)manager;
    if(!self.owner){
        return;
    }
    if(error.code == kCLErrorDenied){
        [self report:PhoneGps::Denied];
        [self.manager stopUpdatingLocation];
    }
    else if(error.code == kCLErrorLocationUnknown){
        // Transient: CoreLocation keeps trying.
    }
    else if(!self.owner->has_fix()){
        [self report:PhoneGps::Unavailable];
    }
}

@end

PhoneGps::PhoneGps(QObject *parent) : QObject(parent)
{
}

PhoneGps::~PhoneGps()
{
    if(m_impl){
        DSPhoneGps *impl = (__bridge_transfer DSPhoneGps *)m_impl;
        [impl stop];
        impl.owner = nullptr;
        impl.manager.delegate = nil;
        m_impl = nullptr;
    }
}

void PhoneGps::start()
{
    if(m_active){
        return;
    }
    m_active = true;
    if(!m_impl){
        DSPhoneGps *impl = [[DSPhoneGps alloc] init];
        impl.owner = this;
        m_impl = (__bridge_retained void *)impl;
    }
    [(__bridge DSPhoneGps *)m_impl start];
}

void PhoneGps::stop()
{
    if(!m_active){
        return;
    }
    if(m_impl){
        [(__bridge DSPhoneGps *)m_impl stop];
    }
    m_active = false;
    m_accuracy = -1.0;
    backend_state(Off);
}
