# Sign-in screen mode (experimental)

With this mode installed, a Mac can use the iMac as a display while the iMac
shows its sign-in window, with nobody logged in. The iMac stays locked: the
Receiver only covers the sign-in window while a session runs.

Nothing is installed by default. The mode is a single macOS LaunchAgent file
that you install and remove from the Receiver's menu.

## Requirements

- TargetBridge Receiver 4.0 in **Applications**, signed with your own
  certificate (see [Sender signing](Sender-Signing.md#keep-permissions-on-your-own-macs-sign-after-installing)).
  Otherwise the macOS firewall may block connections at the sign-in window.
- An administrator account on the iMac, for installing and removing the mode.
- **FileVault:** after a restart, FileVault asks for the password before
  macOS starts and then logs you in directly, so the mode can't run then. It
  works once you **log out** (Apple menu → Log Out…). Locking the screen is
  not enough: macOS does not let apps draw over the lock screen.

## Install

1. In the Receiver's menu bar icon choose **Sign-in screen mode
   (experimental) → Install…**
2. Enter an administrator name and password.
3. Log out of the iMac. From now on, every time the iMac shows the sign-in
   window, a second Receiver runs there in the background.

## Use

- On the Mac, connect as usual (or use *Connect automatically* / *Keep
  alive*). The picture appears above the sign-in window.
- The iMac's keyboard and mouse never control the Mac in this mode, so
  nobody at the locked iMac can use your Mac.
- **Esc or a double-click on the iMac** ends the session: the sign-in window
  is back, the Mac shows *Session ended on the receiver*, and the iMac
  refuses new sessions for 5 minutes, so you can sign in. Keep alive does
  not reconnect after this.
- When someone logs in, the sign-in screen Receiver quits and the normal
  Receiver takes over; the Mac's session drops and reconnects if Keep alive
  is on.

## Uninstall

Choose **Sign-in screen mode (experimental) → Uninstall…** and enter an
administrator password. This stops the sign-in screen Receiver and removes
`/Library/LaunchAgents/com.targetbridge.receiver.signin.plist`; the sign-in
window behaves exactly as before.

Without the Receiver, the same in Terminal:

```bash
sudo pkill -f -- '--login-window'; sudo rm -f /Library/LaunchAgents/com.targetbridge.receiver.signin.plist
```

## How it works

- The LaunchAgent has `LimitLoadToSessionType` `LoginWindow`, so macOS
  starts it only at the sign-in window, never inside a user's session. It
  runs `TargetBridge Receiver --login-window`.
- In that mode the Receiver has no menu bar icon and no waiting screen. Its
  window exists only during a session, at the shielding window level above
  the sign-in window, and may appear before login
  (`canBecomeVisibleWithoutLogin`).
- It checks every 2 seconds whether a user has logged in and then quits.
- Log: `/private/tmp/TargetBridge-SignInScreen.log`.

## Status

Experimental and untested on real hardware so far. Apple supports programs at
the sign-in window only with restrictions; if the picture doesn't appear or
the double-click doesn't work, please report it with the log above.
