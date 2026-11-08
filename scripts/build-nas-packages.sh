#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || { echo 'Use the x86_64 NAS build environment.' >&2; exit 1; }
build="${MIJIALAN_LINUX_BUILD:?Set the Rust release build number}"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || exit 1
out="${MIJIALAN_ARTIFACT_DIR:-$PWD/artifacts}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="$(python3 -c 'import tomllib; print(tomllib.load(open("Cargo.toml","rb"))["workspace"]["package"]["version"])')"
name="MijiaLAN-rs-$version-b$build"
target=x86_64-unknown-linux-musl
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cargo build --locked --release -p mijialan-cli --no-default-features --target "$target"
binary="${CARGO_TARGET_DIR:-target}/$target/release/mijia-rust"
if readelf -l "$binary" | grep -q INTERP || readelf -d "$binary" | grep -q NEEDED; then
    echo "NAS bridge must be statically linked" >&2
    exit 1
fi
test "$("$binary" --version)" = "mijia-rust $version"

# Pin the official packer, and keep it in the build workspace.
fnpack="$scratch/fnpack"
curl -fsSL --retry 2 --max-time 60 https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64 -o "$fnpack"
printf '%s  %s\n' 54b97fa7b70968c4d05c79840f5daeff508957d0bb2062fdb0376d00d9615c93 "$fnpack" | sha256sum -c
chmod 0755 "$fnpack"

payload="$scratch/payload"
mkdir -p "$payload/bin"
install -m 0755 "$binary" "$payload/bin/mijia-rust"
install -m 0755 packaging/nas/service.sh "$payload/bin/service"
cp LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md "$payload/"
cp -R licenses "$payload/licenses"
cargo metadata --locked --format-version 1 --filter-platform "$target" > "$scratch/cargo.json"
python3 scripts/collect-cargo-licenses.py "$scratch/cargo.json" "$payload/licenses/cargo"

icon=crates/desktop/resources/windows/app-icon.svg
rsvg-convert -w 256 -h 256 "$icon" -o "$scratch/icon256.png"
rsvg-convert -w 64 -h 64 "$icon" -o "$scratch/icon64.png"
privilege='{"defaults":{"run-as":"package"}}'

spk="$scratch/spk"
mkdir -p "$spk"/{scripts,conf,WIZARD_UIFILES}
tar -C "$payload" -czf "$spk/package.tgz" .
checksum="$(md5sum "$spk/package.tgz" | cut -d ' ' -f1)"
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build/" -e "s/@CHECKSUM@/$checksum/" packaging/nas/synology/INFO > "$spk/INFO"
printf '%s\n' "$privilege" > "$spk/conf/privilege"
cp "$scratch/icon64.png" "$spk/PACKAGE_ICON.PNG"
cp "$scratch/icon256.png" "$spk/PACKAGE_ICON_256.PNG"
cp packaging/nas/synology/install_uifile "$spk/WIZARD_UIFILES/install_uifile"
cat > "$spk/scripts/start-stop-status" <<'DSM'
#!/bin/sh
export NAS_DEST="${SYNOPKG_PKGDEST:?}" NAS_VAR="${SYNOPKG_PKGVAR:?}"
case "${1:-}" in
    prestart|prestop|log) exit 0 ;;
esac
exec "$NAS_DEST/bin/service" "$@"
DSM
cat > "$spk/scripts/postinst" <<'DSM'
#!/bin/sh
export NAS_DEST="${SYNOPKG_PKGDEST:?}" NAS_VAR="${SYNOPKG_PKGVAR:?}"
exec "$NAS_DEST/bin/service" install
DSM
for script in preinst preuninst postuninst preupgrade postupgrade; do
    printf '#!/bin/sh\nexit 0\n' > "$spk/scripts/$script"
done
chmod 0755 "$spk/scripts/"*
tar --owner=0 --group=0 -C "$spk" -cf "$out/$name-synology-geminilake-test.spk" \
    INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG

(cd "$scratch" && "$fnpack" create mijialan)
fpk="$scratch/mijialan"
mkdir -p "$fpk/app/ui/images" "$fpk/wizard"
find "$fpk" -type f -name .DS_Store -delete
cp -R "$payload/." "$fpk/app/"
sed "s/@VERSION@/$version/" packaging/nas/fnos/manifest > "$fpk/manifest"
printf '%s\n' "$privilege" > "$fpk/config/privilege"
printf '{}\n' > "$fpk/config/resource"
cp "$scratch/icon64.png" "$fpk/ICON.PNG"
cp "$scratch/icon256.png" "$fpk/ICON_256.PNG"
cp "$scratch/icon64.png" "$fpk/app/ui/images/icon_64.png"
cp "$scratch/icon256.png" "$fpk/app/ui/images/icon_256.png"
cp packaging/nas/fnos/ui.json "$fpk/app/ui/config"
cp packaging/nas/fnos/install "$fpk/wizard/install"
cp packaging/nas/fnos/install "$fpk/wizard/config"
for entry in main install_callback config_callback; do
    case "$entry" in
        main) argument='"$@"' ;;
        install_callback) argument=install ;;
        config_callback) argument=configure ;;
    esac
    cat > "$fpk/cmd/$entry" <<FNOS
#!/bin/sh
export NAS_DEST="\${TRIM_APPDEST:?}" NAS_VAR="\${TRIM_PKGVAR:?}"
exec "\$NAS_DEST/bin/service" $argument
FNOS
done
chmod 0755 "$fpk/cmd/"*
(cd "$fpk" && "$fnpack" build)
cp "$fpk/mijialan.fpk" "$out/$name-fnos-x86_64-test.fpk"
(cd "$out" && sha256sum "$name-synology-geminilake-test.spk" "$name-fnos-x86_64-test.fpk" > NAS-SHA256SUMS.txt)
