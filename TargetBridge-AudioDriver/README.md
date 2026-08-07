# TargetBridge audio driver (optional)

Presents the receiver Mac's speakers and microphone as ordinary audio devices on
the sender Mac, so they can be picked from the Sound menu or per app instead of
only from inside TargetBridge.

**This is entirely optional.** TargetBridge is fully functional without it, and
nothing in the app installs it, prompts for it, or depends on it. It is built
and installed by hand.

## What installing it changes on your Mac

| | |
|---|---|
| Adds | one bundle at `/Library/Audio/Plug-Ins/HAL/TargetBridge.driver` |
| Restarts | the system audio server, which briefly interrupts audio in **all** apps |
| Ends | any plug-in host process that has this driver's binary open (only this one — other vendors' audio drivers are left alone) |
| Needs | admin, for the two steps above |

It writes nothing else, installs no launch agent or daemon, and starts nothing
at login. Removal is `./uninstall.sh`, which deletes the bundle and restarts the
audio server.

## Build and install

```sh
./build.sh
./install.sh      # asks for your password
```

The device then appears in Audio MIDI Setup and the Sound menu as
"TargetBridge". To remove it:

```sh
./uninstall.sh
```

## How it works

Audio written to the device is forwarded over loopback UDP to the TargetBridge
app, which sends it to the receiver. The microphone path runs the other way.

The driver withdraws its device when the app is not there to carry audio — a
virtual device that is still listed but silently dropping everything is worse
than no device at all. It detects this by probing the app's socket rather than
listening on one of its own; see the comments in `Driver.cpp` for why that
distinction matters.

## Third-party code

`vendor/libASPL` is [libASPL](https://github.com/gavv/libASPL) by Victor Gaydov,
MIT licensed, vendored unmodified (only `src/` and `include/`; its CMake build,
tests and examples are not used). It implements the AudioServerPlugIn interface,
which is what keeps this driver at a few hundred lines instead of a few thousand
lines of vtable plumbing.

BlackHole was not usable here despite solving a similar problem: it is GPL-3.0
and TargetBridge is MIT.
