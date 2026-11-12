# Privacy and publication review

[简体中文](PRIVACY.md) · **English**

## Data flows and storage

| Activity | Connection or storage | Data involved |
| --- | --- | --- |
| Xiaomi Home device import | Xiaomi account and Xiaomi Home cloud services | Login session, device registry, tokens, IPs, names and rooms |
| Device specifications | `miot-spec.org` and a local cache | Models and public specifications; no Xiaomi credentials required |
| Daily device control | Local UDP 54321 | miIO / MIoT commands and readings |
| Apple Home bridge | LAN HAP and Bonjour / mDNS | Bridge identity, selected device names, services, readings and controls |
| Credential persistence | Local macOS Keychain | Device registry and tokens, bridge identity, setup code and pairing keys, and the Xiaomi Home login session and server region if remembered |
| Preferences | Local UserDefaults | Appearance, HomeKit inclusion choices and related identifiers |
| Software updates | GitHub Pages at `mijialan-updates.ipocket.xyz`, GitHub Releases and its download CDN | Update feed, release notes and packages; hosting services receive the IP address and ordinary HTTP request information |

The app has no project operated backend, advertising or analytics SDK. After a successful QR import, the session is saved to this Mac's Keychain only if you choose Remember Xiaomi Home Login. The app uses the saved session when you choose to re-import devices. Use Forget Login in Settings to delete it. HTTP uses ephemeral URLSession with automatic cookie storage disabled.

Sparkle checks for updates once per day by default. You can disable automatic checks or check manually in Settings. Automatic downloads and installation on quit are off by default. Updates do not upload device registries, tokens or HomeKit pairing material; Sparkle system profile reporting is disabled. The ephemeral URLSession description above applies to device import and specification requests; Sparkle uses its own download mechanism.

The Keychain item uses `AfterFirstUnlockThisDeviceOnly`. Device names, IPs and tokens are stored with bridge pairing material in one item. Denying Keychain access does not replace existing credentials with an empty registry. Device names, rooms and activity readings can also be private data.

## Logs and exports

- Device IDs and control values are marked private in the app's unified logs.
- The HAP handler defaults to info and marks dynamic messages private. Debug messages and accessory database dumps are no longer all promoted to persistent notice messages.
- Vendored pairing logs no longer include raw session key prefixes.
- CLI discovery hides tokens unless `--show-tokens` is explicitly supplied. Some old firmware can return tokens during discovery.
- Other CLI commands still accept token arguments, which may enter shell history or process arguments. Prefer the app for routine credential import.
- `MIJIALAN_DIAGNOSTICS_OUTPUT` uses a field allowlist and omits device tokens, bridge private keys and setup codes. It still contains names, IDs, readings, errors and timestamps, so **it is not an anonymous report**.
- Screenshots, especially import and HomeKit settings, may contain QR codes, setup codes, IPs, device names and rooms. Only the Debug `MIJIALAN_UI_PREVIEW=1` mode provides a fully simulated environment; `MIJIALAN_EPHEMERAL=1` alone does not disable network access.

Review logs and screenshots before sharing. Updating the code does not remove logs already produced by older versions.

## Publication review, 2026-11-02

The review covers source, resources, documentation, dependency pins, Git commit contents and author/committer metadata prepared for publication. It does not involve exporting macOS Keychain data or reading cloud account records.

Changes made for publication:

- Attribute all published commits to `iPocket-APP` using its GitHub noreply address.
- Replace preview IPs with the RFC 5737 documentation range `192.0.2.0/24`, retaining synthetic tokens, device names and rooms.
- Exclude local builds, apps, diagnostic exports, screenshots, internal acceptance records and development QA notes; add credential and signing file ignore rules.
- Apply the logging and CLI output changes described above.
- Preserve third party licenses and modification notices. The project's MIT license does not replace those licenses.

Gitleaks 8.30.1 is used alongside manual checks for tokens, private keys, account sessions, email addresses, local paths, network addresses and hardcoded identifiers. Two sequential hexadecimal test tokens are public protocol fixtures. Another false positive is a Swift private key type declaration with no key value. `.gitleaks.toml` exempts only those exact values in named test files and that exact declaration in its specific source file, rather than excluding test or dependency directories.

The publication snapshot and reachable commit history have no unexplained credential findings. Manual review found no real device tokens, login credentials or private keys. Negative controls with different synthetic tokens verified that the exceptions do not skip arbitrary credentials in those files.

To repeat the scans with Gitleaks 8.30.1 or a compatible version:

```bash
gitleaks git . --redact
gitleaks dir . --redact
```

Directory scans also see ignored local files; publication checks should use a snapshot exported with `git archive`. Static scanning and manual review cannot guarantee the absence of unknown issues. Report sensitive findings privately to the maintainer rather than pasting credentials or real device registries into public issues.
