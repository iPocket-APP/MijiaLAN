#!/usr/bin/env bash
# Reuse the repository's macos-release environment in a temporary job keychain.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS ]] || { echo "Run in a macOS Actions job" >&2; exit 1; }
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${MACOS_CERTIFICATE_P12_BASE64:?Missing certificate secret}"
: "${MACOS_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${APPLE_API_KEY_P8_BASE64:?Missing notarization key}"
: "${MIJIALAN_SIGN_IDENTITY:?Missing signing identity}"
: "${APPLE_API_KEY_ID:?Missing notarization key ID}"
: "${APPLE_API_ISSUER_ID:?Missing notarization issuer}"
umask 077
signing_dir="$(mktemp -d "$RUNNER_TEMP/mijialan-native-signing.XXXXXX")"
keychain="$signing_dir/signing.keychain-db"
printf 'MIJIALAN_CI_SIGNING_DIR=%s\n' "$signing_dir" >> "$GITHUB_ENV"
security list-keychains -d user > "$signing_dir/original-keychains.txt"
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$signing_dir/notary.p8"
keychain_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
python3 - "$signing_dir" "$keychain" <<'PY'
import pathlib, shlex, subprocess, sys
original = shlex.split((pathlib.Path(sys.argv[1]) / 'original-keychains.txt').read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', sys.argv[2], *original], check=True)
PY
security find-identity -v -p codesigning "$keychain" | grep -F -- "$MIJIALAN_SIGN_IDENTITY" > /dev/null
xcrun notarytool store-credentials mijialan-native-ci --keychain "$keychain" \
    --key "$signing_dir/notary.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
    > "$signing_dir/notary-credentials.txt" 2>&1
printf 'MIJIALAN_NOTARY_PROFILE=mijialan-native-ci\nMIJIALAN_NOTARY_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"
rm -f "$signing_dir/certificate.p12" "$signing_dir/notary.p8" "$signing_dir/notary-credentials.txt"
unset keychain_password
echo 'Temporary signing identity and notarization profile verified'
