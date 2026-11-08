"""Check the actual SPK/FPK payloads and run their lifecycle as a non-root user."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request


def unpack(path, dest):
    with tarfile.open(path) as package:
        package.extractall(dest, filter="data")


def test_package(package, root, fnos):
    package_dir = root / "package"
    app_dir = root / "target"
    data_dir = root / "var"
    data_dir.mkdir(parents=True)
    unpack(package, package_dir)
    unpack(package_dir / ("app.tgz" if fnos else "package.tgz"), app_dir)
    assert json.loads((package_dir / "config/privilege" if fnos else package_dir / "conf/privilege").read_text())["defaults"]["run-as"] == "package"
    binary = app_dir / "bin/mijia-rust"
    subprocess.run([binary, "serve", "--help"], check=True, stdout=subprocess.DEVNULL)
    assert "NEEDED" not in subprocess.check_output(["readelf", "-d", binary], text=True)
    address = socket.gethostbyname(socket.gethostname())
    code = "package-fixture-only-52"
    env = dict(os.environ, wizard_lan_ip=address, wizard_setup_code=code, wizard_hap_port="51826")
    if fnos:
        env.update(TRIM_APPDEST=str(app_dir), TRIM_PKGVAR=str(data_dir))
        install = package_dir / "cmd/install_callback"
        main = package_dir / "cmd/main"
    else:
        env.update(SYNOPKG_PKGDEST=str(app_dir), SYNOPKG_PKGVAR=str(data_dir))
        install = package_dir / "scripts/postinst"
        main = package_dir / "scripts/start-stop-status"
    subprocess.run([install], env=env, check=True)
    assert (data_dir / "setup-code").stat().st_mode & 0o777 == 0o600
    subprocess.run([main, "start"], env=env, check=True)
    try:
        subprocess.run([main, "status"], env=env, check=True)
        subprocess.run([main, "start"], env=env, check=True)
        base = f"http://{address}:17890"
        browser = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with browser.open(base, timeout=3) as response:
            assert response.status == 200 and b"MijiaLAN" in response.read()
        unlock = urllib.request.Request(
            f"{base}/api/unlock", json.dumps({"code": code}).encode(),
            {"Content-Type": "application/json", "Origin": base}, method="POST",
        )
        with browser.open(unlock, timeout=3) as response:
            assert response.status == 204
        try:
            browser.open(unlock, timeout=3)
        except urllib.error.HTTPError as error:
            assert error.code == 401
        else:
            raise AssertionError("A one-time setup code was accepted twice")
        assert not (data_dir / "setup-code").exists()
        assert code not in (data_dir / "bridge.log").read_text()
        key = data_dir / "keys/master.key"
        original = hashlib.sha256(key.read_bytes()).digest()
    finally:
        subprocess.run([main, "stop"], env=env, check=True)
    assert subprocess.run([main, "status"], env=env).returncode == 3
    # Reinstall with a new payload and the same private storage.
    subprocess.run([install], env=dict(env, wizard_hap_port="51829"), check=True)
    assert (data_dir / "network.conf").read_text() == f"{address} 51826\n"
    subprocess.run([main, "start"], env=env, check=True)
    try:
        assert hashlib.sha256(key.read_bytes()).digest() == original
    finally:
        subprocess.run([main, "stop"], env=env, check=True)
    print(f"Verified packaged service lifecycle: {package.name}")


if __name__ == "__main__":
    assert os.getuid() != 0, "Use the package-user test environment"
    output = Path(sys.argv[1])
    for extension in ("spk", "fpk"):
        package, = output.glob(f"*-test.{extension}")
        with tempfile.TemporaryDirectory(prefix="mijialan-nas-test-") as temp:
            test_package(package, Path(temp), extension == "fpk")
