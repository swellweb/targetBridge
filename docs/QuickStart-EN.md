# TargetBridge Quick Start (English)

## Package contents

- `TargetBridge-Sender`
- `TargetBridge-Receiver`

## Build the sender

```bash
cd TargetBridge-Sender
./scripts/build_targetbridge_sender_app.sh
```

Produced app:

- `build/TargetBridge.app`

## Build the receiver

Before building, install the required dependencies on the iMac:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ffmpeg sdl2 pkgconf
```

Then build:

Note: The build script automatically bundles FFmpeg and SDL2 inside the `.app` — no Homebrew is needed at runtime.

```bash
cd TargetBridge-Receiver
./scripts/build_tbreceiver_c_app.sh
```

Produced app:

- `build/TargetBridge Receiver.app`

Note:

- On an Intel iMac, build the receiver directly on that iMac so the resulting binary is `x86_64`.

## Launch

### MacBook

Open:

- `build/TargetBridge.app`

On first launch, grant:

- `Screen Recording` permission.

### iMac

Open:

- `build/TargetBridge Receiver.app`

Write down the IP address shown in the startup window.

## Connect

1. Start `TargetBridge Receiver` on the iMac first
2. Read the Thunderbolt Bridge IP shown by the receiver
3. Open `TargetBridge` on the MacBook
4. Choose `Extended display` to use the iMac as a separate desktop, or `Mirror MacBook` to duplicate the MacBook screen
5. Enter that IP in the `Receiver IP` field
6. Press `Connect`

When the first frame arrives, the receiver switches to fullscreen automatically.

For extended desktop, open macOS **System Settings → Displays → Arrange** on the sender Mac after connecting. Place the external TargetBridge display where you want it, then select that display in Display Settings and choose the matching resolution if the iMac does not fill correctly. For the 27-inch 5K path, use the `5K` stream profile with the external display set to the matching 5120 × 2880 / 2560 × 1440 HiDPI mode.

## Stream profiles

- `Standard · 2560 × 1440`
  - conservative baseline
  - highest compatibility

- `Smooth · 2560 × 1440 @ 60`
  - lower latency motion

- `Smooth+ · 3200 × 1800 @ 60`
  - sharper motion profile

- `Crisp · 3840 × 2160 @ 48`
  - clearer text
  - uses `HEVC`
  - lighter than native 5K

- `5K · 5120 × 2880 @ 48`
  - native iMac 5K stream
  - uses `HEVC`
  - highest load

## Auto-start the receiver

To start the receiver automatically at user login on the iMac:

```bash
cd TargetBridge-Receiver
./scripts/install_tbreceiverc_launch_agent.sh
```

To remove it:

```bash
cd TargetBridge-Receiver
./scripts/uninstall_tbreceiverc_launch_agent.sh
```

## Practical notes

- the receiver should be started before the sender
- extended desktop requires arranging the new display in macOS Display Settings on the sender
- the sender can show or hide its top bar icon
- if 5K is not responsive enough, switch back to `Crisp` or `Smooth+`
- the sender build script uses a local DerivedData folder at `TargetBridge-Sender/.build/DerivedData`
