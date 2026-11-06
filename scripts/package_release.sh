#!/usr/bin/env bash
# Build, sign, notarize and staple a universal release. Does not publish it.
# Required: MIJIALAN_SIGN_IDENTITY (Developer ID Application),
#           MIJIALAN_NOTARY_PROFILE (an existing notarytool Keychain profile).
# Use --package-existing to retry packaging a previously built, signed staging app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${MIJIALAN_VERSION:-$(python3 "$ROOT/scripts/release_metadata.py" version)}"
BUILD_NUMBER="${MIJIALAN_BUILD_NUMBER:-$(python3 "$ROOT/scripts/release_metadata.py" build-number)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Expected a positive build number" >&2; exit 1; }
: "${MIJIALAN_SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
: "${MIJIALAN_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
[[ "$MIJIALAN_SIGN_IDENTITY" != - ]] || { echo "Ad hoc signing is not allowed for distribution" >&2; exit 1; }

RELEASE="$ROOT/build/releases/v$VERSION"
STAGING="$RELEASE/staging"
DIST="$RELEASE/dist"
LOGS="$RELEASE/logs"
APP="$STAGING/MijiaLAN.app"
NAME="MijiaLAN-$VERSION-universal"
SYMBOLS="$RELEASE/symbols"
mkdir -p "$STAGING" "$LOGS" "$SYMBOLS"

NOTARY_ARGS=(--profile "$MIJIALAN_NOTARY_PROFILE")
if [[ -n "${MIJIALAN_NOTARY_KEYCHAIN:-}" ]]; then
    NOTARY_ARGS+=(--keychain "$MIJIALAN_NOTARY_KEYCHAIN")
fi

staple() {
    local attempt
    for attempt in 1 2 3; do
        if xcrun stapler staple "$1"; then xcrun stapler validate "$1"; return; fi
        [[ "$attempt" -lt 3 ]] || return 1
        sleep "$((attempt * 5))"
    done
}

cd "$ROOT"
case "${1:-}" in
    "")
        python3 -m unittest discover -s "$ROOT/scripts/tests" -v 2>&1 | tee "$LOGS/release-tools-tests.log"
        swift test --package-path Vendor/MenuBarMijia --scratch-path "$ROOT/.build/mijiacore-tests" \
            -c release --force-resolved-versions 2>&1 | tee "$LOGS/mijiacore-tests.log"
        swift test -c release --force-resolved-versions 2>&1 | tee "$LOGS/tests.log"
        MIJIALAN_APP_OUTPUT="$APP" MIJIALAN_UNIVERSAL=1 \
            MIJIALAN_VERSION="$VERSION" MIJIALAN_BUILD_NUMBER="$BUILD_NUMBER" \
            MIJIALAN_DSYM_OUTPUT="$SYMBOLS/MijiaLAN.app.dSYM" \
            "$ROOT/scripts/build_app.sh" release 2>&1 | tee "$LOGS/build.log"
        ;;
    --package-existing) echo "Packaging the existing staging app: $APP" ;;
    *) echo "Usage: $0 [--package-existing]" >&2; exit 1 ;;
esac
rm -rf "$DIST"
mkdir -p "$DIST"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/swift_runtime.py" verify "$APP" --report "$LOGS/swift-runtime.json"
for ARCH in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/MijiaLAN" -verify_arch "$ARCH"
done
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]]
codesign --display --verbose=4 "$APP" 2> "$LOGS/signature.txt"
grep -q '^Authority=Developer ID Application:' "$LOGS/signature.txt"
grep -q 'flags=.*runtime' "$LOGS/signature.txt"
grep -q '^Timestamp=' "$LOGS/signature.txt"

# Notarize the outermost container once. Apple issues tickets for both the DMG
# and its nested app; the same app ticket can then be stapled before ZIP creation.
IMAGE_ROOT="$RELEASE/dmg-root"
rm -rf "$IMAGE_ROOT"
mkdir -p "$IMAGE_ROOT"
ditto "$APP" "$IMAGE_ROOT/MijiaLAN.app"
ln -sfn /Applications "$IMAGE_ROOT/Applications"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$IMAGE_ROOT/"
hdiutil create -volname "MijiaLAN $VERSION" -srcfolder "$IMAGE_ROOT" \
    -format UDZO -imagekey zlib-level=9 -ov "$DIST/$NAME.dmg"
codesign --force --sign "$MIJIALAN_SIGN_IDENTITY" --timestamp "$DIST/$NAME.dmg"
codesign --verify --strict "$DIST/$NAME.dmg"
python3 "$ROOT/scripts/notarize.py" "$DIST/$NAME.dmg" \
    "${NOTARY_ARGS[@]}" --log-prefix "$LOGS/notarization-dmg"
staple "$DIST/$NAME.dmg"
hdiutil verify "$DIST/$NAME.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 \
    "$DIST/$NAME.dmg" 2> "$LOGS/gatekeeper-dmg.txt"
staple "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2> "$LOGS/gatekeeper-app.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

cd "$DIST"
shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt
python3 - "$ROOT" "$APP" "$VERSION" "$BUILD_NUMBER" "$LOGS/release-info.json" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
root, app, version, build, output = sys.argv[1:]
info = plistlib.loads((pathlib.Path(app) / 'Contents/Info.plist').read_bytes())
report = {
    'version': version, 'build_number': int(build), 'minimum_macos': info['LSMinimumSystemVersion'],
    'source_commit': subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', '-C', root, 'status', '--porcelain'])),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'artifacts': {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                  for p in sorted(pathlib.Path.cwd().iterdir()) if p.is_file()},
}
pathlib.Path(output).write_text(json.dumps(report, indent=2) + '\n')
PY
echo "Signed, notarized artifacts: $DIST"
