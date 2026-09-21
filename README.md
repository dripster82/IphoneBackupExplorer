# iPhone Backup Explorer

**Browse and export the contents of local iPhone and iPad backups on your Mac—without paying for a one-use recovery app.**

iPhone Backup Explorer is a free, native macOS app for Finder and iTunes backups. It can open encrypted backups, search their contents, preview common file types, and export the data you need. Processing happens locally on your Mac; the app does not upload your backup or its contents.

[**Download the latest release**](https://github.com/dripster82/IphoneBackupExplorer/releases/latest) · [View all releases](https://github.com/dripster82/IphoneBackupExplorer/releases) · [Report a problem](https://github.com/dripster82/IphoneBackupExplorer/issues)

## At a glance

- **Free and open source** under the MIT Licence
- **Private by design**—your backup stays on your Mac
- **Encrypted backup support** using your existing backup password
- **Native SwiftUI app** for macOS 14 Sonoma or later
- **Apple silicon and Intel support**

## What you can browse

- Photos, videos, audio, documents, databases and property lists
- Messages and attachments
- WhatsApp conversations and attachments
- Contacts, call history and voicemail
- Notes, calendars and reminders
- Safari history and bookmarks
- Health summaries and photo metadata, including dates and GPS data
- Known Wi-Fi networks, accounts and app permissions
- Password and keychain data from supported encrypted backups
- Installed apps and the raw backup domain/file structure

Availability varies with the iOS version, the apps installed on the device, and what was included in the backup.

## Project status

I originally developed iPhone Backup Explorer for personal use, specifically to recover photos and videos from an iPhone backup. The other data viewers and export features grew out of curiosity while exploring what else the backup contained.

Those additional features appear to work well, but they have not yet been extensively tested against a wide range of devices, iOS versions and real-world backups. You may encounter bugs or unsupported variations in Apple's data formats. Keep your original backup unchanged, verify exported data before relying on it, and please [report anything that does not work](https://github.com/dripster82/IphoneBackupExplorer/issues).

## More features

- Automatically finds backups in `~/Library/Application Support/MobileSync/Backup`
- Opens a backup or backup-folder location you choose, including via drag and drop
- Searches across files, contacts, messages and other loaded data with `⇧⌘F`
- Shows images in a thumbnail gallery and plays supported video, audio and voicemail
- Previews text, JSON and property lists, with Quick Look for other supported files
- Resolves phone numbers to contact names in messages, calls and voicemail
- Exports individual items, selections, visible categories or a complete backup
- Exports structured data to formats including CSV, vCard, iCalendar, Markdown and HTML
- Preserves the original folder structure or produces a flattened export
- Checks for signed and notarized updates from GitHub Releases

## Install

1. Open the [latest release](https://github.com/dripster82/IphoneBackupExplorer/releases/latest).
2. Download the `.dmg` file.
3. Open it and drag **iPhone Backup Explorer** to **Applications**.
4. Launch the app and select a backup.

The current release requires **macOS 14 Sonoma or later**.

### Allowing access to backups

macOS protects the MobileSync folder. If the app cannot read your backups, either:

1. Open **System Settings → Privacy & Security → Full Disk Access**, enable **iPhone Backup Explorer**, then relaunch the app; or
2. Use **Choose Backups Folder…** or **Open Backup Folder…** (`⌘O`) and select the folder manually.

The second option grants access to the folder you select for that session. The app is not sandboxed because it needs to read Finder/iTunes backup data from macOS's protected MobileSync folder.

## Privacy and security

- Backup processing and decryption happen locally.
- Nothing is written back to the original backup.
- Decrypted previews are cached in `~/Library/Caches/IphoneBackupExplorer/<UDID>/` and cleared when you switch backups.
- Backup passwords can unlock highly sensitive data. Only open backups you own or are authorised to access, and take care when exporting passwords, messages, health information or location data.
- In-app updates are downloaded from GitHub Releases and checked for signing and notarisation before installation.

## Compatibility and limitations

- Modern `Manifest.db` backups from iOS 10 and later are supported.
- Older `Manifest.mbdb` backups are detected but cannot currently be opened.
- Some protection classes require a device hardware key and cannot be decrypted from a backup alone; the app reports these files clearly.
- A backup may not contain every category shown above.

## Build from source

Building requires Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open IphoneBackupExplorer.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project IphoneBackupExplorer.xcodeproj \
  -scheme IphoneBackupExplorer \
  -configuration Release \
  -derivedDataPath build \
  build

open build/Build/Products/Release/IphoneBackupExplorer.app
```

## Headless smoke test

```bash
build/Build/Products/Debug/IphoneBackupExplorer.app/Contents/MacOS/IphoneBackupExplorer \
  -selfTest /path/to/backup/UDID \
  -password 'backup password' \
  -out /tmp/export
```

This lists every file in the manifest, exports it and reports any failures.

## Feedback and contributions

Bug reports, feature ideas and pull requests are welcome. Please use [GitHub Issues](https://github.com/dripster82/IphoneBackupExplorer/issues) and avoid attaching real backup files or personal data to a public issue.

## Licence

iPhone Backup Explorer is released under the [MIT Licence](LICENSE).
