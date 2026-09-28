# Live Activity (lock screen + Dynamic Island): build

The Live Activity has two halves:

| Half | Files | Built by |
| --- | --- | --- |
| App side (ActivityKit start/update/end) | `LiveActivityManager.swift`, `DroidStarActivityAttributes.swift`, `ios_live_activity.mm/.h`, `DroidStar::live_activity_sync()` in `droidstar.cpp` | the qmake-generated `DroidStar.xcodeproj` (main target) |
| Card UI (WidgetKit extension) | `ios/LiveActivityExtension/` (`project.yml`, `Sources/`, `Resources/tr.lproj`, `Info.plist`) + the shared `DroidStarActivityAttributes.swift` and `fonts/DSEG7Classic-Bold.ttf` | XcodeGen + a nested `xcodebuild`, run from the app target's post-link phase |

Nothing has to be clicked in Xcode, and re-running qmake keeps working.

## Build steps

The usual three commands; nothing extra:

```sh
cd <builddir>
~/Qt/6.11.3/ios/bin/qmake <worktree>/DroidStar.pro CONFIG+=sdk_no_version_check
make -f DroidStar.xcodeproj/qt_preprocess.mak        # also retypes the .swift files (see below)
cp <worktree>/Info.plist Info-dmrcep.plist && plutil -replace CFBundleDisplayName -string "DMR Cep" Info-dmrcep.plist
xcodebuild -project DroidStar.xcodeproj -scheme DroidStar -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=ZCPND5K7H5 \
  PRODUCT_BUNDLE_IDENTIFIER=com.tuncabildik.droidstar CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER=d14bebf2-ea5e-4480-870d-02e15993bf5d \
  INFOPLIST_FILE=<builddir>/Info-dmrcep.plist ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDMRCep build
```

The build log shows three `[LiveActivity]` lines (signing, building, embedded). The result is
`Release-iphoneos/DroidStar.app/PlugIns/DroidStarLiveActivityExtension.appex`, signed before
the app itself, so `codesign --verify --deep --strict DroidStar.app` passes.

Requirements: `xcodegen` (`brew install xcodegen`; the script also looks in `/opt/homebrew/bin`).

## Signing the extension

* Bundle id: `<app bundle id>.LiveActivity`, i.e. `com.tuncabildik.droidstar.LiveActivity`
  (App Store Connect bundle id `VHFW64WB23`, no capabilities).
* Development profile: `DMR Cep LiveActivity Dev`, UUID `05f69c7b-1511-4db5-b5cc-4a7dfb906952`
  (certificate `8X96WB3W6G`, device `5ZTQB55FXU`, expires 2027-09-28). Installed under
  `~/Library/MobileDevice/Provisioning Profiles` and `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
* The script picks the profile automatically: first an installed, unexpired profile whose app id
  is exactly `TEAM.<extension id>`, else the team wildcard profile (`TEAM.*`). Override with
  `LIVEACTIVITY_PROVISIONING_PROFILE=<name or UUID>`.
* Team and identity come from the app target (`DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`); the
  extension version is copied from the app's Info.plist.
* For App Store / TestFlight builds, create an `IOS_APP_STORE` profile for the same bundle id
  and pass it via `LIVEACTIVITY_PROVISIONING_PROFILE`; when a new device is added, regenerate
  the development profile as well (it lists devices like the app's profile).

Other switches: `LIVEACTIVITY_SKIP=1` builds the app without the extension;
`LIVEACTIVITY_BUNDLE_ID=...` changes the extension id.

## Why it did not work before

1. **The Swift files were never compiled.** qmake's Xcode generator lists `.swift` files from
   `SOURCES` but only puts files with a known C/C++/ObjC extension into "Compile Sources", so
   `LiveActivityManager` was missing from the binary and `NSClassFromString` returned nil
   ("LiveActivityManager class not found"). Fix: `QMAKE_EXT_CPP += .swift` gets them into
   Compile Sources, and `scripts/xcodeproj_swift_filetype.sh` (an extra compiler in
   `DroidStar.pro`, so it runs inside `qt_preprocess.mak` right after qmake and again whenever
   qmake rewrites the project) retypes them from `sourcecode.cpp.cpp` to `sourcecode.swift`.
   If the preprocess step is skipped, the build fails loudly with `unknown type name 'import'`
   rather than silently dropping the feature.
2. **The Swift build settings were no-ops.** `QMAKE_MAC_XCODE_SETTINGS += SWIFT_VERSION=5.0`
   writes a setting literally named `SWIFT_VERSION=5.0`. They are now `.name`/`.value` pairs.
3. **There was no Widget Extension.** Without it iOS has no UI for the activity. It is now
   generated from `ios/LiveActivityExtension/project.yml` by
   `scripts/embed_live_activity_extension.sh` (`QMAKE_POST_LINK`), built in a clean
   environment into `<builddir>/liveactivity/`, and copied into `DroidStar.app/PlugIns`
   before Xcode signs the app.

## Runtime behaviour

`DroidStar::live_activity_sync()` drives the card from C++ (the QML driver in `App2026.qml`
was removed, so it keeps working while the UI is suspended):

| Event | Card |
| --- | --- |
| Link up (`CONNECTED_RW`) | starts, `STANDBY`, amber, "Listening" |
| RX start / talker change | `RX`, green: callsign, name + country (from the QML lookup via `updateNowPlayingRX`), TG, elapsed time |
| RX end | `STANDBY`, "Last heard" + last talker, time since |
| TX (app button, headphones, system PTT) | `TX`, red: own callsign, TG |
| Link lost, auto-reconnect running | `LINKING`, grey (not ended, so no flicker) |
| Manual disconnect, reconnect given up/cancelled | ended immediately |
| App start | orphan activities from a killed run are ended |

Content is only pushed when it changes (update_data fires per voice frame). A 5-minute
refresh keeps a quiet link fresh; if the app dies the card turns stale after ~11 minutes and
shows "NO SIGNAL" instead of freezing.

On the device: Settings → DMR Cep → Live Activities must be on. The log shows
`[DroidStar][LiveActivity] Started Live Activity ...` when it works.
