# MijiaCore reference provenance

The Rust protocol implementation was independently ported from MijiaLAN's pinned
MenuBarMijia / MijiaCore reference, version 1.1.4, commit
`c6a9db1c84fa30125ed4b642b6745487dec94e89`.

The original `jryang1997/MenuBarMijia` repository is no longer available. Native
MijiaLAN preserves that exact snapshot, without behavioral changes, in its
[vendored reference](https://github.com/iPocket-APP/MijiaLAN/tree/4615651aa4f925bd170654d4dcc6744d787b967c/Vendor/MenuBarMijia).

The `LICENSE` in this folder matches the preserved snapshot's MIT license. Rust
does not fetch, compile or bundle the Swift source; its Cargo dependencies and
protocol/schema fixtures are maintained separately. Rebuilding Rust therefore
does not depend on availability of the deleted upstream repository.
