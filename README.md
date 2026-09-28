# DMR Cep

**DMR Cep**, iPhone'u bir DMR el telsizine çeviren, BrandMeister ve diğer DMR ağlarına bağlanan bir amatör telsiz uygulaması. [DroidStar](https://github.com/nostar/DroidStar) (Doug McLain, AD8DP) ve onun iOS sürümü [Droidstar-DMR](https://github.com/rohithzmoi/Droidstar-DMR) (Rohith Namboothiri, VU3LVO) üzerine kurulu; TB1BDL tarafından geliştiriliyor.

> *English:* DMR Cep is an iOS amateur-radio client for BrandMeister/DMR networks, based on DroidStar and the Droidstar-DMR iOS fork. It adds reliable auto-reconnect, Apple Push-to-Talk, roger beeps and ZVEI-1 five-tone ANI sent as AMBE+2 tone frames, replay of received and own transmissions, a Turkish UI, a redesigned "handheld radio" interface and many iOS audio fixes. GPL-3.0.

## Özellikler

- **El telsizi arayüzü:** kehribar LCD'de 7 segmentli TG numarası, kanal şeridi gibi favori TG'ler, o an konuşanın çağrı işareti, büyük yuvarlak Bağlan/PTT tuşu.
- **Güvenilir bağlantı:** sunucu kapanması (MSTCL/MSTNAK) ve 20 sn sessizlikte otomatik yeniden bağlanma, Wi-Fi ↔ mobil geçişinde hemen yeniden kayıt, el sıkışma paketlerinde tekrar gönderme, çift dokunma koruması, bağlanınca çan sesi.
- **Apple Push-to-Talk (iOS 16+):** kilit ekranı ve Dinamik Ada'da bas-konuş, Bluetooth PTT aksesuarları, konuşanın adı.
- **Roger ve 5 ton:** girişte ve çıkışta farklı roger bipleri, ZVEI-1 5 ton ANI (DMR ID'nin son 5 hanesi). Tonlar AMBE+2 **ton çerçevesi** olarak gönderilir; DVSI vocoder'lı telsizlerde temiz çıkar. Gelen ton çerçeveleri de çalınır.
- **Tekrar dinle:** gelen yayınlar ve kendi yayınların (karşının duyduğu hâliyle) kaydedilir; QSO listesinde her satırda ▶.
- **Ses:** TX için gürültü kapısı + otomatik kazanç + ses tonu (Doğal / İnce 300 Hz / Çok ince 500 Hz), RX için otomatik kazanç.
- **Konuşma grubu:** favoriler (ad BrandMeister'dan), yazarken ad önizleme, 7 haneli numarada "DMR ID gibi görünüyor, özel arama mı?" uyarısı.
- **Konum:** isteğe bağlı telefon GPS'i ile BrandMeister'a istasyon konumu (varsayılan kapalı).
- **Türkçe arayüz** (Ayarlar'dan English seçilebilir).

## Derleme (iOS)

Gerekenler: Xcode 27, Qt **6.11.3** for iOS (6.7.x, Xcode 27 SDK ile derlenmiyor).

```sh
# Qt (aqtinstall ile; yarım kalırsa ios/bin/qmake ve target_qt.conf içindeki host yollarını macos kurulumuna yönlendirin)
aqt install-qt mac desktop 6.11.3 clang_64 -m qtmultimedia
aqt install-qt mac ios 6.11.3 ios -m qtmultimedia --autodesktop

mkdir build-ios && cd build-ios
~/Qt/6.11.3/ios/bin/qmake ../DroidStar.pro CONFIG+=sdk_no_version_check
make -f DroidStar.xcodeproj/qt_preprocess.mak     # Xcode'un yeni derleme sistemi önişlemeyi sıraya koymuyor
xcodebuild -project DroidStar.xcodeproj -scheme DroidStar -configuration Release \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=<takım> PRODUCT_BUNDLE_IDENTIFIER=<paket kimliği> \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDMRCep build
```

Notlar:
- PushToTalk için App ID'de **Push to Talk** ve **Push Notifications** yetenekleri açık olmalı (`DroidStar.entitlements`).
- iOS'ta çoklu ortam arka ucu olarak FFmpeg değil Darwin eklentisi kullanılır (`QTPLUGIN.multimedia = darwinmediaplugin`).
- Uygulama cihazda `Library/Application Support/DroidStar/debug.log` tutar; ses teşhisi için son TX `tx_last_mic.wav` / `tx_last_decoded.wav` olarak yazılır.

## Emeği geçenler

- **Doug McLain, AD8DP** — DroidStar
- **Rohith Namboothiri, VU3LVO** — Droidstar-DMR iOS sürümü ve 2026 arayüzü
- **TB1BDL** — DMR Cep
- 7 segment yazı tipi: [DSEG](https://github.com/keshikan/DSEG) (keshikan, SIL OFL 1.1)
- AMBE+2 ton çerçevesi düzeni için referans: [mbelib-neo](https://github.com/arancormonk/mbelib-neo)

## Lisans

GNU General Public License v3.0 — bkz. [LICENSE](LICENSE). DSEG yazı tipi kendi lisansıyla (`fonts/DSEG-LICENSE.txt`).
