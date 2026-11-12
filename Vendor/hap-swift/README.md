# hap-swift (vendored)

[acumen-dev/hap-swift](https://github.com/acumen-dev/hap-swift) at `638001bd3590082a8909fd4046ec226ab1349f20`, Apache 2.0 (`LICENSE.md`). Sources and manifest only; the upstream test targets are left out.

## Local changes

An encrypted HAP frame carries at most 1024 plaintext bytes (HAP spec §6.5.2). Upstream ignored that limit in both directions, which only shows once a bridge holds more than one small accessory:

- **Sending:** `HAPSession.encrypt` put a whole response into one frame. The `GET /accessories` answer of a bridge runs to several kilobytes; iOS drops the connection on the oversized frame and the Home app reports "Unable to Add Accessory". It now splits plaintext into frames of at most 1024 bytes.
- **Receiving:** `HAPConnectionContext` in `AppleTCPServer.swift` parsed each decrypted frame as a complete HTTP request and dropped a request spread over several frames without replying, such as iOS subscribing to every characteristic of a big bridge at once. It now keeps decrypted bytes until a whole request has arrived (`HTTPProtocol.requestLength(in:)`), then handles every complete request in them.

A third change is about Bonjour: upstream refreshed the TXT record after `POST /pairings` but not after pair-setup, so a freshly paired bridge kept advertising `sf=1` (unpaired). iOS looks the accessory up again to finish adding it and takes `sf=1` for a reset accessory. `CharacteristicProtocol.handlePairSetup` now re-advertises once pair-setup has stored the first controller.

`HAPLinux` keeps the upstream receive path; MijiaLAN only builds for macOS.

`HAPBridge.addAccessory` also accepts `appendingCharacteristicTypes`: these characteristics receive IIDs after
all existing services and characteristics. MijiaLAN uses this when adding Configured Name (`E3`) to an already
paired air conditioner's mode switches, preserving their service/On/Name IIDs and existing Home configuration.

`PairVerifyStateMachine` exposes the verified controller identifier after authentication. The Apple transport
passes it to characteristic handling so pairing administration can enforce controller permissions.

`PairingStateMachine` no longer includes session key prefixes in any log message. These were raw key bytes,
despite the upstream log text calling them a hash. MijiaLAN's app log handler also disables debug/trace dumps
by default and marks dynamic HAP log content private.

`CharacteristicProtocol` checks the debug log level before converting accessory/read response bodies to strings,
avoiding that extra allocation in normal operation. Diagnostic messages include connection IDs; the Apple
transport also records connection endpoints, response/event submission and socket completion. PUT diagnostics
include request values, per-characteristic write errors and 207 response statuses; peer closure has a separate
marker from receive/decryption failures. These are disabled
by the app's default info log level. Its explicit `MIJIALAN_HAP_DIAGNOSTICS=1` launch option copies only selected
transport/characteristic/event categories to local stderr; pairing payloads, key material and trace are excluded.
An absolute `MIJIALAN_HAP_DIAGNOSTICS_FILE` path instead enables a private rotating local capture: two files of
at most 4 MiB each, a bounded 128 KiB pending queue and a serial utility worker. This lets an intermittent
failure retain its preceding requests without unbounded disk growth or synchronous file I/O in HAP handlers.
`MIJIALAN_TRACE_FILE` enables the same rotating capture with miIO calls and their elapsed times included.
Device-info responses are omitted and the device token is redacted from miIO messages.

Modified Swift files carry an explicit modification notice. `Package.swift` omits upstream test targets because
only sources are vendored; MijiaLAN maintains its own bridge and protocol regression tests.

### Value constraints and real-network regressions (2026-11-04)

`HAPValueConstraints` applies the same format, finite-value, intrinsic type bounds, declared range,
step and allowed-value rules used by the Rust implementation. Reads round to the advertised step
and numeric representation; writes must already satisfy them before a device handler runs.
`HAPBridge` applies these rules to initial accessory values and updates, retaining the last confirmed
cache entry while marking invalid reads unavailable. Recovery restores success and notifies subscribers.
`HAPString` bounds generated metadata to 64 UTF-8 bytes at Unicode scalar boundaries, without changing
the original device registry or saved names. Oversized incoming strings are rejected.

Read-status failures generate `-70402` events without a cached value. New subscribers receive an initial
value or status, and `CharacteristicProtocol` rejects subscriptions to characteristics without `ev`.

The Apple listener and service accept an optional `loopbackOnly` mode used by isolated network tests;
it binds to 127.0.0.1 and suppresses Bonjour publication. The normal listener defaults are unchanged.
Root-package regressions compare 73 read/write vectors generated by Rust, and exercise real miIO UDP,
Pair Setup / Pair Verify over TCP, CryptoKit-authenticated HAP frames, UTF-8 names, invalid reads and
events, recovery, revoked-session rejection, and re-pairing with the same bridge identity and PIN.

### Multi-status reads (2026-11-05)

`CharacteristicProtocol.handleGetCharacteristics` answered a partly failed read with 207 but left
`status` out of the successful entries. HAP §6.7.4.4 requires a status on every entry of a 207, and
iOS treats a missing one as a failure: Apple Home reads every accessory of a bridge in one request,
so a single unreachable device made the reachable ones show No Response while writes still worked.
Successful entries of a 207 now carry `"status": 0` with their value; a fully successful read is
still a plain 200 without status fields.

### Connection ordering (2026-11-05)

`HAPSession.encryptAndSend` allocates frame counters and submits the resulting
bytes to TCP in the same actor-isolated operation. Previously response and event
tasks could submit encrypted frames in a different order from their nonces,
causing intermittent authentication failures. The Apple receive loop also waits
for processing before scheduling its next read, preserving byte order across
actor suspensions. Regressions cover 128 concurrent encrypted writers and eight
independent real UDP/TCP pairing, subscription and re-pairing sessions.

Characteristic event delivery also uses a FIFO task chain, including the initial
subscription snapshot. Cache mutation order alone does not preserve delivery order
when an asynchronous send suspends. A delayed unavailable event could previously
arrive after a same-value recovery event and leave Home displaying an old error.
Regression cases cover both existing subscribers and subscribing while unavailable.

### Response priority and failed sessions (2026-11-08)

`HAPConnectionContext` now queues events while receiving or handling an HTTP request, and drains them in FIFO
order only after submitting its complete response. Encrypting frames in counter order alone did not enforce
this: initial subscription events and notifications from an awaited write handler could reach the controller
before the HTTP acknowledgement. The gate also spans incomplete encrypted frames and fragmented HTTP requests;
idle notifications still send immediately. This follows the response/event separation used by
[HAP-NodeJS](https://github.com/homebridge/HAP-NodeJS/blob/latest/src/lib/util/eventedhttp.ts).

An authentication/decryption failure now closes that TCP connection and removes its subscriptions. Previously
processing stopped but the connection stayed open with the same failing frame at its head, so the controller
could keep waiting on a session that could never recover. Invalid complete requests, over-limit incomplete
requests and response-encryption failures also close the unusable connection. Pairing storage is unchanged.

Real UDP/TCP regressions cover the `yeelink.light.lamp4` legacy `get_prop` path, power-off/brightness/colour
temperature reads, initial subscriptions, partial read failures and same-value recovery, and a suspended write
handler. The controller fixture now records events that arrive before a response rather than silently hiding
that ordering. A corrupt-frame regression distinguishes prompt peer closure from the client's own watchdog.

### Write-origin events (2026-11-08)

Characteristic PUTs now carry their originating connection through the awaited write handler. Ordinary
confirmed values matching that write are sent to other subscribers but not echoed back to the writer,
following the origin exclusion in [Apple HomeKit ADK](https://github.com/apple/HomeKitADK/blob/master/HAP/HAPIPAccessoryServer.c)
and [HAP-NodeJS](https://github.com/homebridge/HAP-NodeJS/blob/latest/src/lib/util/eventedhttp.ts).
Linked characteristic changes, errors, recovery and explicit corrective notifications still reach it.
The context is task-local, scoped to a bridge and characteristic, and expires when the write returns.
The bridge tracks which value was last queued for the writing connection. A correction or error can
therefore be followed by another event returning to the original value. Regressions cover two controllers,
linked updates, physical changes, failures, resets and context lifetime.

### Power and level writes (2026-11-08)

Within a characteristic PUT, power-on writes run before level writes and power-off writes run afterward.
The status response follows the original order. Standalone nonzero brightness writes use the same device
queue operation as the app dimmer, which turns on an off lamp before setting its level. Confirming reads are
published after pending Home writes complete, keeping a lamp's intermediate fade levels out of Home.

### Primary service (2026-11-05)

`HAPService.isPrimary` is published as the service's `"primary": true` in `GET /accessories`, and
`HAPBridge.addAccessory` keeps it when it renumbers services. MijiaLAN marks each device's main service,
such as Fan v2, so Home builds the accessory tile around it instead of one of its named switches.
A changed flag is part of MijiaLAN's database signature, so Home is told to reload the accessory.

### State number (2026-11-12)

The Bonjour `s#` was always `1`. In a home without a hub, an iPhone that had left kept showing a bridged lamp as
off for 45 minutes after it was switched on elsewhere, and opening Home did not reconnect to the bridge. The lamp's
own HomeKit tile was right; that accessory advertised `s#=39`. `HAPBridge` now keeps a state number that moves once
after a controller disconnects, on the next change of a writable, notifying characteristic or of its read status.
Sensor readings do not move it, so a changing temperature cannot re-announce the bridge each time a controller comes
and goes. `HAPAdvertiser.updateStateNumber` replaces the TXT record in place through the new
`ServiceDiscovery.updateTXT` (`DNSServiceUpdateRecord` in vendored mdns-swift), and advertises the whole record
where that is not possible. MijiaLAN persists the number in its bridge layout.
