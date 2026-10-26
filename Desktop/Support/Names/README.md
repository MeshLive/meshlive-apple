The three names-v2 text files are the frozen MeshLive Android name lists and pair blocklist,
GPL-3.0-or-later with MeshLive. Source: [StrangerNames.kt and assets at 49f4c2a](https://github.com/MeshLive/meshlive-android/tree/49f4c2a9992509aa72ffd51fdb88109497340fa4/app/src/main/assets/names).

`DesktopNearbyNames` verifies their published SHA-256 digests before use and implements the same
domain-separated hash, blocked-pair retry and collision suffix rules. Editing these files would
change the name of every public input; a new catalogue requires a new protocol catalogue version.
They contain public words only. No device, identity, contact or session data belongs here.
