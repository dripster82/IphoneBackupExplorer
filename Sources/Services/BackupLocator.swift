import Foundation

enum BackupLocator {
    static var defaultBackupRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    /// Scans a MobileSync root folder for backup subfolders.
    static func scan(root: URL) throws -> [BackupDevice] {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoPermissionError || error.code == NSFileReadUnknownError) {
                throw BackupError.permissionDenied(root)
            }
            if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
                throw BackupError.permissionDenied(root)
            }
            throw error
        }
        var devices: [BackupDevice] = []
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let device = try? load(backupFolder: url) { devices.append(device) }
        }
        return devices.sorted { ($0.lastBackupDate ?? .distantPast) > ($1.lastBackupDate ?? .distantPast) }
    }

    /// Loads Info.plist / Manifest.plist from a single backup folder.
    static func load(backupFolder url: URL) throws -> BackupDevice {
        let fm = FileManager.default
        let infoURL = url.appendingPathComponent("Info.plist")
        let manifestPlistURL = url.appendingPathComponent("Manifest.plist")
        let manifestDBURL = url.appendingPathComponent("Manifest.db")
        let hasManifestDB = fm.fileExists(atPath: manifestDBURL.path)
        let hasMBDB = fm.fileExists(atPath: url.appendingPathComponent("Manifest.mbdb").path)

        guard fm.fileExists(atPath: infoURL.path) || fm.fileExists(atPath: manifestPlistURL.path) || hasManifestDB else {
            throw BackupError.notABackup(url)
        }
        if !hasManifestDB && hasMBDB { throw BackupError.legacyFormat }

        let info = readPlist(infoURL)
        let manifest = readPlist(manifestPlistURL)
        let lockdown = manifest["Lockdown"] as? [String: Any] ?? [:]

        func str(_ key: String) -> String {
            (info[key] as? String) ?? (lockdown[key] as? String) ?? ""
        }
        let apps = (info["Installed Applications"] as? [String]) ?? Array((manifest["Applications"] as? [String: Any])?.keys ?? [:].keys)

        return BackupDevice(
            id: url.lastPathComponent,
            url: url,
            deviceName: str("Device Name").isEmpty ? str("Display Name") : str("Device Name"),
            productType: str("Product Type").isEmpty ? str("ProductType") : str("Product Type"),
            productVersion: str("Product Version").isEmpty ? str("ProductVersion") : str("Product Version"),
            buildVersion: str("Build Version").isEmpty ? str("BuildVersion") : str("Build Version"),
            serialNumber: str("Serial Number").isEmpty ? str("SerialNumber") : str("Serial Number"),
            phoneNumber: str("Phone Number"),
            lastBackupDate: (info["Last Backup Date"] as? Date) ?? (manifest["Date"] as? Date),
            // IsEncrypted is authoritative. ManifestKey only exists when the manifest itself is
            // encrypted, so it's a safe secondary signal. BackupKeyBag is NOT a signal — unencrypted
            // backups also carry a key bag to describe protection classes.
            isEncrypted: ((manifest["IsEncrypted"] as? Bool) ?? ((manifest["IsEncrypted"] as? NSNumber)?.boolValue ?? false))
                || manifest["ManifestKey"] != nil,
            backupVersion: (manifest["Version"] as? String) ?? "",
            installedApps: apps.sorted(),
            hasManifestDB: hasManifestDB
        )
    }

    private static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] ?? [:]
    }

    static func manifestPlist(for device: BackupDevice) -> [String: Any] {
        readPlist(device.url.appendingPathComponent("Manifest.plist"))
    }
}
