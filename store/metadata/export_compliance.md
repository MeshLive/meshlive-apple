# Export compliance (App Store Connect)

The app's `Info.plist` has `ITSAppUsesNonExemptEncryption` = **NO**.

| Question | Draft answer | Reason |
|---|---|---|
| Does the app use encryption? | Yes | Calls and streams use authenticated end-to-end encryption, and links use a signed handshake. |
| Is the cryptography provided by the operating system? | Yes, all of it is Apple's CryptoKit | Key agreement, signatures and authenticated encryption use CryptoKit only. |
| Does the app use a proprietary or non-standard algorithm? | No | No custom cipher or proprietary algorithm is implemented. |
| Is encryption exposed to the user or configurable? | No | It is built into calls and streams and has no user setting. |
| Does the app use encryption for anything else? | No | No DRM, VPN, disk encryption or payment cryptography. |

Recorded classification: ECCN 5D992.c under the mass-market provision (License Exception ENC section 740.17(b)(1)); no
annual self-classification report is required for such items since 2021.

**Risk line for the owner:** Apple's flow distinguishes encryption the operating system supplies from encryption an app
adds. This app adds its own handshake on top of CryptoKit, so answer the form's questions literally and keep the answers
consistent with the Info.plist key. If the form routes to a documentation upload, the rationale above is the draft.

**This is not legal advice; the owner decides the declaration and whether to file anyway.**

**Verify in the form:** the export-compliance questions and their labels change; the intent is "uses encryption",
"operating-system cryptography", no proprietary algorithm, and the recorded classification above.
