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

// Live Activity UI (lock screen banner + Dynamic Island) for DMR Cep.
// Compiled only into the Widget Extension; the state comes from DroidStarActivityAttributes,
// which the main app fills in through LiveActivityManager.

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Palette (mirrors ui2026/theme/Tokens.qml)

private enum Palette {
    static let body = Color(hex: 0x15171B)       // graphite radio body
    static let surface = Color(hex: 0x1E2127)
    static let stroke = Color(hex: 0x343B46)
    static let text = Color(hex: 0xECEDEF)
    static let muted = Color(hex: 0x9AA1AC)
    static let lcd = Color(hex: 0xF4A62A)        // amber LCD
    static let lcdHi = Color(hex: 0xFFC45C)
    static let lcdInk = Color(hex: 0x2B1702)
    static let rx = Color(hex: 0x3DD68C)         // receiving
    static let tx = Color(hex: 0xFF5147)         // transmitting
    // LCD backlight follows the radio: green while receiving, red while we transmit.
    static let lcdRx = Color(hex: 0x5CCB6E)
    static let lcdRxHi = Color(hex: 0x9BEAA4)
    static let lcdTx = Color(hex: 0xF2574A)
    static let lcdTxHi = Color(hex: 0xFF9A8A)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

// 7-segment font bundled with the extension (UIAppFonts); falls back to a system font.
private func lcdDigits(_ size: CGFloat) -> Font {
    .custom("DSEG7Classic-Bold", size: size)
}

// MARK: - View model

@available(iOS 16.1, *)
private struct CardModel {
    let state: DroidStarActivityAttributes.ContentState
    let station: String
    let stale: Bool

    enum Kind { case rx, tx, idle, link }

    var kind: Kind {
        switch state.mode {
        case "RX": return .rx
        case "TX": return .tx
        case "LINK": return .link
        default: return .idle
        }
    }

    var tint: Color {
        if stale { return Palette.muted }
        switch kind {
        case .rx: return Palette.rx
        case .tx: return Palette.tx
        case .idle: return Palette.lcd
        case .link: return Palette.muted
        }
    }

    var badge: LocalizedStringKey {
        if stale { return "NO SIGNAL" }
        switch kind {
        case .rx: return "RX"
        case .tx: return "TX"
        case .idle: return "STANDBY"
        case .link: return "LINKING"
        }
    }

    var headline: LocalizedStringKey {
        if stale { return "App is not running" }
        switch kind {
        case .rx: return "Receiving"
        case .tx: return "Transmitting"
        case .idle: return state.callsign.isEmpty ? "Listening" : "Last heard"
        case .link: return "Connecting…"
        }
    }

    var callsign: String {
        if !state.callsign.isEmpty { return state.callsign.uppercased() }
        return kind == .tx ? station.uppercased() : "— — —"
    }

    var nameLine: String {
        [state.handle, state.country].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var talkgroup: String { state.tgid }

    var symbol: String {
        switch kind {
        case .tx: return "mic.fill"
        case .link: return "antenna.radiowaves.left.and.right.slash"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Pieces

@available(iOS 16.1, *)
private struct ModeBadge: View {
    let model: CardModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.tint)
                .frame(width: 7, height: 7)
            Text(model.badge)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(model.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(model.tint.opacity(0.16)))
        .overlay(Capsule().stroke(model.tint.opacity(0.45), lineWidth: 1))
    }
}

@available(iOS 16.1, *)
private struct ElapsedText: View {
    let since: Date
    let size: CGFloat
    let color: Color

    var body: some View {
        Text(since, style: .timer)
            .font(lcdDigits(size))
            .monospacedDigit()
            .foregroundColor(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
    }
}

// Amber LCD panel: who is talking, name and talkgroup.
@available(iOS 16.1, *)
private struct LcdPanel: View {
    let model: CardModel

    private var backlight: [Color] {
        if model.stale { return [Palette.lcdHi, Palette.lcd] }
        switch model.kind {
        case .rx: return [Palette.lcdRxHi, Palette.lcdRx]
        case .tx: return [Palette.lcdTxHi, Palette.lcdTx]
        default: return [Palette.lcdHi, Palette.lcd]
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.callsign)
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundColor(Palette.lcdInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(model.nameLine.isEmpty ? " " : model.nameLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.lcdInk.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !model.talkgroup.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("TG")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(Palette.lcdInk.opacity(0.7))
                    Text(model.talkgroup)
                        .font(lcdDigits(18))
                        .foregroundColor(Palette.lcdInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: backlight, startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.lcdInk.opacity(0.25), lineWidth: 1)
        )
        .opacity(model.stale || model.kind == .link ? 0.55 : 1)
    }
}

// MARK: - Lock screen / banner

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ModeBadge(model: model)
                Text(model.headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ElapsedText(since: model.state.since, size: 15, color: model.tint)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            LcdPanel(model: model)
            HStack(spacing: 6) {
                Image(systemName: model.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(model.tint)
                Text(model.state.status.isEmpty ? "DMR Cep" : model.state.status)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !model.station.isEmpty {
                    Text(model.station.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.muted)
                }
            }
        }
        .padding(14)
        .background(Palette.body)
    }
}

// MARK: - Widget

@available(iOS 16.1, *)
struct DroidStarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DroidStarActivityAttributes.self) { context in
            let model = CardModel(state: context.state, station: context.attributes.station,
                                  stale: isStale(context))
            LockScreenView(model: model)
                .activityBackgroundTint(Palette.body)
                .activitySystemActionForegroundColor(Palette.lcd)
        } dynamicIsland: { context in
            let model = CardModel(state: context.state, station: context.attributes.station,
                                  stale: isStale(context))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ModeBadge(model: model)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(since: model.state.since, size: 14, color: model.tint)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(model.headline)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Palette.muted)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        LcdPanel(model: model)
                        Text(model.state.status)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(Palette.muted)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: model.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(model.tint)
                    if model.kind == .rx || model.kind == .tx {
                        Text(model.badge)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundColor(model.tint)
                    }
                }
            } compactTrailing: {
                Group {
                    if model.kind == .rx || model.kind == .tx {
                        Text(model.callsign)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    } else if !model.talkgroup.isEmpty {
                        Text("TG \(model.talkgroup)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    } else {
                        Text(model.badge)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                    }
                }
                .foregroundColor(model.kind == .idle ? Palette.lcd : Palette.text)
                .lineLimit(1)
                .frame(maxWidth: 76)
            } minimal: {
                Image(systemName: model.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(model.tint)
            }
            .keylineTint(model.tint)
        }
    }

    private func isStale(_ context: ActivityViewContext<DroidStarActivityAttributes>) -> Bool {
        if #available(iOSApplicationExtension 16.2, *) {
            return context.isStale
        }
        return false
    }
}

@main
struct DroidStarLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DroidStarLiveActivityWidget()
    }
}
