"""Verify the installed Debian package draws a real frame using software Vulkan."""
import os
import re
import struct
import subprocess
import tempfile
import time
from contextlib import ExitStack


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def has_rendered(env):
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], env=env, text=True)
    window = re.search(r'\b(0x[0-9a-f]+) "MijiaLAN Rust"', tree)
    if not window:
        return False
    capture = subprocess.run(
        ["xwd", "-silent", "-id", window[1]], env=env, capture_output=True
    )
    if capture.returncode != 0:
        return False  # The window may exist before it is mapped.
    header = struct.unpack_from(">25I", capture.stdout)
    width, height = header[4:6]
    byte_order = "little" if header[7] == 0 else "big"
    bits_per_pixel, stride = header[11:13]
    if bits_per_pixel != 32:
        return False
    rgb_mask = header[14] | header[15] | header[16]
    offset = header[0] + 12 * header[19]  # Header and XWD color table.
    colors = set()
    for y in range(24, height - 24, 8):
        for x in range(24, width - 24, 8):
            start = offset + y * stride + x * 4
            pixel = int.from_bytes(capture.stdout[start : start + 4], byte_order)
            colors.add(pixel & rgb_mask)
            if len(colors) >= 8:
                return True
    return False


with tempfile.TemporaryDirectory() as runtime, ExitStack() as stack:
    env = dict(os.environ, DISPLAY=":98", XDG_RUNTIME_DIR=runtime, XDG_CONFIG_HOME=runtime)
    env.pop("WAYLAND_DISPLAY", None)
    env["VK_ICD_FILENAMES"] = "/usr/share/vulkan/icd.d/lvp_icd.x86_64.json"
    env["LP_NUM_THREADS"] = "4"
    server = subprocess.Popen(
        ["Xtigervnc", ":98", "-geometry", "1280x900", "-depth", "24",
         "-localhost", "-nolisten", "tcp", "-SecurityTypes", "None"],
        env=env,
    )
    stack.callback(stop, server)
    for _ in range(40):
        if subprocess.run(
            ["xdpyinfo"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode == 0:
            break
        time.sleep(0.25)
    else:
        raise SystemExit("Could not start the Debian X11 test display.")

    wm = subprocess.Popen(["openbox"], env=env)
    stack.callback(stop, wm)
    app = subprocess.Popen(["mijialan-rust", "--demo"], env=env)
    stack.callback(stop, app)
    for _ in range(80):
        if app.poll() is not None:
            raise SystemExit(f"MijiaLAN exited before rendering (code {app.returncode}).")
        if has_rendered(env):
            print("Debian X11 rendered the installed MijiaLAN desktop.")
            break
        time.sleep(0.25)
    else:
        raise SystemExit("MijiaLAN's X11 window did not draw visible content.")
