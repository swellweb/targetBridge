# TargetBridge

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/swellweb)

Use an Intel iMac as an external display for an Apple Silicon MacBook — free, no dongle, via Thunderbolt Bridge.

If TargetBridge is useful to you, a ⭐ on GitHub helps others find it.

Apple removed Target Display Mode on Apple Silicon. TargetBridge brings it back via software, streaming your MacBook screen to the iMac at up to 5K over a direct Thunderbolt cable.

## Screenshots

**Sender (MacBook Apple Silicon) — waiting for connection:**
![TargetBridge Sender](screenshots/sender-idle.png)

**Sender — active stream (5K, HEVC):**
![TargetBridge Sender active](screenshots/sender-active.png)

**Receiver (Intel iMac) — waiting for sender:**
![TargetBridge Receiver](screenshots/receiver.png)

**iMac connected at native resolution via Thunderbolt:**
![TargetBridge native resolution](screenshots/resolution_linked_thunderbolt.png)

## Download

**[→ Download latest release (pre-built apps, no Xcode needed)](https://github.com/swellweb/targetBridge/releases/latest)**

- `TargetBridge.app.zip` — Sender for MacBook Apple Silicon
- `TargetBridge-Receiver.app.zip` — Receiver for Intel iMac (**requires macOS 14 Sonoma**)

Unzip and double-click. On first launch, grant Screen Recording to the sender.

> **iMac on Ventura or older?** The pre-built receiver requires macOS 14. Build it directly on your iMac instead — takes ~2 minutes, see the [Quick Start guide](TargetBridge-QuickStart-EN.md).

> **Pre-built receiver crashing?** Make sure you downloaded v1.1.0 or later — older builds required Homebrew. If you have an older build, re-download from the [latest release](https://github.com/swellweb/targetBridge/releases/latest).

## Requirements

- MacBook Apple Silicon (M1 or later) — sender
- Intel iMac 2017 or later — receiver
- Thunderbolt 3/4 cable

## Stream profiles

- `Standard · 2560 × 1440` — low latency, high stability
- `5K · 5120 × 2880` — sharper image, HEVC, slightly more load

## Projects

- `TargetBridge-Sender`
- `TargetBridge-Receiver`

## Quick start

- Italian: `TargetBridge-QuickStart-IT.md`
- English: `TargetBridge-QuickStart-EN.md`
