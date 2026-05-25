Addons for TargetBridge
=======================

TargetBridge supports manifest-based addons in the Sender.

This first implementation is intentionally conservative:
- addons are discovered from JSON manifest files
- addons can be enabled or disabled from the Sender settings UI
- addons can expose capabilities that the Sender can react to
- addons do **not** load arbitrary executable code

This gives us a safe extension point without destabilizing the core display
pipeline.

Where addon files live
----------------------

User-installed addon manifests are loaded from:

`~/Library/Application Support/TargetBridge/Addons/User/`

Bundled official addon manifests also ship inside the app bundle and are mirrored to:

`~/Library/Application Support/TargetBridge/Addons/Official/`

How to add an addon
-------------------

1. Create a JSON manifest file.
2. Open **TargetBridge > Settings > Add-ons**.
3. Click **Import Addon...**.
4. Select the JSON file.
5. Enable or disable the addon from the list.

Manifest format
---------------

Example:

```json
{
  "id": "com.example.targetbridge.my-addon",
  "name": "My Addon",
  "version": "1.0",
  "summary": "Short human-readable description.",
  "author": "Example",
  "minimumSenderVersion": "3.0",
  "capabilities": [
    "network-link"
  ],
  "experimental": true,
  "defaultEnabled": false
}
```

Fields:
- `id`: stable unique identifier
- `name`: display name in the UI
- `version`: addon version string
- `summary`: short description
- `author`: optional author name
- `websiteURL`: optional website URL
- `documentationURL`: optional documentation URL
- `minimumSenderVersion`: optional minimum TargetBridge sender version
- `capabilities`: array of capability identifiers
- `experimental`: whether the addon should be labeled experimental
- `defaultEnabled`: whether it should be enabled by default

Current capability identifiers
------------------------------

- `network-link`
- `audio-relay`
- `input-dockstation`

Notes
-----

- If an addon is incompatible with the installed Sender version, it will still
  be listed in the UI but marked incompatible.
- This addon system currently targets the Sender UI and feature gating.
- The `input-dockstation` addon forwards keyboard and mouse input from the
  currently selected master Mac to one connected slave session at a time.
- The current input roles are:
  - `Off`
  - `This Mac is Master`
  - `Receiver is Master`
- When `This Mac is Master` is active, you can also choose how to switch
  control between slave sessions:
  - keep the master's desktop behavior fully native
  - or use the left/right screen edge and the `Ctrl+Option+Left/Right`
    hotkeys to move control to the previous/next slave
- The `input-dockstation` addon requires extra macOS permissions:
  - on the Sender, accessibility/input-monitoring approval may be needed so
    TargetBridge can observe keyboard and mouse activity
  - on the Receiver, accessibility approval may be needed so TargetBridge can
    inject synthetic keyboard and mouse events
- The current input relay implementation does not suppress local input on the
  Sender. Events continue to affect the Sender while also being forwarded to
  the active Receiver session.
