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

import Foundation
import AppIntents

// Action Button / Shortcuts / Siri PTT.
//
// The intents run inside the app process (openAppWhenRun = false; the system launches or wakes
// the app in the background) and forward to DSHardwarePTT in HardwareButtonPTT.mm, which calls
// the same C++ handler as the volume buttons (DroidStar::hw_ptt_action).
//
// They conform to PushToTalkTransmissionIntent (iOS 17.4+): that is what allows a Push to Talk
// app to call PTChannelManager.requestBeginTransmitting while it is in the background. So when
// "System Push-to-Talk" is on (channel joined), TX from the Action Button also works with the
// phone locked. Apple's guidance is to return from perform() only after didBeginTransmitting,
// so we wait (bounded) for the system to confirm.
//
// Setup for the user: Settings > Action Button > Shortcut > DMR Cep > "Bas-konuş".

@available(iOS 17.4, *)
enum DSPttBridge {
    static let actionStop = 0
    static let actionStart = 1
    static let actionToggle = 2

    @MainActor
    private static func call(_ selector: String, _ arg: NSNumber? = nil) -> Int? {
        guard let cls = NSClassFromString("DSHardwarePTT") else {
            NSLog("[HWPTT] DSHardwarePTT class not found")
            return nil
        }
        let obj: AnyObject = cls
        let sel = NSSelectorFromString(selector)
        let result = arg != nil ? obj.perform(sel, with: arg) : obj.perform(sel)
        return (result?.takeUnretainedValue() as? NSNumber)?.intValue
    }

    /// Runs a TX action. Returns the TX state afterwards (true = on air).
    @MainActor
    static func run(_ action: Int) async throws -> Bool {
        guard let r = call("performIntentAction:", NSNumber(value: action)), r >= 0 else {
            throw DSPttError.notConnected
        }
        if r == 1, (call("systemPTTState") ?? 0) >= 1 {
            // System PTT channel joined: wait for didBeginTransmitting (max ~1.5 s).
            for _ in 0..<30 {
                if call("systemPTTState") == 2 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            NSLog("[HWPTT] intent: system PTT state after start = %d", call("systemPTTState") ?? -1)
        }
        return r == 1
    }
}

@available(iOS 17.4, *)
enum DSPttError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected:
            return "DMR Cep bağlı değil. Önce uygulamayı açıp bir sunucuya bağlan."
        }
    }
}

@available(iOS 17.4, *)
struct DSToggleTransmitIntent: AppIntent, PushToTalkTransmissionIntent {
    static var title: LocalizedStringResource = "Bas-konuş"
    static var description = IntentDescription("DMR Cep'te yayını başlatır; yayındaysan bitirir. Eylem Tuşu'na atanabilir.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await DSPttBridge.run(DSPttBridge.actionToggle)
        return .result()
    }
}

@available(iOS 17.4, *)
struct DSStartTransmitIntent: AppIntent, PushToTalkTransmissionIntent {
    static var title: LocalizedStringResource = "Yayına başla"
    static var description = IntentDescription("DMR Cep'te yayını (TX) başlatır.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await DSPttBridge.run(DSPttBridge.actionStart)
        return .result()
    }
}

@available(iOS 17.4, *)
struct DSStopTransmitIntent: AppIntent, PushToTalkTransmissionIntent {
    static var title: LocalizedStringResource = "Yayını bitir"
    static var description = IntentDescription("DMR Cep'te yayını (TX) bitirir.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await DSPttBridge.run(DSPttBridge.actionStop)
        return .result()
    }
}

@available(iOS 17.4, *)
struct DSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DSToggleTransmitIntent(),
                    phrases: ["\(.applicationName) bas konuş", "\(.applicationName) ile konuş"],
                    shortTitle: "Bas-konuş",
                    systemImageName: "mic.circle.fill")
        AppShortcut(intent: DSStartTransmitIntent(),
                    phrases: ["\(.applicationName) yayına başla"],
                    shortTitle: "Yayına başla",
                    systemImageName: "mic.fill")
        AppShortcut(intent: DSStopTransmitIntent(),
                    phrases: ["\(.applicationName) yayını bitir"],
                    shortTitle: "Yayını bitir",
                    systemImageName: "mic.slash.fill")
    }
}
