# Release packaging

The native Swift version and build number are defined once in `release.json`.
Native releases use `v<version>` tags. Rust uses a separate branch and `rs-` tags.

## GitHub Actions

- **Native macOS CI** runs Release tests, builds an ad hoc Universal ZIP, and
  launches that exact archive on both macOS 15 Apple Silicon and Intel runners.
  It runs for `main`, `codex/**`, pull requests targeting `main`, and manual dispatch.
- **Native signed release** runs for `v*` tags. It requires a matching `release.json`,
  a release note at `docs/releases/v<version>.md`, and a source commit contained in `main`.
  It tests, signs, notarizes and staples a Universal app, ZIP and DMG. Both macOS 15
  startup checks must pass before a separate job publishes the three release files.
- Manual dispatch on `main` defaults to packaging only. With `publish=true`,
  the version tag is created only after signing and both startup checks pass.
  If that tag already exists, it must point to the exact source commit being built.

The signing job uses the repository's existing `macos-release` environment, shared
with Rust. Its deployment rules must allow branch `main` and tags `v*`, in addition
to the existing Rust rules. Required environment secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 Developer ID Application certificate and private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting that PKCS#12 export |
| `APPLE_API_KEY_P8_BASE64` | Base64 App Store Connect API key authorized for notarization |

Environment variables: `MIJIALAN_SIGNING_IDENTITY` (certificate SHA-1 or identity),
`APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID`. No credentials are needed for ordinary CI.
Signing materials are imported into a temporary keychain, validated, and removed
by an `always()` cleanup step. They are outside the workspace, cache and uploaded logs.

For the next release, update `release.json`, add its notes, commit to `main`, then:

```bash
version="$(python3 scripts/release_metadata.py version)"
git tag -a "v$version" -m "MijiaLAN $version"
git push origin "v$version"
```

Actions builds with Xcode 27.1 on the `xcode-27` hosted image. Package startup is
checked with the native CPU on `macos-15` and `macos-15-intel`, exercising older
system Swift runtimes rather than relying only on a new SDK's dependency audit.
This verifies packaged launch, not control of the user's physical devices.

## Local packaging

`scripts/package_release.sh` builds a universal macOS 15+ app, signs it with
Developer ID and Hardened Runtime, notarizes and staples the app and DMG,
checks Gatekeeper acceptance, and produces a DMG, ZIP and SHA-256 checksums.
It runs Release tests before packaging and does not publish anything to GitHub.

Requirements:

- Xcode 27.1 or later, including the Icon Composer asset compiler.
- Python 3 (provided by the Xcode command line tools) for the runtime dependency audit.
- An installed Developer ID Application certificate with its private key.
- An existing `notarytool` Keychain credential profile for that certificate's team.

```bash
MIJIALAN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
MIJIALAN_NOTARY_PROFILE='your-notary-profile' \
./scripts/package_release.sh
```

Artifacts are written to `build/releases/v<version>/dist/`. Build, test,
signature, notarization and Gatekeeper logs stay in the adjacent `logs/`
directory. Only the DMG, ZIP and `SHA256SUMS.txt` are intended as release
attachments. Real device registries, pairing data and diagnostic exports are
not part of the app bundle.

Local overrides `MIJIALAN_VERSION` and `MIJIALAN_BUILD_NUMBER` are still supported.
Set `MIJIALAN_NOTARY_KEYCHAIN` when the notary profile belongs to a specific file-based
keychain, as Actions does. `MIJIALAN_DSYM_OUTPUT` optionally selects a `.dSYM` output
for direct `build_app.sh` builds; release packaging always keeps it under `symbols/`.

## Packaging optimizations and evidence

- Release executables use `strip -S -x` to remove debug and non-global symbols,
  while preserving exported symbols and runtime metadata. Matching dSYMs remain
  separate; their UUIDs must match every executable architecture before stripping.
- SwiftPM dependency downloads are cached by toolchain and resolved package graph.
  Native compilation is not reused from an incompatible compiler or operating system.
- Already compressed ZIP, DMG and symbol archives use Actions artifact compression
  level 0. DMGs retain the macOS-compatible UDZO format with zlib level 9.
- App and DMG each retain their notarization ticket. ZIPs are rebuilt after app
  stapling, so extracting the ZIP also provides an offline-verifiable app.
- Rejected or timed-out notarizations preserve submission IDs and available Apple
  details. Stapling retries briefly for ticket propagation; failed submissions are
  not silently resubmitted. Build/test logs stream during CI and upload on failure.
- `logs/release-info.json` records source commit, dirty-tree state, Xcode, sizes
  and hashes. CI stores dSYMs and release logs separately from the three public assets.

These choices follow [GitHub's temporary-keychain signing example](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Apple's notarization and stapling workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[Apple's symbol-stripping settings](https://developer.apple.com/documentation/xcode/build-settings-reference),
and [upload-artifact's compression guidance](https://github.com/actions/upload-artifact#altering-compressions-level-speed-v-size).
Available toolchains are recorded in the [official runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

If packaging stops after the staging app has been built and signed, rerun with
`--package-existing` and the same environment to retry notarization without
rebuilding. This verifies the staging app's version, build number, architectures,
Developer ID signature, Hardened Runtime and timestamp. Use it only for the
unchanged app whose Release tests already passed.

After checking the packages, commit the release scripts and documentation,
tag the matching source commit, and upload the three artifacts to a GitHub
Release. Describe hardware validation limits in the release notes; passing
automated tests and Apple notarization do not verify every device or firmware.

For a local universal build without notarization:

```bash
MIJIALAN_UNIVERSAL=1 ./scripts/build_app.sh
```

`MIJIALAN_APP_OUTPUT` can select a staging `.app` path without replacing an
installed copy. The default local build uses ad hoc signing; setting
`MIJIALAN_SIGN_IDENTITY` enables timestamped Developer ID signing instead.

The application icon is authored in `Resources/AppIcon.icon` with Icon Composer.
It preserves the Rust app's teal background and Lucide house outline. The Rust
branch carries the same document under `resources/macos/AppIcon.icon`; keep the
two copies identical when changing the icon. Both build scripts compile it into
`Assets.car` for macOS 26+ and `AppIcon.icns` for older macOS releases, then merge
the compiler's icon metadata into `Info.plist` before signing the bundle.

`scripts/swift_runtime.py embed` uses Apple's `swift-stdlib-tool` to copy required
Swift back-deployment libraries into `Contents/Frameworks`, adds the app-relative
runtime search path, removes development-toolchain search paths, and signs the
embedded libraries before the app is signed. This is required for macOS 15 even
when the same executable launches successfully on a newer development machine.
The release script also audits existing staging apps before notarization; the
audit rejects unresolved non-system dependencies, incompatible architectures,
and Mach-O deployment targets newer than the app's declared minimum.
