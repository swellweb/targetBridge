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

Pre-built downloads are signed ad-hoc, so each update looks like a new app to
macOS. Signing the installed apps yourself with one certificate fixes that.
No Apple Developer account is needed for your own Macs.

**Once per Mac:**

1. You need a code-signing certificate with its private key as a `.p12` file
   (for example `TargetBridge-CodeSigning.p12`) and its password. Keep both
   safe, for example in a password manager: every Mac and every update must use
   the same certificate. A new certificate means approving the permissions
   again. To make your own instead, use Keychain Access → Certificate
   Assistant → Create a Certificate, with the type *Code Signing*.
2. Double-click the `.p12` file and enter its password. It's added to your
   login keychain.
3. Trust it for code signing: in Keychain Access, open the certificate (it's
   under *My Certificates*), expand *Trust*, set *Code Signing* to
   *Always Trust*, and confirm with your Mac password. Leave the other
   settings as they are.
4. Check it in Terminal; the certificate should appear in the list:
   ```bash
   security find-identity -v -p codesigning
   ```

**After every install or update, before the first launch:**

Copy the app to `/Applications`, then run
[`sign-local.sh`](../scripts/sign-local.sh) in Terminal:

```bash
bash ~/Downloads/sign-local.sh
```

It signs `TargetBridge.app` and `TargetBridge Receiver.app` in
`/Applications` with your certificate (nested code first), removes the download
quarantine, and verifies the result. To sign other copies, pass their paths;
for a certificate with another name, set `TB_SIGN_IDENTITY`. Without the
script, the same in two commands:

```bash
xattr -cr /Applications/TargetBridge.app
codesign --force --deep --sign "TargetBridge Code Signing" /Applications/TargetBridge.app
```

The first launch after switching from an ad-hoc build asks for the permissions
one last time. After that, updates keep them, as long as each one is signed
with the same certificate and stays in `/Applications` under the same name.

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
