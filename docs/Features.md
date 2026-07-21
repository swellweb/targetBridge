# TargetBridge Feature Guide

This page gives a practical overview of the main TargetBridge features introduced or expanded in the 3.0 line, with links to deeper documentation where it exists.

## Display Modes

TargetBridge supports two main display modes:

- `Duplicate Desktop` mirrors the sender's current desktop to the receiver.
- `Extended Desktop` creates a virtual display on the sender and streams that display to the receiver.

Extended layouts can be arranged in macOS **System Settings -> Displays -> Arrange**. TargetBridge remembers the saved arrangement per receiver when possible and restores it on reconnect.

If the receiver panel does not look correct, set the matching resolution on the TargetBridge display in macOS Display Settings. For 27-inch 5K iMac workflows, the `Crisp` or `5K` stream profiles usually pair best with the matching HiDPI arrangement.

Related reading:

- [docs/QuickStart-EN.md](docs/QuickStart-EN.md)
- [docs/QuickStart-IT.md](docs/QuickStart-IT.md)
- [docs/QuickStart-ZH.md](docs/QuickStart-ZH.md)

## Display Profiles

Each sender session offers three ready-to-use display profiles before connecting:

- `Work 5K` creates an extended desktop at 5K with render matching enabled.
- `Low latency` mirrors the desktop at 1440p and 60 FPS without audio relay.
- `Presentation` mirrors the desktop at 1440p with audio relay enabled.

TargetBridge remembers the last selected profile for each discovered receiver, so
choosing that receiver again restores the matching setup before the next connection.
Profiles never change an active stream; stop the session before applying another one.

## Multi-Receiver Workflows

One sender can connect to multiple receivers at the same time, using multiple cables or links. Each session keeps its own transport, stream profile, display mode, and addon state.

This is useful for:

- one MacBook driving multiple old iMac panels
- separate receiver machines for side displays
- mixed mirror and extended workflows during testing

When multiple extended sessions are active, treat the sender Mac as the central coordinator for display layout.

## Network Link (Experimental)

`Network Link` reuses the same display pipeline over a local IP connection instead of only `Thunderbolt Bridge`.

It is intentionally marked experimental because:

- Thunderbolt is still the recommended low-latency path
- Wi-Fi and general LAN links have more jitter and more variable throughput
- hardware and home-network quality matter much more than with direct Thunderbolt

Use this when:

- the Macs are on the same LAN and you want to test the pipeline without a direct cable
- you want to reuse the same receiver discovery and session model over Ethernet or Wi-Fi

Related reading:

- [docs/Addons.md#official-addons](docs/Addons.md#official-addons)

## Audio Relay

`Audio Relay` streams system audio from the sender to the receiver alongside the video stream.

The current implementation:

- captures system audio on the sender with ScreenCaptureKit
- converts it to low-overhead PCM for the receiver
- uses a receiver ring buffer and bounded backlog to stay responsive under jitter
- is designed for low-latency playback rather than archival-perfect sync

Related reading:

- [docs/audio.md](docs/audio.md)
- [docs/Addons.md#official-addons](docs/Addons.md#official-addons)

## Input Dockstation

`Input Dockstation` adds keyboard and mouse relay between the connected Macs.

The key concepts are:

- `Off`
- `This Mac is Master`
- `Receiver is Master`

Only one active master path should control input at a time.

When input relay is active, TargetBridge can also:

- switch control between slave sessions
- keep or relay control focus depending on the chosen role
- sync text clipboard contents in the direction of the active master
- expose role-specific hotkeys so the active master can switch sender Spaces or change slave target without leaving the session model

When `Receiver is Master` is active, the session settings can also store
custom shortcut bindings. A trigger pressed on the receiver runs an action on
the sender, which makes it possible to use a non-reserved trigger such as
`Ctrl+Option+Left` for a protected sender shortcut such as `Ctrl+Left`.
macOS asks once for permission to let TargetBridge control `System Events` on
the sender when a configured shortcut is first used.

This is useful for KVM-like workflows where one keyboard and mouse should control another connected Mac without leaving the TargetBridge session model.

Related reading:

- [docs/Addons.md#input-dockstation](docs/Addons.md#input-dockstation)

## Remote Brightness Control

The sender can adjust receiver panel brightness directly from the session UI.

This makes it easier to treat the receiver as part of the same workspace without manually opening receiver-side display settings each time.

The current implementation sends brightness updates over the session protocol and applies them on the receiver side.

## Shared Translations

Sender and Receiver now use shared JSON language files stored in the repository.

This makes it much easier to:

- update existing strings
- add a new language
- keep Sender and Receiver terminology aligned

Related reading:

- [docs/Translations.md](docs/Translations.md)

## Thunderbolt Networking Extras

TargetBridge already depends on `Thunderbolt Bridge` as a network path. That same link can also be used for standard peer-to-peer macOS services.

Examples:

- SSH / SFTP
- File Sharing
- Internet Sharing
- Time Machine to storage attached to the other Mac
- printer or storage sharing over the same cable

These are standard macOS networking features that can live alongside TargetBridge.

Related reading:

- [docs/Hardware.md#thunderbolt-networking](docs/Hardware.md#thunderbolt-networking)
