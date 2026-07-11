#!/usr/bin/env python3
"""Mock TargetBridge sender — drives a receiver over plain TCP with no
Thunderbolt hardware, no Apple Silicon, and no screen capture.

Speaks the wire protocol from src/proto.h:
    [4 bytes BE uint32 length][1 byte type][payload (length-1 bytes)]

Modes (--mode):
    handshake   connect, HELLO, heartbeat for --duration, TEARDOWN, close.
    stream      handshake + generate H.264 with the ffmpeg CLI (testsrc2)
                and stream it as PARAM_SETS + AVCC FRAMEs at ~30 fps.
    hang        connect, HELLO, then go silent (no heartbeats) while keeping
                the socket open — exercises the receiver's idle watchdog,
                which should reap the session after ~10s.
    badlen      connect, HELLO, then send a corrupt 0xFFFFFFFF length prefix —
                the receiver's parser must reject it and disconnect.
    drop        connect, HELLO, send half a packet, then close abruptly —
                the receiver must return to "waiting for sender".

Stdlib only. Example:
    python3 tests/mock_sender.py --mode handshake --duration 3
"""

import argparse
import json
import socket
import struct
import subprocess
import sys
import tempfile
import time

# Packet types (src/proto.h)
PKT_HELLO_RECEIVER = 0x10
PKT_PARAM_SETS = 0x20
PKT_FRAME = 0x21
PKT_HEARTBEAT = 0x30
PKT_TEARDOWN = 0x31


def packet(ptype: int, payload: bytes) -> bytes:
    return struct.pack(">I", 1 + len(payload)) + bytes([ptype]) + payload


def json_packet(ptype: int, obj) -> bytes:
    return packet(ptype, json.dumps(obj).encode("utf-8"))


def hello_packet(name: str) -> bytes:
    return json_packet(PKT_HELLO_RECEIVER, {
        "senderName": name,
        "uiLanguage": "en",
        "capturePreset": "standard1440p",
        "captureSource": "desktopMirror",
        "captureWidth": 1280,
        "captureHeight": 720,
        "codec": "h264",
    })


def drain_receiver(sock: socket.socket, quiet: bool = False) -> None:
    """Read whatever the receiver sent (DISPLAY_PROFILE etc.) so its writes
    don't back up; log packet types for debugging."""
    sock.setblocking(False)
    try:
        data = sock.recv(65536)
        while data:
            if len(data) >= 5:
                (length,) = struct.unpack(">I", data[:4])
                if not quiet:
                    print(f"[mock] receiver sent type=0x{data[4]:02x} len={length}")
                data = data[4 + length:]
            else:
                break
    except (BlockingIOError, socket.error):
        pass
    finally:
        sock.setblocking(True)


# ---- H.264 generation & AVCC conversion (stream mode) ----------------------

def generate_h264(duration_s: int, fps: int = 30) -> bytes:
    """Render a test pattern to Annex-B H.264 using the ffmpeg CLI."""
    with tempfile.NamedTemporaryFile(suffix=".h264", delete=False) as tmp:
        path = tmp.name
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate={fps}:duration={duration_s}",
        "-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-g", str(fps), "-f", "h264", path,
    ]
    subprocess.run(cmd, check=True)
    with open(path, "rb") as f:
        return f.read()


def split_annexb(data: bytes):
    """Split an Annex-B stream into raw NAL units (start codes removed)."""
    nals, i, n = [], 0, len(data)
    while i < n:
        if data[i:i + 4] == b"\x00\x00\x00\x01":
            start = i + 4
        elif data[i:i + 3] == b"\x00\x00\x01":
            start = i + 3
        else:
            i += 1
            continue
        j = start
        while j < n:
            if data[j:j + 4] == b"\x00\x00\x00\x01" or data[j:j + 3] == b"\x00\x00\x01":
                break
            j += 1
        nals.append(data[start:j])
        i = j
    return nals


def stream_video(sock: socket.socket, duration_s: int) -> None:
    fps = 30
    nals = split_annexb(generate_h264(duration_s, fps))

    sps = next(n for n in nals if n and (n[0] & 0x1F) == 7)
    pps = next(n for n in nals if n and (n[0] & 0x1F) == 8)

    # PARAM_SETS payload: [1B codec (1=H264)][1B count] then [4B BE size][bytes] per set.
    params = bytes([1, 2])
    for ps in (sps, pps):
        params += struct.pack(">I", len(ps)) + ps
    sock.sendall(packet(PKT_PARAM_SETS, params))
    print(f"[mock] sent param sets (SPS {len(sps)}B, PPS {len(pps)}B)")

    # Group slices into frames: a frame is one slice NAL (types 1/5) here
    # (baseline testsrc2 output, one slice per picture).
    frame_interval = 1.0 / fps
    heartbeat_due = time.monotonic()
    seq = 0
    frames_sent = 0
    for nal in nals:
        ntype = nal[0] & 0x1F if nal else 0
        if ntype not in (1, 5):
            continue
        # FRAME payload: AVCC — 4-byte BE length-prefixed NAL units.
        sock.sendall(packet(PKT_FRAME, struct.pack(">I", len(nal)) + nal))
        frames_sent += 1
        now = time.monotonic()
        if now >= heartbeat_due:
            sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": seq}))
            seq += 1
            heartbeat_due = now + 2.0
        drain_receiver(sock, quiet=True)
        time.sleep(frame_interval)
    print(f"[mock] streamed {frames_sent} frames")


# ---- modes ------------------------------------------------------------------

def run(args) -> int:
    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"[mock] connected to {args.host}:{args.port}")
    time.sleep(0.2)
    drain_receiver(sock)

    sock.sendall(hello_packet(args.name))
    print("[mock] sent HELLO")

    try:
        if args.mode == "handshake":
            deadline = time.monotonic() + args.duration
            seq = 0
            while time.monotonic() < deadline:
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": seq}))
                seq += 1
                drain_receiver(sock)
                time.sleep(2.0)
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))
            print("[mock] sent TEARDOWN")

        elif args.mode == "stream":
            stream_video(sock, args.duration)
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock stream done"}))

        elif args.mode == "hang":
            print(f"[mock] going silent for {args.duration}s (socket stays open, no heartbeats)")
            time.sleep(args.duration)
            # If the receiver's idle watchdog works, it already closed us.
            try:
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": 0}))
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": 1}))
                print("[mock] receiver still accepted writes after silence")
            except (BrokenPipeError, ConnectionResetError):
                print("[mock] receiver closed the stale session (watchdog OK)")

        elif args.mode == "badlen":
            sock.sendall(struct.pack(">I", 0xFFFFFFFF) + b"\x21")
            print("[mock] sent corrupt 0xFFFFFFFF length prefix")
            sock.settimeout(5)
            try:
                data = sock.recv(4096)
                while data:
                    data = sock.recv(4096)
                print("[mock] receiver disconnected us (parser rejected corrupt length)")
            except socket.timeout:
                print("[mock] ERROR: receiver did not disconnect within 5s")
                return 1

        elif args.mode == "drop":
            # Announce a 1000-byte packet but send only half, then vanish.
            sock.sendall(struct.pack(">I", 1001) + b"\x21" + b"\x00" * 500)
            print("[mock] sent partial frame; closing abruptly")

    finally:
        sock.close()
    print("[mock] done")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=54321)
    ap.add_argument("--mode", choices=["handshake", "stream", "hang", "badlen", "drop"], default="handshake")
    ap.add_argument("--duration", type=int, default=5, help="seconds (mode-specific)")
    ap.add_argument("--name", default="MockSender")
    return run(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
