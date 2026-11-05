# Release packaging

The current native Swift release is **0.1.2 (build 3)**. Rust releases use a
separate branch and `rs-` tags.

`scripts/package_release.sh` builds a universal macOS 15+ app, signs it with
Developer ID and Hardened Runtime, notarizes and staples the app and DMG,
checks Gatekeeper acceptance, and produces a DMG, ZIP and SHA-256 checksums.
It runs Release tests before packaging and does not publish anything to GitHub.

Requirements:

- Xcode 26 or later, providing Swift 6.4 or later and the Icon Composer asset compiler.
- Python 3 (provided by the Xcode command line tools) for the runtime dependency audit.
- An installed Developer ID Application certificate with its private key.
- An existing `notarytool` Keychain credential profile for that certificate's team.

```bash
MIJIALAN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
MIJIALAN_NOTARY_PROFILE='your-notary-profile' \
MIJIALAN_VERSION=0.1.2 \
MIJIALAN_BUILD_NUMBER=3 \
./scripts/package_release.sh
```

Artifacts are written to `build/releases/v<version>/dist/`. Build, test,
signature, notarization and Gatekeeper logs stay in the adjacent `logs/`
directory. Only the DMG, ZIP and `SHA256SUMS.txt` are intended as release
attachments. Real device registries, pairing data and diagnostic exports are
not part of the app bundle.

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
