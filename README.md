![TargetBridge Overview](images/connection-diagram.svg)

# TargetBridge

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/swellweb)

Use an Intel iMac as an external display for an Apple Silicon Mac — free, no dongle, via Thunderbolt Bridge.

If TargetBridge is useful to you, a ⭐ on GitHub helps others find it.

Apple dropped Target Display Mode in 2014 with the 5K iMac — and it never came back. TargetBridge brings it back via software, streaming your screen to the iMac at up to 5K over a direct Thunderbolt cable.

## Branch status

The latest stable public release is still **v1.3.0**.

This branch, `feature/multi-imac-direct`, contains additional in-progress work that is not part of the latest release yet:

- direct multi-iMac sender support with multiple simultaneous sessions
- automatic receiver discovery via Bonjour
- remembered extended-display arrangement for the same receiver
- repo-local build outputs under `build/`
- receiver build target lowered to **macOS 11+** for Intel testing

If you just want the stable public version, use the latest release. If you want to test the upcoming direct multi-iMac work, build from this branch.

## Screenshots

**Sender (Apple Silicon Mac) — waiting for connection:**
![TargetBridge Sender](images/sender-idle.png)

**Sender — active stream (5K, HEVC):**
![TargetBridge Sender active](images/sender-active.png)

**Receiver (Intel iMac) — waiting for sender:**
![TargetBridge Receiver](images/receiver.png)

**iMac connected at native resolution via Thunderbolt:**
![TargetBridge native resolution](images/resolution_linked_thunderbolt.png)

## Download

**[→ Download latest release (pre-built apps, no Xcode needed)](https://github.com/swellweb/targetBridge/releases/latest)**

- `TargetBridge.app.zip` — Sender (Apple Silicon Mac, **requires macOS 14 Sonoma or later**)
- `TargetBridge-Receiver.app.zip` — Receiver (Intel iMac, **requires macOS 11 Big Sur or later**)

Unzip and double-click. On first launch, grant Screen Recording permission to the sender.

If you are testing the current development branch instead of the latest release, build outputs now go into:

- `build/TargetBridge.app`
- `build/TargetBridge Receiver.app`

> **"App is damaged" warning?** macOS quarantines unsigned apps downloaded from the browser. Run this in Terminal, then try again:
> ```bash
> xattr -cr ~/Downloads/TargetBridge.app
> xattr -cr ~/Downloads/TargetBridge\ Receiver.app
> ```

> **Pre-built receiver crashing?** Make sure you downloaded v1.2.0 or later — older builds required Homebrew or macOS 14. Re-download from the [latest release](https://github.com/swellweb/targetBridge/releases/latest).

## Requirements

- Sender: Apple Silicon Mac (M1 or later), macOS 14 Sonoma or later, TB3/4/5
- Receiver: Intel iMac 2017 or later, macOS 11 Big Sur or later, TB3/4/5
- Thunderbolt 3/4/5 cable (backwards compatible)

## Stream profiles

- `Standard · 2560 × 1440` — conservative baseline
- `Smooth · 2560 × 1440 @ 60` — lower latency motion
- `Smooth+ · 3200 × 1800 @ 60` — sharper motion profile
- `Crisp · 3840 × 2160 @ 48` — clearer text with HEVC
- `5K · 5120 × 2880 @ 48` — native iMac 5K stream with HEVC

The sender can stream either an extended virtual display or a mirror of the sender display.

## Direct multi-iMac preview

This branch adds an experimental direct multi-iMac path for setups like:

```text
iMac1 <--TB-- MacBook --TB--> iMac2
```

Current branch behavior:

- one sender app can manage multiple receiver sessions
- each session can bind to its own Thunderbolt Bridge interface
- discovered receivers can be selected from the UI instead of typing the IP manually
- the main target is `extended + extended`; multi-session mirror mode still needs more testing

This is branch-only work for now and should be considered preview / test functionality until it lands in a stable release.

## Extended Desktop

For an extended desktop, choose `Extended display` on the sender before connecting. After the virtual display appears, open macOS **System Settings → Displays → Arrange** on the sender Mac and position the external display where you want it. TargetBridge now reuses the last saved extended-display position for the same receiver when possible.

If the receiver does not fill the iMac panel or the cursor/desktop feels scaled incorrectly, select the external TargetBridge display in macOS Display Settings and choose the matching resolution. For the 27-inch 5K iMac path, use a high-clarity stream profile such as `Crisp` or `5K` with the external display set to the matching 2560 × 1440 HiDPI mode.

## Projects

- `TargetBridge-Sender`
- `TargetBridge-Receiver`

## Quick start

- Italian: `docs/QuickStart-IT.md`
- English: `docs/QuickStart-EN.md`

When testing this branch, the sender can also discover compatible receivers automatically in the UI and prefill their Thunderbolt Bridge IP.
