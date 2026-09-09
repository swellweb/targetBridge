# Stable Sender identity and privacy permissions

macOS recognises updates by the app's code-signing designated requirement, not
just its name or version. An ad-hoc signature binds that requirement to the
binary's hashes. Rebuilding changes those hashes and can invalidate Screen
Recording and Accessibility consent.

## Build and sign

Use one persistent certificate and keep `com.targetbridge.sender` as the bundle
identifier. Configure `TARGETBRIDGE_CODESIGN_IDENTITY` with the certificate's
fingerprint, or store that public fingerprint in:

`~/Library/Application Support/TargetBridge/Build/sender-signing-identity.txt`

The regular Sender build now refuses to silently produce an ad-hoc artifact.
Signing errors and verification failures are fatal. It stages the candidate
before replacing the previous build, so a missing/locked signing key leaves the
previous artifact intact.

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

For distribution, use Developer ID plus the required notarization workflow;
these scripts alone do not implement notarization. Do not mix local and upstream signers if preserving existing consent
is required. No Apple Developer membership is provisioned by these scripts.

For a disposable development build only, explicitly opt in to both
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
approve Screen Recording and Accessibility there if macOS asks. Do not edit
TCC databases, run blanket permission resets, or disable system protections.

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
