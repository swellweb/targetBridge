# TargetBridge

Use an Intel iMac as an external display for an Apple Silicon MacBook — free, no dongle, via Thunderbolt Bridge.

Apple removed Target Display Mode on Apple Silicon. TargetBridge brings it back via software, streaming your MacBook screen to the iMac at up to 5K over a direct Thunderbolt cable.

## Screenshots

**Sender (MacBook Apple Silicon) — waiting for connection:**
![TargetBridge Sender](screenshots/sender-idle.png)

**Sender — active stream (5K, HEVC):**
![TargetBridge Sender active](screenshots/sender-active.png)

**Receiver (Intel iMac) — waiting for sender:**
![TargetBridge Receiver](screenshots/receiver.png)

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
