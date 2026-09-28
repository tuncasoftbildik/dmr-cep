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

import Foundation
import ActivityKit

// App-side half of the Live Activity: starts, updates and ends the ActivityKit activity.
// The card UI lives in the Widget Extension (ios/LiveActivityExtension), which is built and
// embedded by scripts/embed_live_activity_extension.sh.
//
// The explicit Objective-C name lets ios_live_activity.mm find the class with
// NSClassFromString(@"LiveActivityManager") regardless of the Swift module name.
@available(iOS 16.1, *)
@objc(LiveActivityManager)
final class LiveActivityManager: NSObject {
    @objc static let shared = LiveActivityManager()

    typealias State = DroidStarActivityAttributes.ContentState

    // All state is touched on the main queue only.
    private var activity: Activity<DroidStarActivityAttributes>?
    private var station = ""
    private var lastState: State?
    private var lastPush = Date.distantPast
    private var loggedDisabled = false

    // Re-send an unchanged state after this long so the card does not go stale while the
    // app is alive; if the app dies, the card turns stale (see staleDate) instead of freezing.
    private static let refreshInterval: TimeInterval = 4 * 60
    private static let staleAfter: TimeInterval = 11 * 60

    private override init() {
        super.init()
    }

    // MARK: - Public API (called from ios_live_activity.mm via the ObjC runtime)

    @objc static var isDynamicIslandAvailable: Bool {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        if !enabled {
            print("[DroidStar][LiveActivity] areActivitiesEnabled == false")
        }
        return enabled
    }

    /// Start the activity if needed, otherwise update it. `since` is seconds since 1970
    /// (0 = now) and marks when the current mode began.
    @objc(updateWithMode:callsign:name:country:tg:status:station:since:)
    func update(mode: String, callsign: String, name: String, country: String, tg: String,
                status: String, station: String, since: Double) {
        let sinceDate = since > 0 ? Date(timeIntervalSince1970: since) : Date()
        let state = State(mode: mode, callsign: callsign, handle: name, country: country,
                          tgid: tg, status: status, since: sinceDate, timestamp: Date())
        DispatchQueue.main.async {
            self.apply(state, station: station)
        }
    }

    @objc func endLiveActivity() {
        DispatchQueue.main.async {
            let current = self.activity
            self.activity = nil
            self.lastState = nil
            guard let current else { return }
            Task {
                await current.end(dismissalPolicy: .immediate)
                print("[DroidStar][LiveActivity] Ended Live Activity: \(current.id)")
            }
        }
    }

    /// End every activity of ours, including orphans left behind by a previous run.
    @objc func endAllActivities() {
        DispatchQueue.main.async {
            self.activity = nil
            self.lastState = nil
            let all = Activity<DroidStarActivityAttributes>.activities
            guard !all.isEmpty else { return }
            Task {
                for existing in all {
                    print("[DroidStar][LiveActivity] Ending activity: \(existing.id)")
                    await existing.end(dismissalPolicy: .immediate)
                }
            }
        }
    }

    // Backwards-compatible selectors (older call sites).
    @objc(startOrUpdateLiveActivityWithMode:callsign:handle:country:tgid:)
    func startOrUpdateLiveActivity(mode: String, callsign: String, handle: String, country: String, tgid: String) {
        update(mode: mode, callsign: callsign, name: handle, country: country, tg: tgid,
               status: "", station: station, since: 0)
    }

    @objc(updateQsoDetailsWithMode:callsign:handle:country:tgid:)
    func updateQsoDetails(mode: String, callsign: String, handle: String, country: String, tgid: String) {
        startOrUpdateLiveActivity(mode: mode, callsign: callsign, handle: handle, country: country, tgid: tgid)
    }

    // MARK: - Private

    private func apply(_ state: State, station: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !loggedDisabled {
                print("[DroidStar][LiveActivity] Live Activities are disabled for this app (Settings)")
                loggedDisabled = true
            }
            return
        }
        loggedDisabled = false

        // Attributes are immutable; a different station callsign needs a new activity.
        if let current = activity, station != self.station {
            activity = nil
            lastState = nil
            Task { await current.end(dismissalPolicy: .immediate) }
        }

        if let current = activity, Self.isRunning(current) {
            if let last = lastState, Self.sameContent(last, state),
               Date().timeIntervalSince(lastPush) < Self.refreshInterval {
                return
            }
            lastState = state
            lastPush = Date()
            push(state, to: current)
            return
        }

        start(state, station: station)
    }

    private func start(_ state: State, station: String) {
        // Clean up anything left over (previous run, dismissed card) before starting fresh.
        let leftovers = Activity<DroidStarActivityAttributes>.activities
        if !leftovers.isEmpty {
            Task {
                for old in leftovers { await old.end(dismissalPolicy: .immediate) }
            }
        }

        let attributes = DroidStarActivityAttributes(station: station)
        do {
            let newActivity: Activity<DroidStarActivityAttributes>
            if #available(iOS 16.2, *) {
                newActivity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                    pushType: nil)
            } else {
                newActivity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            }
            activity = newActivity
            self.station = station
            lastState = state
            lastPush = Date()
            print("[DroidStar][LiveActivity] Started Live Activity \(newActivity.id) mode=\(state.mode)")
        } catch {
            print("[DroidStar][LiveActivity] Error starting Live Activity: \(error)")
        }
    }

    private func push(_ state: State, to current: Activity<DroidStarActivityAttributes>) {
        Task {
            if #available(iOS 16.2, *) {
                await current.update(ActivityContent(state: state,
                                                     staleDate: Date().addingTimeInterval(Self.staleAfter)))
            } else {
                await current.update(using: state)
            }
        }
    }

    private static func isRunning(_ activity: Activity<DroidStarActivityAttributes>) -> Bool {
        if activity.activityState == .active { return true }
        if #available(iOS 16.2, *) { return activity.activityState == .stale }
        return false
    }

    private static func sameContent(_ a: State, _ b: State) -> Bool {
        a.mode == b.mode && a.callsign == b.callsign && a.handle == b.handle && a.country == b.country
            && a.tgid == b.tgid && a.status == b.status && a.since == b.since
    }
}
