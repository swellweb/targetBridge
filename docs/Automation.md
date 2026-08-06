# Remote Connection & Automation (Sender)

TargetBridge's Sender can be driven without the GUI — for scripting, SSH, remote
connection from another Mac, or connecting automatically on login/wake. It reuses the
same in-app connect/disconnect paths the GUI uses, so there's no separate control logic
to keep in sync.

There are two equivalent entry points, plus a small CLI wrapper:

## 1. `targetbridge` CLI

A thin wrapper (in [`cli/targetbridge`](../cli/targetbridge)) over the URL scheme. Put it on your `PATH`:

```bash
install -m 0755 cli/targetbridge /usr/local/bin/targetbridge   # or ~/bin, etc.
```

```bash
targetbridge connect                                            # auto-pick receiver, app defaults
targetbridge connect --receiver auto --mode mirror --preset retina4k --path auto --input receiver --retry
targetbridge connect --receiver 169.254.0.2 --mode extended --preset 5k
targetbridge disconnect
```

Options: `--receiver auto|<id|name|ip>`, `--mode mirror|extended`, `--preset <name>`,
`--path auto|wired|thunderbolt|usb|ethernet|wifi`, `--input receiver|sender|off`,
`--retry`, `--transport tb|net`, `--session N`, `--local-ip <ip>`.
Presets: `standard1440p`, `smooth1440p60`, `smooth1800p60`, `crisp2160p60`, `retina4k60`, `native5k`,
`native5k60Experimental` (aliases: `1440p`, `1440p60`, `1800p`, `4k`, `5k`, `5k60`).
The `retina4k60` profile streams the native 4096 × 2304 panel size of the 21.5-inch
Retina 4K iMac at 60 FPS. With `--path auto`, the Sender probes every advertised
path using a bounded real transfer and chooses the fastest working route. `--retry`
keeps monitoring the session and re-runs selection after a link failure.
`native5k60Experimental` is an opt-in HEVC test profile for 5K at 60 FPS; it does not
replace the stable 5K 48 FPS profile. A receiver of `auto` waits briefly for
Bonjour discovery and uses the first receiver found; a raw IP/hostname bypasses discovery.

It launches the Sender on demand and works whether the app is already running or not.

## 2. URL scheme

The CLI just builds and opens a `targetbridge://` URL — you can use these directly
(in Shortcuts, Raycast, a `.command` file, etc.):

```
targetbridge://connect?receiver=auto&mode=mirror&preset=native5k
targetbridge://connect?receiver=<receiver-ip>&mode=extended&preset=1440p&session=1
targetbridge://disconnect
```

```bash
open "targetbridge://connect?receiver=auto&mode=mirror&preset=1440p"
```

## 3. Launch arguments (connect on launch / login item)

Passing `--connect` (and the same options) to the app at launch connects once it's up —
handy for a Login Item or LaunchAgent:

```bash
open -a TargetBridge --args --connect --receiver auto --mode mirror --preset 1440p
```

## Recipes

**Connect from another Mac over SSH** — the Sender must be at a logged-in desktop with
TargetBridge installed.

Start with the simplest form first:

```bash
ssh <sender-user>@<sender-host> \
  "open 'targetbridge://connect?receiver=auto&mode=mirror&preset=1440p'"
```

On some macOS setups, if LaunchServices does not deliver the URL into the active GUI
session from a plain remote shell, fall back to `launchctl asuser`:

```bash
ssh <sender-user>@<sender-host> \
  "launchctl asuser \$(id -u <sender-user>) open 'targetbridge://connect?receiver=auto&mode=mirror&preset=1440p'"
```

If that still fails with an audit-session permission error, try the same command through
`sudo` from an interactive SSH session (`ssh -t ...`), because the GUI handoff can be more
strict on some systems.

**Let the Receiver recover a headless Sender** — the monitor-mode Receiver includes an
optional recovery helper. Provision a dedicated, restricted SSH key locally; credentials
are deliberately never bundled in the app or installer. Store the private key and pinned
host key in:

```
~/Library/Application Support/TargetBridge/Recovery/id_ed25519_targetbridge_recovery
~/Library/Application Support/TargetBridge/Recovery/known_hosts
```

Pair the Sender hostname and account by writing one line to each file:

```
~/Library/Application Support/TargetBridge/Receiver/paired-mac-mini
~/Library/Application Support/TargetBridge/Receiver/paired-mac-mini-user
```

The Sender-side authorized key should use a forced command restricted to TargetBridge's
start/stop and input-mode actions. The Receiver first tries the paired hostname, then its
last working hostname, an optional `Recovery/target-host`, `TB_SENDER_HOST`, and finally
the generic `mac-mini.local` mDNS name. `TB_SENDER_USER` can override the paired account.

**Auto-connect on wake (Hammerspoon, on the sender):**

```lua
hs.caffeinate.watcher.new(function(e)
  local w = hs.caffeinate.watcher
  if e == w.systemDidWake or e == w.screensDidUnlock then
    hs.timer.doAfter(2, function()
      hs.execute("open 'targetbridge://connect?receiver=auto&mode=mirror&preset=1440p'")
    end)
  end
end):start()
```

**Arrange the display after connecting (displayplacer):** TargetBridge restores its saved
extended-desktop arrangement at connect time, so apply your own layout *after* the stream
is up (e.g. poll until the display appears, then run your saved `displayplacer "..."` command).

## Notes

- The Sender's capture pipeline requires a logged-in GUI session; these entry points
  signal the app inside that session — they do not (and cannot) start screen capture from a
  pure headless context.
- `auto` requires the receiver to be discoverable over Bonjour (`_targetbridge._tcp`). On
  first use, grant the Sender Screen Recording permission as usual.
- These commands are fire-and-forget: the CLI / `open` returns as soon as the URL is
  delivered, which is **not** the same as "streaming established." Check the app (or its
  log: `log show --predicate 'eventMessage CONTAINS "[automation]"' --last 2m`) to confirm.
- For remote SSH automation, a plain `open 'targetbridge://...'` is often enough and is the
  least brittle option. Use `launchctl asuser` only when the plain form does not reach the
  active GUI session on the sender.
- `connect` without `--session` targets session 1 and updates its saved receiver, same as
  changing it in the GUI.
- On a cold launch, `receiver=auto` waits briefly for Bonjour; if discovery is slow on the
  first run, pass an explicit `--receiver <ip>` to skip the wait.
