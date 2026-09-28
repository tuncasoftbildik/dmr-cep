#!/bin/bash
# Builds the Live Activity Widget Extension (ios/LiveActivityExtension) and embeds the signed
# .appex into the app bundle being built.
#
# Runs as the qmake post-link build phase of the DroidStar target (QMAKE_POST_LINK in
# DroidStar.pro), i.e. after the app binary is linked and before Xcode signs the app, so the
# nested extension is sealed into the app signature. See docs/live-activity-build.md.
#
# Environment overrides (all optional):
#   LIVEACTIVITY_SKIP=1                     do nothing (app builds without the card UI)
#   LIVEACTIVITY_BUNDLE_ID=...              default: $PRODUCT_BUNDLE_IDENTIFIER.LiveActivity
#   LIVEACTIVITY_PROVISIONING_PROFILE=...   profile name or UUID for the extension; default:
#                                           the installed profile for the bundle id, else the
#                                           team wildcard profile
#   XCODEGEN=/path/to/xcodegen              default: xcodegen on PATH or /opt/homebrew/bin

set -euo pipefail

log() { echo "[LiveActivity] $*"; }

if [ "${LIVEACTIVITY_SKIP:-0}" = "1" ]; then
    log "LIVEACTIVITY_SKIP=1, not embedding the widget extension"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC="$SRC_ROOT/ios/LiveActivityExtension/project.yml"
EXT_TARGET="DroidStarLiveActivityExtension"

: "${TARGET_BUILD_DIR:?must run inside an Xcode build phase}"
: "${CONFIGURATION:?}"
: "${PLATFORM_NAME:?}"
: "${PROJECT_DIR:?}"
PLUGINS_DIR="$TARGET_BUILD_DIR/${PLUGINS_FOLDER_PATH:-${WRAPPER_NAME:-DroidStar.app}/PlugIns}"

XCODEGEN_BIN="${XCODEGEN:-$(command -v xcodegen || true)}"
[ -z "$XCODEGEN_BIN" ] && [ -x /opt/homebrew/bin/xcodegen ] && XCODEGEN_BIN=/opt/homebrew/bin/xcodegen
[ -z "$XCODEGEN_BIN" ] && [ -x /usr/local/bin/xcodegen ] && XCODEGEN_BIN=/usr/local/bin/xcodegen
if [ -z "$XCODEGEN_BIN" ]; then
    echo "error: [LiveActivity] xcodegen not found (brew install xcodegen), or set LIVEACTIVITY_SKIP=1" >&2
    exit 1
fi

WORK="$PROJECT_DIR/liveactivity"
mkdir -p "$WORK"

# Generate the extension project next to the qmake project (never inside the source tree).
"$XCODEGEN_BIN" generate --quiet --spec "$SPEC" --project "$WORK"

APP_BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.tuncabildik.droidstar}"
EXT_BUNDLE_ID="${LIVEACTIVITY_BUNDLE_ID:-$APP_BUNDLE_ID.LiveActivity}"

# Keep the extension version in step with the app (App Store validation requires it).
APP_PLIST="$TARGET_BUILD_DIR/${INFOPLIST_PATH:-}"
SHORT_VERSION="${QMAKE_SHORT_VERSION:-1.0}"
BUILD_VERSION="${QMAKE_FULL_VERSION:-1}"
if [ -n "${INFOPLIST_PATH:-}" ] && [ -f "$APP_PLIST" ]; then
    SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo "$SHORT_VERSION")"
    BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo "$BUILD_VERSION")"
fi

# Finds an installed provisioning profile (UUID) whose app id is exactly TEAM.<id>.
find_profile() {
    local wanted="$1" f tmp appid uuid
    tmp="$(mktemp -t la-profile)"
    for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
             "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
        [ -f "$f" ] || continue
        security cms -D -i "$f" > "$tmp" 2>/dev/null || continue
        appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null || true)"
        if [ "$appid" = "$wanted" ]; then
            # Skip expired profiles.
            local exp
            exp="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp" 2>/dev/null || true)"
            if [ -n "$exp" ] && [ "$(date -j -f '%a %b %d %T %Z %Y' "$exp" +%s 2>/dev/null || echo 9999999999)" -lt "$(date +%s)" ]; then
                continue
            fi
            uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$tmp")"
            rm -f "$tmp"
            echo "$uuid"
            return 0
        fi
    done
    rm -f "$tmp"
    return 1
}

SIGN_ARGS=()
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    SIGN_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
elif [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
    SIGN_ARGS+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
else
    TEAM="${DEVELOPMENT_TEAM:-}"
    if [ -z "$TEAM" ]; then
        echo "error: [LiveActivity] DEVELOPMENT_TEAM is not set for the app target" >&2
        exit 1
    fi
    PROFILE="${LIVEACTIVITY_PROVISIONING_PROFILE:-}"
    if [ -z "$PROFILE" ]; then
        PROFILE="$(find_profile "$TEAM.$EXT_BUNDLE_ID" || find_profile "$TEAM.*" || true)"
    fi
    if [ -z "$PROFILE" ]; then
        echo "error: [LiveActivity] no provisioning profile for $TEAM.$EXT_BUNDLE_ID; see docs/live-activity-build.md" >&2
        exit 1
    fi
    IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
    log "signing $EXT_BUNDLE_ID with profile $PROFILE ($IDENTITY)"
    SIGN_ARGS+=(CODE_SIGN_STYLE=Manual "DEVELOPMENT_TEAM=$TEAM" "CODE_SIGN_IDENTITY=$IDENTITY"
                "PROVISIONING_PROFILE_SPECIFIER=$PROFILE")
fi

SYMROOT_DIR="$WORK/build"
log "building $EXT_TARGET ($CONFIGURATION, $PLATFORM_NAME, ${ARCHS:-default archs})"

# Run the nested build in a clean environment: Xcode exports hundreds of build settings to
# script phases and xcodebuild would pick them up as overrides for the extension.
env -i HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} \
    xcodebuild -quiet \
        -project "$WORK/DroidStarLiveActivity.xcodeproj" \
        -target "$EXT_TARGET" \
        -configuration "$CONFIGURATION" \
        -sdk "$PLATFORM_NAME" \
        SYMROOT="$SYMROOT_DIR" \
        OBJROOT="$WORK/obj" \
        ${ARCHS:+ARCHS="$ARCHS"} \
        ONLY_ACTIVE_ARCH=NO \
        INFOPLIST_FILE="$SRC_ROOT/ios/LiveActivityExtension/Info.plist" \
        PRODUCT_BUNDLE_IDENTIFIER="$EXT_BUNDLE_ID" \
        MARKETING_VERSION="$SHORT_VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
        "${SIGN_ARGS[@]}" \
        build

APPEX="$SYMROOT_DIR/$CONFIGURATION-$PLATFORM_NAME/$EXT_TARGET.appex"
if [ ! -d "$APPEX" ]; then
    echo "error: [LiveActivity] extension build produced no $APPEX" >&2
    exit 1
fi

mkdir -p "$PLUGINS_DIR"
rm -rf "$PLUGINS_DIR/$EXT_TARGET.appex"
ditto "$APPEX" "$PLUGINS_DIR/$EXT_TARGET.appex"
log "embedded $EXT_TARGET.appex ($EXT_BUNDLE_ID $SHORT_VERSION/$BUILD_VERSION) into $PLUGINS_DIR"
