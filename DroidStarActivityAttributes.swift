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

// Shared between the main app target (compiled via DroidStar.pro) and the Widget Extension
// (ios/LiveActivityExtension/project.yml). ActivityKit matches the two by type name, so the
// struct name and the Codable layout must stay identical in both targets.

@available(iOS 16.1, *)
public struct DroidStarActivityAttributes: ActivityAttributes {
    public typealias DroidStarActivityStatus = ContentState

    public struct ContentState: Codable, Hashable {
        /// "RX" (someone is talking), "TX" (we are transmitting), "IDLE" (connected, listening)
        /// or "LINK" (connection lost, reconnecting).
        public var mode: String
        /// Talker callsign (our own on TX, empty when idle).
        public var callsign: String
        /// Talker first name, if known.
        public var handle: String
        public var country: String
        /// Talkgroup / destination.
        public var tgid: String
        /// Connection line, e.g. "DMR · BM Turkey 2862".
        public var status: String
        /// When the current mode started; drives the elapsed timer on the card.
        public var since: Date
        public var timestamp: Date

        public init(mode: String, callsign: String, handle: String, country: String, tgid: String,
                    status: String = "", since: Date = Date(), timestamp: Date = Date()) {
            self.mode = mode
            self.callsign = callsign
            self.handle = handle
            self.country = country
            self.tgid = tgid
            self.status = status
            self.since = since
            self.timestamp = timestamp
        }
    }

    /// Our own station callsign (fixed for the lifetime of the activity).
    public var station: String

    public init(station: String = "") {
        self.station = station
    }
}
