# iPhone Backup Explorer

A native macOS (SwiftUI) app for browsing iPhone/iPad backups made by Finder or iTunes,
previewing the photos, videos, audio and documents inside them, and exporting files out.

## Features

- Finds every backup in `~/Library/Application Support/MobileSync/Backup`, or opens any backup folder you choose.
- Supports **encrypted backups**: enter the backup password and the app unlocks the key bag and decrypts
  `Manifest.db` and every file on the fly (AES-256 / RFC 3394 key unwrap via CommonCrypto). Nothing is
  written back to the backup.
- Browse by domain (Camera Roll, Home, Media, per-app containers, …) and by category
  (Photos, Videos, Audio, Documents, Databases, Property Lists, Other), with search across paths.
- List view (sortable table) or thumbnail grid for photos and videos.
- Preview pane: images (HEIC, JPEG, PNG…), video and audio playback, pretty-printed plists/JSON/text,
  Quick Look for everything else. Device info (model, iOS version, serial, installed apps) when nothing is selected.
- Export a single file, the current selection, or everything in view. Keeps the `Domain/relative/path`
  structure or flattens into one folder. Modification dates are restored. Progress + cancel + failure report.
- Keyboard: ⌘O open backup folder, ⇧⌘O choose backups location, ⌘R rescan, ⌘E export selected, ⇧⌘E export all in view.

## Building

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open IphoneBackupExplorer.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project IphoneBackupExplorer.xcodeproj -scheme IphoneBackupExplorer -configuration Release -derivedDataPath build build
open build/Build/Products/Release/IphoneBackupExplorer.app
```

## Full Disk Access

macOS protects the MobileSync folder. The first time you run the app it will probably say it can't read the
backups. Either:

1. **System Settings → Privacy & Security → Full Disk Access** → enable *iPhone Backup Explorer*, then relaunch (or ⌘R), or
2. Use **Choose Backups Folder…** / **Open Backup Folder…** (⌘O) and pick the folder yourself. The open panel grants
   access to that folder for the session.

The app is not sandboxed for this reason.

## Notes

- Only the modern `Manifest.db` format (iOS 10 and later) is supported. Older `Manifest.mbdb` backups are detected and reported.
- Decrypted previews are cached in `~/Library/Caches/IphoneBackupExplorer/<UDID>/` and cleared when you switch backups.
- Files in protection classes that require the device's hardware key (rare in backups) will fail to decrypt with a clear error.

## Headless smoke test

```bash
build/Build/Products/Debug/IphoneBackupExplorer.app/Contents/MacOS/IphoneBackupExplorer \
  -selfTest /path/to/backup/UDID -password 'backup password' -out /tmp/export
```

Lists every file in the manifest and exports them, printing any failures.
