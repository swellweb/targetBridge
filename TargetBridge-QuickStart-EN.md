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

- `~/Desktop/TargetBridge.app`

## Build the receiver

Before building, install the required dependencies on the iMac:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ffmpeg sdl2 pkg-config
```

Then build:

Note: the build script automatically bundles ffmpeg and SDL2 inside the `.app` — no Homebrew needed at runtime.

```bash
cd TargetBridge-Receiver
./scripts/build_tbreceiver_c_app.sh
```

Produced app:

- `~/Desktop/TargetBridge Receiver.app`

Note:

- on an Intel iMac, build the receiver directly on that iMac so the resulting binary is `x86_64`

## Launch

### MacBook

Open:

- `TargetBridge.app`

On first launch, grant:

- `Screen Recording`

### iMac

Open:

- `TargetBridge Receiver.app`

Write down the IP address shown in the startup window.

## Connect

1. Start `TargetBridge Receiver` on the iMac first
2. Read the Thunderbolt Bridge IP shown by the receiver
3. Open `TargetBridge` on the MacBook
4. Enter that IP in the `Receiver IP` field
5. Press `Connect`

When the first frame arrives, the receiver switches to fullscreen automatically.

## Stream profiles

- `Standard · 2560 × 1440`
  - lower latency
  - higher stability
  - less sharp than native 5K

- `5K · 5120 × 2880`
  - sharper image
  - uses `HEVC`
  - more load and slightly higher latency

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
- the sender can show or hide its top bar icon
- if 5K is not responsive enough, switch back to the `Standard` profile
- the sender build script uses a local DerivedData folder at `TargetBridge-Sender/.build/DerivedData`
