# Stable application identity and privacy permissions

macOS recognises updates by the app's code-signing designated requirement, not
just its name or version. An ad-hoc signature binds that requirement to the
binary's hashes. Rebuilding changes those hashes and can invalidate Screen
Recording, Accessibility, and Input Monitoring consent.

TargetBridge has two applications: Sender (`com.targetbridge.sender`) and
Receiver (`com.targetbridge.receiver`). Both must retain their respective
bundle ID, installation path, and signing identity. This matters whenever the
app has been granted a macOS privacy permission.

## Keep permissions on your own Macs: sign after installing

Pre-built downloads are signed ad-hoc, so macOS treats every update as a new
app and asks for Screen Recording, Accessibility and Input Monitoring again.
Signing the installed apps yourself with one certificate of your own fixes
that. It takes about ten minutes once, then one Terminal command per update.
No Apple Developer account is needed.

You sign on **one** Mac, the one with the certificate, and copy the signed
apps to your other Macs. The other Macs don't need the certificate: the
signature travels with the app.

### Part 1: create the certificate (once)

Skip this part if you already have a `.p12` file for TargetBridge; import it
by double-clicking it and continue with Part 2.

1. Open **Keychain Access**: press Cmd+Space, type `Keychain Access`, press
   Return. (On macOS 15 and later, Spotlight finds it even though it is no
   longer in the Utilities folder.)
2. In the menu bar choose **Keychain Access → Certificate Assistant →
   Create a Certificate…**
3. Fill in:
   - **Name:** `TargetBridge Code Signing` (exactly this; the signing script
     looks for this name)
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create**, confirm the warning with **Continue**, then click
   **Done**.
5. Make a backup: in Keychain Access, select **login** on the left and **My
   Certificates** at the top, right-click **TargetBridge Code Signing** and
   choose **Export…**. Save it as `TargetBridge-CodeSigning.p12` and set a
   password. Keep the file and the password safe, for example in your
   password manager. With a new certificate you'd have to approve the
   permissions again.

### Part 2: trust the certificate (once, on the signing Mac)

1. In Keychain Access, select **login** and **My Certificates**,
   double-click **TargetBridge Code Signing**, expand **Trust**, and set
   **Code Signing** to **Always Trust**. Leave all other settings at "no
   value specified". Close the window and confirm with your Mac password.
2. Check it: open **Terminal** (Cmd+Space, type `Terminal`) and run
   ```bash
   security find-identity -v -p codesigning
   ```
   The list must contain `"TargetBridge Code Signing"`. If it says
   `0 valid identities found`, repeat step 1.

### Part 3: sign every update in one go

1. Make a new folder for the update, for example **TargetBridge 4.0** in
   Downloads, and save all downloads in it: the Sender and the Receiver, for
   Apple silicon (`arm64`) and Intel (`x86_64`), whichever you need. Zipped
   or unzipped doesn't matter.
2. Put the signing script into the same folder. In Terminal (adjust the
   folder name):
   ```bash
   cd ~/Downloads/"TargetBridge 4.0"
   curl -fsSL -o sign-local.sh https://raw.githubusercontent.com/mjfrank/targetBridge/performance/scripts/sign-local.sh
   ```
   You can also download
   [`sign-local.sh`](../scripts/sign-local.sh) in the browser and move it
   into the folder.
3. Run it:
   ```bash
   bash sign-local.sh
   ```
   It unpacks the zips into one folder per download, signs every app it
   finds and lists which app belongs on which Mac, for example
   `TargetBridge Receiver.app (x86_64, for Intel Macs)`. Each app ends with
   a line like `ok: Authority=TargetBridge Code Signing`. If Keychain Access
   asks to allow `codesign` to use the key, enter your Mac password and
   choose **Always Allow**.
4. For the apps that run on this Mac, the script asks
   `Install … into /Applications on this Mac? [y/N]`. Quit the app first,
   then answer `y`.

### Part 4: copy the apps to your other Macs

1. Quit TargetBridge on the other Mac.
2. Copy the signed app from the update folder to that Mac, for example with
   AirDrop, a USB stick or file sharing, and drag it into **Applications**.
   Choose **Replace** if asked. Keep the name exactly `TargetBridge.app` or
   `TargetBridge Receiver.app`.
3. If macOS says the app can't be opened because Apple can't check it (this
   happens after AirDrop or a download), run on that Mac:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/TargetBridge Receiver.app"
   ```
   (or `/Applications/TargetBridge.app`), or click **Open Anyway** in
   **System Settings → Privacy & Security**. This doesn't change the
   signature.

**The first time only**, macOS asks for the permissions once more, because
the app's identity changed from ad-hoc to your certificate. Approve them in
**System Settings → Privacy & Security** (Screen Recording on the Sender Mac;
Accessibility and Input Monitoring where you use them). If the app is listed
there already but doesn't work, select it, remove it with **–**, and add it
again with **+**. From the next update on, the permissions stay.

### Troubleshooting

- **`No valid code-signing certificate named "TargetBridge Code Signing"`**:
  the certificate is missing or not trusted on this Mac; do Part 2 again.
- **The app still asks for permissions after an update**: the update wasn't
  signed, or was signed with another certificate. Sign it again and approve
  the permissions one last time.
- **Check which certificate an app is signed with:**
  ```bash
  codesign -dv /Applications/TargetBridge.app 2>&1 | grep Authority
  ```
- **Sign the apps already in Applications** instead of a download folder:
  `bash sign-local.sh --applications`
- **A certificate with another name:** set `TB_SIGN_IDENTITY`, for example
  `TB_SIGN_IDENTITY="My Certificate" bash sign-local.sh`.

If the macOS firewall is on, the Receiver's sign-in screen mode also needs
the signed Receiver: the firewall only keeps allowing connections at the
sign-in window for an app whose signature doesn't change with every update.

## Build and sign

Use one persistent certificate and keep `com.targetbridge.sender` as the bundle
identifier. Configure `TARGETBRIDGE_CODESIGN_IDENTITY` with the certificate's
fingerprint, or store that public fingerprint in:

`~/Library/Application Support/TargetBridge/Build/sender-signing-identity.txt`

The regular Sender build preserves upstream's disposable ad-hoc CI/development
build when no signing configuration was requested, with a prominent warning.
Set `TARGETBRIDGE_REQUIRE_PERSISTENT_SIGNING=1` to require an update-safe build
even on an unconfigured machine. Configuring an identity or a configuration
file also enables strict preflight: a missing/invalid configured identity never
falls back to ad-hoc. Signing errors and verification failures are fatal.
The build stages the candidate
before replacing the previous build, so a missing/locked signing key leaves the
previous artifact intact.

The packaging build disables Xcode's debug-dylib/preview executor layout, so
the standalone app can be strictly signed without unsigned preview dylibs.
This does not change normal interactive builds in Xcode.

For private local builds only, a persistent self-signed code-signing identity
can be configured using Apple's Certificate Assistant in Keychain Access.
Any change to its trust settings requires the Mac owner's explicit approval;
limit trust to Code Signing. These build scripts never create/trust certificates,
unlock a Keychain, export keys, or change TCC settings. Do not use an unrestricted
trust-root setup. Verify the chosen fingerprint against the actual certificate.

Keep the signing Keychain and always sign on that Mac, even when compilation
happens elsewhere. Do not recreate the certificate for each build. A lost key
requires an intentional identity migration and new consent. A local certificate
is not a substitute for Developer ID and notarization for public distribution.

For public distribution, use Developer ID plus the required notarization
workflow; these scripts alone do not implement notarization. Configure the
same certificate in the `TARGETBRIDGE_CODESIGN_P12_BASE64` and
`TARGETBRIDGE_CODESIGN_P12_PASSWORD` repository secrets before tagging a final
release. The release workflow refuses an exact `vX.Y.Z` release if that
persistent identity is unavailable; prerelease tags remain usable for
disposable CI builds. Do not mix local and upstream signers if preserving
existing consent is required. No Apple Developer membership is provisioned by
these scripts.

When using the signing helper directly, a disposable development build must opt in to both
`TARGETBRIDGE_CODESIGN_IDENTITY=-` and `TARGETBRIDGE_ALLOW_ADHOC=1`. Never install
it over a Sender that is already persistently signed.

## Install/update gate

Before replacing an installed, persistently signed Sender:

```sh
scripts/verify_sender_update.sh /Applications/TargetBridge.app ../build/TargetBridge.app
```

The check rejects ad-hoc signatures, broken bundles, wrong bundle IDs and a
candidate that fails the installed app's designated requirement on any
architecture. Never re-sign, modify Info.plist or otherwise change the bundle
after that check. Preserve the signature with `ditto` and verify it again at the
destination. Keep a recoverable backup outside Applications.

An initial migration from an ad-hoc app intentionally fails this gate: it is an
identity change, not a seamless update. Back up the installed app, replace it
once with the persistently signed app at `/Applications/TargetBridge.app`, and
approve any requested privacy permissions there. The Receiver follows the same
rule at `/Applications/TargetBridge Receiver.app`. Do not edit TCC databases,
run blanket permission resets, or disable system protections. Once the stable
identity is in place, subsequent signed updates preserve the identity macOS
uses to associate existing consent.

## Validation

Test two builds with different executable contents signed with the same
identity: both must pass signature verification and the second must satisfy the
first's designated requirement. Test that an ad-hoc update, a different signer,
wrong bundle ID and a tampered resource are rejected.

`scripts/test_sender_signing.sh /path/to/signed/TargetBridge.app` covers signing
continuity with a changed sealed bundle, missing/unavailable identities, explicit
ad-hoc opt-in, bundle ID mismatch and tampering. Run it with a configured valid
identity; a refusal at preflight is not a passing integration test. Also test a
separate compiled revision and, when available, a second signer before release.

Signing continuity is necessary, not proof that TCC granted permissions. The
final acceptance test is a real A-to-B installed update after human consent on
the Sender Mac, checking screen capture and receiver-controlled input without
granting them again. macOS can still ask for consent after a reset, identity
change, certificate loss, or OS privacy-policy change.

References:
- https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- https://developer.apple.com/library/archive/technotes/tn2206/
- https://developer.apple.com/forums/thread/819406
- https://support.apple.com/guide/keychain-access/kyca8916/mac
