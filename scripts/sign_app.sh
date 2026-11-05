#!/usr/bin/env bash
# Sign nested Sparkle helpers before their framework and the containing app.
set -euo pipefail
APP="${1:?Pass an app bundle}"
IDENTITY="${2:--}"
FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == - ]]; then
    FLAGS+=(--timestamp=none)
else
    FLAGS+=(--options runtime --timestamp)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE" ]]; then
    codesign "${FLAGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
    codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
    codesign "${FLAGS[@]}" "$SPARKLE/Autoupdate"
    codesign "${FLAGS[@]}" "$SPARKLE/Updater.app"
    codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
while IFS= read -r -d '' library; do
    codesign "${FLAGS[@]}" "$library"
done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -type f -print0)
codesign "${FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
