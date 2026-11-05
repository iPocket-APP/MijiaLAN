#!/usr/bin/env bash
# Change only signatures on an already verified CI app, retaining its runtime libraries.
set -euo pipefail
: "${MIJIALAN_SIGN_IDENTITY:?Set the Developer ID Application signing identity}"
[[ "$MIJIALAN_SIGN_IDENTITY" != - ]] || { echo 'Distribution requires Developer ID' >&2; exit 1; }
app="${1:?Pass the verified staging app}"
codesign --verify --deep --strict "$app"
bash "$(dirname "$0")/../sign_app.sh" "$app" "$MIJIALAN_SIGN_IDENTITY"
