import Foundation
import UniformTypeIdentifiers

/// A backup folder found on disk (one per device / UDID).
struct BackupDevice: Identifiable, Hashable {
    let id: String              // UDID / folder name
    let url: URL
    let deviceName: String
    let productType: String
    let productVersion: String
    let buildVersion: String
    let serialNumber: String
    let phoneNumber: String
    let lastBackupDate: Date?
    let isEncrypted: Bool
    let backupVersion: String
    let installedApps: [String]
    let hasManifestDB: Bool

    var title: String { deviceName.isEmpty ? id : deviceName }
    var subtitle: String {
        var parts: [String] = []
        if !productType.isEmpty { parts.append(BackupDevice.friendlyModel(productType)) }
        if !productVersion.isEmpty { parts.append("iOS \(productVersion)") }
        return parts.joined(separator: " · ")
    }

    static func friendlyModel(_ productType: String) -> String {
        let map: [String: String] = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd gen)", "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd gen)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        ]
        return map[productType] ?? productType
    }
}

/// One row from Manifest.db's Files table.
struct BackupFile: Identifiable, Hashable {
    let id: String              // fileID (SHA1 of "domain-relativePath")
    let domain: String
    let relativePath: String
    let flags: Int              // 1 = file, 2 = directory, 4 = symlink
    var size: Int64
    var modified: Date?
    var protectionClass: Int
    var encryptionKey: Data?    // wrapped per-file key (class prefix stripped), encrypted backups only

    var isDirectory: Bool { flags == 2 }
    var isRegularFile: Bool { flags == 1 }
    var fileName: String { (relativePath as NSString).lastPathComponent }
    var fileExtension: String { (relativePath as NSString).pathExtension.lowercased() }
    var utType: UTType? { fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension) }
    var category: FileCategory { FileCategory.categorize(self) }
    var domainDisplayName: String { DomainInfo.displayName(for: domain) }

    /// Location of the raw (possibly encrypted) blob inside the backup folder.
    func storageURL(in backupURL: URL) -> URL {
        backupURL.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
    }
}

enum FileCategory: String, CaseIterable, Identifiable {
    case all = "All Files"
    case media = "Photos & Videos"
    case photos = "Photos"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case databases = "Databases"
    case plists = "Property Lists"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "doc.on.doc"
        case .media: return "photo.on.rectangle.angled"
        case .photos: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .databases: return "cylinder"
        case .plists: return "list.bullet.rectangle"
        case .other: return "questionmark.folder"
        }
    }

    /// True for categories that should offer the thumbnail grid.
    var isMedia: Bool { self == .photos || self == .videos || self == .media }

    /// Does a file in `category` belong under this filter? `.media` matches photos and videos.
    func matches(_ category: FileCategory) -> Bool {
        switch self {
        case .all: return true
        case .media: return category == .photos || category == .videos
        default: return category == self
        }
    }

    static func categorize(_ file: BackupFile) -> FileCategory {
        let ext = file.fileExtension
        switch ext {
        case "sqlite", "sqlitedb", "db", "sqlite3", "sqlite-wal", "sqlite-shm", "db-wal", "db-shm":
            return .databases
        case "plist":
            return .plists
        case "pdf", "txt", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote", "csv", "json", "xml", "html", "md", "vcf", "ics":
            return .documents
        default:
            break
        }
        if let type = file.utType {
            if type.conforms(to: .image) { return .photos }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .text) || type.conforms(to: .pdf) { return .documents }
        }
        return .other
    }
}

enum DomainInfo {
    static func displayName(for domain: String) -> String {
        switch domain {
        case "CameraRollDomain": return "Camera Roll"
        case "MediaDomain": return "Media"
        case "HomeDomain": return "Home"
        case "RootDomain": return "Root"
        case "WirelessDomain": return "Wireless"
        case "WifiDomain": return "Wi-Fi"
        case "KeychainDomain": return "Keychain"
        case "SystemPreferencesDomain": return "System Preferences"
        case "ManagedPreferencesDomain": return "Managed Preferences"
        case "MobileDeviceDomain": return "Mobile Device"
        case "DatabaseDomain": return "Database"
        case "HealthDomain": return "Health"
        case "HomeKitDomain": return "HomeKit"
        case "InstallDomain": return "Install"
        case "KeyboardDomain": return "Keyboard"
        case "NetworkDomain": return "Network"
        case "TonesDomain": return "Ringtones"
        case "BooksDomain": return "Books"
        case "ProtectedDomain": return "Protected"
        default:
            if domain.hasPrefix("AppDomain-") { return "App: " + domain.dropFirst("AppDomain-".count) }
            if domain.hasPrefix("AppDomainGroup-") { return "App Group: " + domain.dropFirst("AppDomainGroup-".count) }
            if domain.hasPrefix("AppDomainPlugin-") { return "App Plugin: " + domain.dropFirst("AppDomainPlugin-".count) }
            if domain.hasPrefix("SysContainerDomain-") { return "System Container: " + domain.dropFirst("SysContainerDomain-".count) }
            if domain.hasPrefix("SysSharedContainerDomain-") { return "System Shared: " + domain.dropFirst("SysSharedContainerDomain-".count) }
            return domain
        }
    }

    static func systemImage(for domain: String) -> String {
        switch domain {
        case "CameraRollDomain": return "camera"
        case "MediaDomain": return "photo.on.rectangle"
        case "HomeDomain": return "house"
        case "HealthDomain": return "heart"
        case "KeychainDomain": return "key"
        case "WifiDomain", "WirelessDomain", "NetworkDomain": return "wifi"
        case "TonesDomain": return "bell"
        case "BooksDomain": return "book"
        default:
            if domain.hasPrefix("AppDomain") { return "app" }
            if domain.hasPrefix("Sys") { return "gearshape" }
            return "folder"
        }
    }
}

struct DomainSummary: Identifiable, Hashable {
    let domain: String
    let fileCount: Int
    let totalSize: Int64
    var id: String { domain }
    var displayName: String { DomainInfo.displayName(for: domain) }
}

enum BackupError: LocalizedError {
    case permissionDenied(URL)
    case notABackup(URL)
    case legacyFormat
    case manifestMissing
    case encryptedNeedsPassword
    case wrongPassword
    case keybagMissing
    case classKeyUnavailable(Int)
    case sqlite(String)
    case notADatabase(Data)
    case crypto(String)
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return "macOS blocked access to \(url.path). Grant Full Disk Access to iPhone Backup Explorer in System Settings → Privacy & Security, or choose the backup folder manually."
        case .notABackup(let url):
            return "\(url.lastPathComponent) does not look like an iPhone backup (no Manifest.db / Info.plist found)."
        case .legacyFormat:
            return "This backup uses the legacy Manifest.mbdb format (iOS 9 and earlier) which is not supported."
        case .manifestMissing:
            return "Manifest.db is missing from this backup."
        case .encryptedNeedsPassword:
            return "This backup is encrypted. Enter the backup password to open it."
        case .wrongPassword:
            return "The password is incorrect."
        case .keybagMissing:
            return "The backup is marked encrypted but contains no key bag."
        case .classKeyUnavailable(let c):
            return "The key for protection class \(c) is not available in this backup."
        case .sqlite(let msg):
            return "Database error: \(msg)"
        case .notADatabase(let header):
            let hex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(decoding: header, as: UTF8.self).filter { $0.isASCII && !$0.isNewline }
            return "Manifest.db is not a valid SQLite database and does not look encrypted. Its first bytes are: \(hex) “\(ascii)”. The backup may be incomplete or corrupted."
        case .crypto(let msg):
            return "Decryption failed: \(msg)"
        case .fileMissing(let id):
            return "The file's data (\(id)) is missing from the backup folder."
        }
    }
}
