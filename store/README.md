# Store metadata and assets

Everything App Store Connect needs for MeshLive 1.0, ready for the owner to paste or pull in. Nothing in this folder is
uploaded by a script.

| Folder | Contents |
|---|---|
| `metadata/en-US/` | The listing texts, one file per App Store Connect field. |
| `metadata/` | Review notes and the answer sheets for the App Store Connect questionnaires. |
| `web/` | Drafts of the terms, privacy and support pages the owner publishes. |

The files are plain UTF-8 text with LF line endings and one trailing newline. The field limits are the App Store Connect
limits:

| File | Limit |
|---|---|
| `name.txt` | 30 characters |
| `subtitle.txt` | 30 characters |
| `promotional_text.txt` | 170 characters |
| `description.txt` | 4,000 characters |
| `keywords.txt` | 100 characters, comma-separated, no spaces after commas |
| `release_notes.txt` | 4,000 characters |
| `support_url.txt`, `marketing_url.txt`, `privacy_url.txt` | one https URL |

Check every file before pasting:

```sh
python3 Scripts/check-store-metadata.py
```

The checker prints `PASS` or `FAIL` for each file and exits 0 only when everything passes. It does not contact Apple, and
nothing here uploads a build or the listing.
