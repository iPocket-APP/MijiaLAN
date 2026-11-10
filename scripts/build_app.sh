#!/usr/bin/env bash
# Builds build/MijiaLAN.app, ad hoc signed for local use by default.
#
#   scripts/build_app.sh            # release
#   scripts/build_app.sh debug
# Set MIJIALAN_UNIVERSAL=1 for Apple Silicon + Intel, and MIJIALAN_SIGN_IDENTITY
# to a Developer ID Application identity for timestamped hardened runtime signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
MINIMUM_MACOS=12.0
BUNDLE_IDENTIFIER="com.mijialan.MijiaLAN"
VERSION="${MIJIALAN_VERSION:-$(python3 "$ROOT/scripts/release_metadata.py" version)}"
BUILD_NUMBER="${MIJIALAN_BUILD_NUMBER:-$(python3 "$ROOT/scripts/release_metadata.py" build-number)}"
SIGN_IDENTITY="${MIJIALAN_SIGN_IDENTITY:--}"
APP="${MIJIALAN_APP_OUTPUT:-$ROOT/build/MijiaLAN.app}"

[[ "$CONFIG" == release || "$CONFIG" == debug ]] || { echo "Expected release or debug" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Expected a positive build number" >&2; exit 1; }
[[ "$APP" == /*.app ]] || { echo "App output must be an absolute .app path" >&2; exit 1; }

cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS"
BUILD_ARGS=(-c "$CONFIG" --force-resolved-versions --product MijiaLANApp)
if [[ "${MIJIALAN_UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MijiaLANApp" "$APP/Contents/MacOS/MijiaLAN"
# MijiaCore's translation tables; MijiaCore finds them under Contents/Resources.
cp -R "$BIN_DIR/MenuBarMijia_MijiaCore.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/MijiaLAN_MijiaLAN.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
# Icon Composer supplies the layered system icon and an ICNS fallback for older macOS.
xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target "$MINIMUM_MACOS" \
    --output-format human-readable-text \
    --output-partial-info-plist "$APP/Contents/Resources/AppIcon-info.plist"
# Ship the original notices, including notices for bundled third party C code.
mkdir -p "$APP/Contents/Resources/Licenses/MijiaLAN"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/MijiaLAN/"
mkdir -p "$APP/Contents/Resources/Licenses/lucide"
cp "$ROOT/Resources/Licenses/lucide/LICENSE" "$APP/Contents/Resources/Licenses/lucide/"
cp "$ROOT/PRIVACY.md" "$ROOT/PRIVACY.en.md" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
# ditto preserves the versioned framework's symlinks and executable permissions.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' NOTICE; do
    RELATIVE="${NOTICE#"$ROOT/"}"
    RELATIVE="${RELATIVE#.build/checkouts/}"
    DESTINATION="$APP/Contents/Resources/Licenses/$RELATIVE"
    mkdir -p "$(dirname "$DESTINATION")"
    cp "$NOTICE" "$DESTINATION"
done < <(find "$ROOT/.build/checkouts" "$ROOT/Vendor/MenuBarMijia" "$ROOT/Vendor/hap-swift" "$ROOT/Vendor/mdns-swift" "$ROOT/Vendor/hass-xiaomi-miot" "$ROOT/Vendor/homebridge-miot" -type f \
    \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'COPYING*' -o -iname 'PATENTS*' \
    -o -name 'CNIOSHA1.h' -o -name 'cpp_magic.h' \) \
    -not -path '*/.git/*' -print0)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleDisplayName</key>
    <string>MijiaLAN</string>
    <key>CFBundleExecutable</key>
    <string>MijiaLAN</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MijiaLAN</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_MACOS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MijiaLAN controls Mijia Wi-Fi devices directly over your local network and provides a HomeKit bridge for the Home app on your iPhone.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_hap._tcp</string>
        <string>_miio._udp</string>
    </array>
</dict>
</plist>
PLIST

# Monterey registers this background-only login item through Service Management.
LOGIN_ITEM="$APP/Contents/Library/LoginItems/MijiaLANLoginItem.app"
mkdir -p "$LOGIN_ITEM/Contents/MacOS"
LOGIN_ARCHES=()
for ARCH in $(lipo -archs "$APP/Contents/MacOS/MijiaLAN"); do
    LOGIN_ARCHES+=(-arch "$ARCH")
done
xcrun --sdk macosx clang -Os -fobjc-arc -framework AppKit -mmacosx-version-min="$MINIMUM_MACOS" \
    "${LOGIN_ARCHES[@]}" "$ROOT/Sources/MijiaLANLoginItem/main.m" -o "$LOGIN_ITEM/Contents/MacOS/MijiaLANLoginItem"
cat > "$LOGIN_ITEM/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER.LoginItem</string>
    <key>CFBundleExecutable</key>
    <string>MijiaLANLoginItem</string>
    <key>CFBundleName</key>
    <string>MijiaLAN</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_MACOS</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST
plutil -lint "$LOGIN_ITEM/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Merge '$APP/Contents/Resources/AppIcon-info.plist'" "$APP/Contents/Info.plist"
rm "$APP/Contents/Resources/AppIcon-info.plist"
python3 "$ROOT/scripts/sparkle_updates.py" configure-app "$APP"
plutil -lint "$APP/Contents/Info.plist"
if [[ "${MIJIALAN_UNIVERSAL:-0}" == 1 ]]; then
    for ARCH in arm64 x86_64; do
        lipo "$APP/Contents/MacOS/MijiaLAN" -verify_arch "$ARCH"
    done
fi
if [[ "$CONFIG" == release ]]; then
    # Keep matching symbols outside the distributable app for crash diagnosis.
    if [[ -n "${MIJIALAN_DSYM_OUTPUT:-}" ]]; then
        [[ "$MIJIALAN_DSYM_OUTPUT" == /*.dSYM ]] || { echo "dSYM output must be an absolute .dSYM path" >&2; exit 1; }
        rm -rf "$MIJIALAN_DSYM_OUTPUT"
        mkdir -p "$(dirname "$MIJIALAN_DSYM_OUTPUT")"
        if [[ -d "$BIN_DIR/MijiaLANApp.dSYM" ]]; then
            ditto "$BIN_DIR/MijiaLANApp.dSYM" "$MIJIALAN_DSYM_OUTPUT"
        else
            xcrun dsymutil "$BIN_DIR/MijiaLANApp" -o "$MIJIALAN_DSYM_OUTPUT"
        fi
        python3 - "$BIN_DIR/MijiaLANApp" "$MIJIALAN_DSYM_OUTPUT" <<'PY'
import re, subprocess, sys
def uuids(path):
    return set(re.findall(r"UUID: ([0-9A-F-]+) \(([^)]+)\)",
        subprocess.check_output(["xcrun", "dwarfdump", "--uuid", path], text=True)))
binary, symbols = map(uuids, sys.argv[1:])
assert binary and binary == symbols, "dSYM UUIDs do not match the release executable"
PY
    fi
    # Drop local symbols as well as debug entries, retaining exported symbols
    # and Swift/Objective-C runtime metadata.
    strip -S -x "$APP/Contents/MacOS/MijiaLAN"
fi
python3 "$ROOT/scripts/swift_runtime.py" embed "$APP" --sign "$SIGN_IDENTITY"
bash "$ROOT/scripts/sign_app.sh" "$APP" "$SIGN_IDENTITY"
echo "$APP"
