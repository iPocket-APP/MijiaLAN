#!/usr/bin/env bash
# Build a signed, notarized Apple Silicon experience package. Does not publish it.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Run on an Apple Silicon Mac" >&2; exit 1; }
: "${MIJIALAN_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
: "${MIJIALAN_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
[[ "$MIJIALAN_SIGNING_IDENTITY" != - ]] || { echo "Distribution requires Developer ID signing" >&2; exit 1; }
version="$(python3 -c 'import tomllib; print(tomllib.load(open("Cargo.toml", "rb"))["workspace"]["package"]["version"])')"
build_number="${MIJIALAN_BUILD_NUMBER:-2}"
release="$root/build/releases/v$version-rs.1"
staging="$release/staging"
dist="$release/dist"
logs="$release/logs"
app="$staging/MijiaLAN.app"
name="MijiaLAN-rs-$version-macos-arm64"
mkdir -p "$staging" "$dist" "$logs"

case "${1:-}" in
  "")
    cargo fmt --all --check > "$logs/format.log" 2>&1
    cargo test --locked --release --workspace -j 4 > "$logs/tests.log" 2>&1
    MIJIALAN_BUILD_NUMBER="$build_number" MIJIALAN_APP_OUTPUT="$app" MIJIALAN_APP_NAME=MijiaLAN \
      bash scripts/build-macos.sh release > "$logs/bundle.log" 2>&1
    cargo metadata --locked --format-version 1 --filter-platform aarch64-apple-darwin > "$release/cargo-metadata.json"
    python3 scripts/collect-cargo-licenses.py "$release/cargo-metadata.json" "$app/Contents/Resources/Licenses/Cargo"
    # Notices are part of the sealed resources; sign again after adding them.
    codesign --force --sign "$MIJIALAN_SIGNING_IDENTITY" --options runtime --timestamp "$app"
    ;;
  --package-existing) echo "Packaging the existing signed app: $app" ;;
  *) echo "Usage: $0 [--package-existing]" >&2; exit 1 ;;
esac

[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == xyz.ipocket.MijiaLAN.Rust ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" == "$build_number" ]]
for binary in mijialan-rust mijia-rust; do
  lipo "$app/Contents/MacOS/$binary" -verify_arch arm64
  codesign --verify --strict "$app/Contents/MacOS/$binary"
done
codesign --verify --deep --strict "$app"
codesign --display --verbose=4 "$app" 2> "$logs/signature.txt"
grep -q '^Authority=Developer ID Application:' "$logs/signature.txt"
grep -q 'flags=.*runtime' "$logs/signature.txt"
grep -q '^Timestamp=' "$logs/signature.txt"

ditto -c -k --sequesterRsrc --keepParent "$app" "$release/notarization.zip"
xcrun notarytool submit "$release/notarization.zip" --keychain-profile "$MIJIALAN_NOTARY_PROFILE" \
  --wait --timeout 20m --output-format json > "$logs/notarization-app.json"
[[ "$(plutil -extract status raw "$logs/notarization-app.json")" == Accepted ]]
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app" 2> "$logs/gatekeeper-app.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$name.zip"

image_root="$release/dmg-root"
mkdir -p "$image_root"
ditto "$app" "$image_root/MijiaLAN.app"
ln -sfn /Applications "$image_root/Applications"
cp LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md "$image_root/"
cat > "$image_root/体验说明.txt" <<'NOTE'
MijiaLAN · Rust 版 · Apple Silicon

将 MijiaLAN.app 拖入 Applications，或在磁盘映像中直接打开。
本版本使用独立于 Swift 版的数据目录，保留此前 Rust 版导入的设备和配对资料。
请避免同时运行两个使用同一 Rust 数据目录的桥接实例。
首次使用 Developer ID 签名版本时，macOS 可能要求重新允许读取已有钥匙串凭据。
NOTE
hdiutil create -volname "MijiaLAN rs $version" -srcfolder "$image_root" -format UDZO -ov "$dist/$name.dmg"
codesign --force --sign "$MIJIALAN_SIGNING_IDENTITY" --timestamp "$dist/$name.dmg"
codesign --verify --strict "$dist/$name.dmg"
xcrun notarytool submit "$dist/$name.dmg" --keychain-profile "$MIJIALAN_NOTARY_PROFILE" \
  --wait --timeout 20m --output-format json > "$logs/notarization-dmg.json"
[[ "$(plutil -extract status raw "$logs/notarization-dmg.json")" == Accepted ]]
xcrun stapler staple "$dist/$name.dmg"
xcrun stapler validate "$dist/$name.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dist/$name.dmg" 2> "$logs/gatekeeper-dmg.txt"
(cd "$dist" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)
echo "Signed and notarized packages: $dist"
