# MeshLive privacy policy: iPhone and Mac

Last changed: 11 November 2026

## In short
- MeshLive has no account, no server, no ads and no analytics. The developers collect no data about you.
- Calls and livestreams go directly between nearby devices over Bluetooth and are end-to-end encrypted (calls) or encrypted
  between devices (livestreams). Nothing goes through the internet.
- The content is encrypted; the fact that a MeshLive device is nearby is not hidden from someone with a Bluetooth scanner.
- Your identity key stays in the device Keychain. Contacts, recent calls and settings stay on your device and are not backed up.
- Release builds keep no log file and write nothing to the system log.

## What the app asks for
- Bluetooth: to find and connect to people nearby.
- Microphone: for calls.
- Camera: for video calls and to scan a contact's code (asked the first time you need it).
- Notifications: so your device rings for a call.
MeshLive does not use your location, contacts, photos or advertising identifier, and does not track you.

## What nearby devices can see
While the app is open and ready for calls, its Bluetooth announcement carries a rotating ID that changes every 15 minutes. A
livestream offer or a viewer request can carry a stable ID prefix, so a scanner that records them can recognise the same device
over time. Connections use hidden identities: a stranger sees a temporary ID, and your usual ID goes to verified contacts and to
a person you call or whose call you accept. Your name is never broadcast: it is sent encrypted only to the people "Who sees
my name" allows. A livestream title is public to anyone who joins. MeshLive does not make you anonymous. iOS may show your
iPhone's device name (Settings > General > About > Name) to a device that connects, so give it a neutral name.

## What stays on your device
Your keys, verified contacts, recent calls (encrypted with a key that never leaves the device) and settings. "Delete
everything" in Settings erases them. It cannot erase copies held by other people or backups made elsewhere.

## Crash reports
After a crash, the system gives MeshLive a diagnostic. The app keeps a short report (app and system version, device model and
where the app failed; no names, IDs, messages or keys) for up to 7 days and asks at the next launch whether you want to share it.
It is sent only if you share it yourself. "Don't ask again" deletes it and stops keeping reports. "Export diagnostics" in
Settings shows a short technical text before anything leaves the device.

## Blocking and reporting
Blocking is local: the block list is stored encrypted on your device and nobody is told. A report only prepares an email that
you choose to send.

## Children
MeshLive is for people 18 and older.

## Third-party code
MeshLive includes the open-source Opus and libvpx codecs. Their licences are shown in the app under Settings > About this app >
Open-source licences.

## On a Mac
On a Mac, MeshLive advertises from the Mac's fixed Bluetooth address, so anyone scanning nearby can recognise the same Mac over
time. Turn off Allow calls or quit the app when you do not want to be recognisable.

## Contact and changes
meshlive.dev@gmail.com. We will update this page when the app changes; the date of the last change is at the top of the
published page.
