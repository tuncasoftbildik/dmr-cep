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
import SwiftUI
import UIKit
import Translation

// The English -> Turkish language pack can only be downloaded with the user's consent, through
// SwiftUI's .translationTask (prepareTranslation() shows the system download sheet). The app UI is
// QML, so Settings calls ds_subtitle_open_translation_download() and this small sheet is presented
// in a UIHostingController over the Qt view controller. When it closes, the subtitle engine
// re-checks the pack (ds_subtitle_refresh_status) and starts translating.

@available(iOS 18.0, *)
private struct DSTranslationDownloadView: View {
    let onClose: () -> Void
    @State private var config: TranslationSession.Configuration?
    @State private var status: LanguageAvailability.Status?
    @State private var message = ""
    @State private var working = false

    private let en = Locale.Language(identifier: "en")
    private let tr = Locale.Language(identifier: "tr")

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Altyazılar İngilizce tanınır ve telefonda, internet olmadan Türkçeye çevrilir. Bunun için Apple'ın İngilizce → Türkçe çeviri paketi bir kez indirilir.")
                    .font(.body)
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(statusText).font(.headline)
                }
                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    working = true
                    message = ""
                    if config == nil {
                        config = TranslationSession.Configuration(source: en, target: tr)
                    } else {
                        config?.invalidate()
                    }
                } label: {
                    Label(status == .installed ? "Paket yüklü" : "Türkçe çeviri paketi indir",
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(status == .installed || status == .unsupported || working)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Türkçe çeviri")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tamam") { onClose() }
                }
            }
        }
        .translationTask(config) { session in
            do {
                try await session.prepareTranslation()
                NSLog("[Altyazi] translation pack prepared")
            } catch {
                NSLog("[Altyazi] prepareTranslation failed: %@", "\(error)")
                await MainActor.run { message = "İndirme tamamlanmadı: \(error.localizedDescription)" }
            }
            await refresh()
            await MainActor.run { working = false }
        }
        .task { await refresh() }
        .onDisappear { ds_subtitle_refresh_status() }     // also after a swipe-down
    }

    private func refresh() async {
        let st = await LanguageAvailability().status(from: en, to: tr)
        await MainActor.run { status = st }
    }

    private var statusText: String {
        switch status {
        case .installed: return "Çeviri paketi yüklü"
        case .supported: return "Çeviri paketi indirilmedi"
        case .unsupported: return "Bu cihazda İngilizce → Türkçe çeviri yok"
        default: return "Denetleniyor…"
        }
    }
    private var icon: String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .unsupported: return "xmark.circle"
        default: return "arrow.down.circle"
        }
    }
    private var color: Color {
        switch status {
        case .installed: return .green
        case .unsupported: return .red
        default: return .orange
        }
    }
}

@MainActor
private func dsTopViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var vc = window?.rootViewController
    while let p = vc?.presentedViewController { vc = p }
    return vc
}

@_cdecl("ds_subtitle_open_translation_download")
public func ds_subtitle_open_translation_download() {
    DispatchQueue.main.async {
        guard #available(iOS 18.0, *) else { return }
        guard let top = dsTopViewController() else {
            NSLog("[Altyazi] no view controller to present the translation sheet")
            return
        }
        weak var host: UIViewController?
        let view = DSTranslationDownloadView { host?.dismiss(animated: true) }
        let hc = UIHostingController(rootView: view)
        hc.modalPresentationStyle = .pageSheet
        if let sheet = hc.sheetPresentationController { sheet.detents = [.medium(), .large()] }
        host = hc
        top.present(hc, animated: true)
    }
}
