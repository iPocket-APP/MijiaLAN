# Apple TV version checks

The shared update site also publishes `/tvos/releases.json`. This is a version announcement feed for the self-signed TV experiment, not a Sparkle installer feed. Existing native `/appcast.xml` and Rust `/rs/*/appcast.xml` paths and signing keys are unchanged.

`scripts/tvos_updates.py` collects public GitHub releases with a `tvos-vVERSION-bBUILD` tag, a publication timestamp, and a nonempty `MijiaLAN-tvOS-VERSION-bBUILD.ipa` asset. Published prereleases are supported; drafts, native tags, Rust tags, missing packages, zero-length assets and foreign package names are excluded. TV builds must be unique, positive, globally increasing integers within `1..2147483647`.

The feed has `schemaVersion: 1`, `platform: "tvOS"`, `bundleIdentifier: "com.ipocket.MijiaLAN.TVPrototype"`, `channel: "selfSigned"`, and a `releases` array. Each release has `version`, `build`, `tag`, plain-text `notes`, `publishedAt` and a canonical repository `releaseURL`. Releases are ordered by descending numeric build, keeping at most 20 with 6,000 characters of notes each, within the client's 1 MiB response limit. With no TV package published, the array is empty; native versions are never substituted.

The client requests this HTTPS endpoint, validates platform / bundle / channel / release URL, compares numeric build numbers and displays release notes and a QR code. It does not download or install the IPA. The QR code opens the public release page on another device. Self-signed installation still requires the paired Mac, valid signing and matching app / extension identities. App Store and TestFlight distribution would need their own channel eligibility and installation links; this feed does not claim those channels are live.

## Deployment

This branch extends the shared-site work from `codex/rust-update-feeds`. All three publishers already rebuild the complete shared site through `scripts/update_site.py`; the new collector runs inside that assembly before any site files are staged. Native and Rust releases therefore retain the TV feed, including an empty initial feed. The post-deployment check now verifies TV JSON as well as all appcasts.

Deploy through the existing `Refresh shared update feeds` workflow on main after merging these changes. This deploys version information and does not publish a TV installer. While the path returns HTTP 404, the TV client can read the same tag / asset rules from the public GitHub releases API; other server errors remain visible instead of becoming a successful empty result. This fallback currently scans the latest 100 releases.

## Validation

```sh
python3 -m unittest discover -s scripts/tests -p 'test_tvos_updates.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_update_site.py' -v
```

Five TV collector tests cover flavor isolation, numeric ordering, draft / package filtering, duplicate builds, the empty initial feed and response-size limits. The eight shared-site tests include retaining native + all three Rust appcasts alongside the TV feed. No public release or private signing key is needed for these tests.

The TV app is in the separate `codex/tvos-network-extension-prototype` worktree under `Experiments/AppleTV`. A local feed produced by this collector was served on loopback and fetched by the tvOS Simulator app, which detected the newer build and displayed a release QR code. Local fixture metadata is not published.
