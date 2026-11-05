#!/usr/bin/env bash
# Sign nested updater helpers first, preserving the downloader's sandbox entitlements.
set -euo pipefail
app="${1:?Pass the Rust app bundle}"
identity="${2:--}"
flags=(--force --sign "$identity")
if [[ "$identity" == - ]]; then flags+=(--timestamp=none); else flags+=(--options runtime --timestamp); fi
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$sparkle" ]]; then
  codesign "${flags[@]}" "$sparkle/XPCServices/Installer.xpc"
  codesign "${flags[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  codesign "${flags[@]}" "$sparkle/Autoupdate"
  codesign "${flags[@]}" "$sparkle/Updater.app"
  codesign "${flags[@]}" "$app/Contents/Frameworks/Sparkle.framework"
fi
codesign "${flags[@]}" "$app/Contents/MacOS/mijia-rust"
codesign "${flags[@]}" "$app/Contents/MacOS/mijialan-rust"
codesign "${flags[@]}" "$app"
codesign --verify --deep --strict "$app"
