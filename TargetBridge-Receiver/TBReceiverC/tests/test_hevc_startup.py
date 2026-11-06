#!/usr/bin/env python3
"""Optional macOS VideoToolbox + real FFmpeg decoder startup test.

Run with FFmpeg development libraries available through pkg-config, e.g.:
  PKG_CONFIG_PATH=/path/to/prefix/lib/pkgconfig python3 tests/test_hevc_startup.py
Default resolution is 4480x2520; pass width and height to test another size.
Requires hardware HEVC encoding/decoding. Uses only synthetic pixels, and does
not start Receiver, create windows, capture the display, or access the network.
"""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("This optional hardware test requires macOS/VideoToolbox")
    root = Path(__file__).resolve().parent.parent
    packages = ["libavcodec", "libavutil", "libswscale"]
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", *packages], text=True))
    with tempfile.TemporaryDirectory(prefix="tb-hevc-startup-") as directory:
        executable = Path(directory) / "test_hevc_startup"
        command = [os.environ.get("CC", "clang"), "-fobjc-arc", "-O1", "-g",
                   "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=11.0",
                   "-I", str(root / "src"), str(root / "tests/test_hevc_startup.m"),
                   str(root / "src/decoder.c"), *flags,
                   "-framework", "Foundation", "-framework", "VideoToolbox",
                   "-framework", "CoreMedia", "-framework", "CoreVideo",
                   "-o", str(executable)]
        subprocess.run(command, check=True)
        subprocess.run([str(executable), *sys.argv[1:]], check=True)


if __name__ == "__main__":
    main()
