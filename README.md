![TargetBridge Overview](images/connection-diagram.svg)

# TargetBridge

Apple dropped Target Display Mode in late 2014 with the 5K iMac — and it never came back.

TargetBridge brings it back via software, streaming your screen at up to 5K over a direct Thunderbolt connection, e.g. to an iMac.

It's free and open source software, no subscription and no dongle required.

If it is useful to you, spread the news and give us a ⭐ on GitHub.

Sponsoring the TargetBridge project is also very welcome:

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/swellweb)

## TargetBridge 3.2

TargetBridge 3.2 builds on the multi-Mac workspace foundation with more
reliable display preferences, receiver-driven shortcuts, and repeatable
hardware-free Receiver testing:

- mirror mode and extended desktop mode
- multiple receivers from one sender
- experimental `Network Link` transport in addition to Thunderbolt Bridge
- streamed system audio
- shared JSON localization for Sender and Receiver
- official manifest-based addons
- `Input Dockstation` with master/slave keyboard and mouse control
- text clipboard sync tied to the active input master
- remote brightness control from the sender
- automatic receiver discovery and extended-layout restore
- remote connection automation via URL scheme, CLI wrapper, launch args, and SSH recipes
- remembers the selected virtual-display resolution for each receiver
- configurable Receiver Master shortcuts, including protected macOS shortcuts such as Space switching
- mock sender, parser tests, and a loopback smoke test for Receiver resilience without a second Mac

## Feature Guides

- Overview hub: [docs/Features.md](docs/Features.md)
- Mirror mode and Extended Desktop: [docs/Features.md#display-modes](docs/Features.md#display-modes)
- Multi-receiver layouts: [docs/Features.md#multi-receiver-workflows](docs/Features.md#multi-receiver-workflows)
- Network Link (experimental): [docs/Features.md#network-link-experimental](docs/Features.md#network-link-experimental)
- Audio Relay: [docs/Features.md#audio-relay](docs/Features.md#audio-relay)
- Input Dockstation, clipboard sync, master/slave roles, and Receiver Master shortcuts: [docs/Features.md#input-dockstation](docs/Features.md#input-dockstation)
- Remote brightness control: [docs/Features.md#remote-brightness-control](docs/Features.md#remote-brightness-control)
- Remote connection & automation (URL scheme, launch args, SSH, login/wake): [docs/Automation.md](docs/Automation.md)
- Shared translations and language files: [docs/Features.md#shared-translations](docs/Features.md#shared-translations)
- Thunderbolt networking extras (SSH/SFTP, file sharing, Internet Sharing): [docs/Features.md#thunderbolt-networking-extras](docs/Features.md#thunderbolt-networking-extras)

## Core Features

- Sender can stream either a mirrored desktop or an extended virtual display. See [Display Modes](docs/Features.md#display-modes).
- One sender can drive multiple receiver Macs over separate cables. See [Multi-Receiver Workflows](docs/Features.md#multi-receiver-workflows).
- Stream profiles range from `2560 x 1440` to `5120 x 2880` with H.264/HEVC selection based on capability. See [Display Modes](docs/Features.md#display-modes).
- Receiver discovery is automatic over Bonjour. Extended-display arrangement is remembered per receiver when possible. See [Display Modes](docs/Features.md#display-modes).
- Thunderbolt Bridge remains the primary low-latency path, with `Network Link` available as an experimental addon-gated transport. See [Network Link](docs/Features.md#network-link-experimental).

## Official Addons

TargetBridge now has a conservative manifest-based addon system. Official manifests ship with the app, and user manifests can be imported from the settings UI.

- `Network Link`: local Ethernet/Wi-Fi transport path for the same display pipeline. See [docs/Addons.md#official-addons](docs/Addons.md#official-addons) and [Network Link](docs/Features.md#network-link-experimental).
- `Audio Relay`: streamed system audio from sender to receiver. See [docs/audio.md](docs/audio.md) and [docs/Addons.md#official-addons](docs/Addons.md#official-addons).
- `Input Dockstation`: keyboard/mouse relay, master/slave roles, slave switching, and text clipboard sync. See [docs/Addons.md#input-dockstation](docs/Addons.md#input-dockstation) and [Input Dockstation](docs/Features.md#input-dockstation).

## Requirements

- Sender: Apple Silicon Mac (M1 or later), macOS 14 Sonoma or later
- Receiver: Intel or Apple Silicon Mac, macOS 11 Big Sur or later
- Thunderbolt cable
- See also [docs/Hardware.md](docs/Hardware.md) for hardware details, tested cables, adapters, and Thunderbolt networking ideas.

## Download

**[→ Download latest release (pre-built apps, no Xcode needed)](https://github.com/swellweb/targetBridge/releases/latest)**

- `TargetBridge-arm64.app.zip` — Sender (for Apple Silicon Macs)
- `TargetBridge-Receiver-arm64.app.zip` — Apple Silicon Receiver (use machine as monitor for sender)
- `TargetBridge-Receiver-x86_64.app.zip` — Intel Receiver (use machine as monitor for sender)

Unzip and double-click. On first launch, grant Screen Recording permission to the sender.

If you build from source, app outputs go into `build/` folder.

> **"App is damaged" warning?** macOS quarantines unsigned apps downloaded from the browser. Run this in Terminal, then try again:
> ```bash
> xattr -cr ~/Downloads/TargetBridge-arm64.app
> xattr -cr ~/Downloads/TargetBridge-Receiver-arm64.app
> xattr -cr ~/Downloads/TargetBridge-Receiver-x86_64.app
> ```

## Permissions

- Sender usually needs `Screen Recording`.
- `Input Dockstation` may also require `Accessibility` and `Input Monitoring`, depending on the active role.
- Receiver may require `Accessibility` or `Input Monitoring` when it participates in input relay.
- In practice, `Input Dockstation` is a two-sided feature: one Mac captures input, the other injects it, so permissions may be needed on both Sender and Receiver.
- See [docs/Addons.md#input-dockstation](docs/Addons.md#input-dockstation) for the permission matrix.

## Quick start

- Italian: [docs/QuickStart-IT.md](docs/QuickStart-IT.md)
- English: [docs/QuickStart-EN.md](docs/QuickStart-EN.md)
- 中文: [docs/QuickStart-ZH.md](docs/QuickStart-ZH.md)
- Translation guide: [docs/Translations.md](docs/Translations.md)

## Detailed Documentation

- Feature overview: [docs/Features.md](docs/Features.md)
- Remote connection & automation: [docs/Automation.md](docs/Automation.md)
- Addon manifests and capability model: [docs/Addons.md](docs/Addons.md)
- Audio transport internals: [docs/audio.md](docs/audio.md)
- Hardware, cables, adapters, and Thunderbolt Bridge networking: [docs/Hardware.md](docs/Hardware.md)
- Translation workflow: [docs/Translations.md](docs/Translations.md)
- Testing without hardware (unit tests, mock sender, loopback smoke): [docs/Testing.md](docs/Testing.md)
- Binary verification: [docs/verify-binaries.md](docs/verify-binaries.md)

## Licensing and brand

TargetBridge source code is available under the MIT License. Please preserve the
required copyright and license notices when redistributing copies or substantial
portions of the software.

Project branding and commercial use are handled separately from the source code
license. For now, the canonical source-code license is:

- [LICENSE](LICENSE)

## Screenshots

**Sender (Apple Silicon Mac) — multi-session dashboard:**
![TargetBridge Sender](images/sender-multisession.png)

**Sender — active mirrored stream (5K, HEVC):**
![TargetBridge Sender active](images/sender-active-mirror.png)

**Receiver (Intel iMac) — waiting for sender:**
![TargetBridge Receiver](images/receiver.png)

**macOS Displays — extended desktop target:**
![TargetBridge extended desktop](images/display-extend.png)

**macOS Displays — mirrored desktop target:**
![TargetBridge mirrored desktop](images/display-mirror.png)
