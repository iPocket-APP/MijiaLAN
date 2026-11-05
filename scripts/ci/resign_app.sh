#!/usr/bin/env bash
# Change only signatures on an already verified CI app, retaining its runtime libraries.
set -euo pipefail
: "${MIJIALAN_SIGN_IDENTITY:?Set the Developer ID Application signing identity}"
[[ "$MIJIALAN_SIGN_IDENTITY" != - ]] || { echo 'Distribution requires Developer ID' >&2; exit 1; }
app="${1:?Pass the verified staging app}"
codesign --verify --deep --strict "$app"
while IFS= read -r -d '' library; do
    codesign --force --sign "$MIJIALAN_SIGN_IDENTITY" --options runtime --timestamp "$library"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -type f -print0)
codesign --force --sign "$MIJIALAN_SIGN_IDENTITY" --options runtime --timestamp "$app"
codesign --verify --deep --strict "$app"
