import Foundation

/// Parses the BackupKeyBag blob from Manifest.plist and unwraps class keys with the backup password.
final class Keybag {
    private struct ClassKey {
        var uuid: Data?
        var clas: UInt32 = 0
        var wrap: UInt32 = 0
        var wpky: Data?
        var key: Data?
    }

    private var attributes: [String: Data] = [:]
    private var classKeys: [UInt32: ClassKey] = [:]
    private(set) var isUnlocked = false

    init(data: Data) throws {
        var offset = 0
        var current: ClassKey?
        var sawKeybagUUID = false
        var sawKeybagWRAP = false
        while offset + 8 <= data.count {
            let tag = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = Int(Keybag.be32(data, offset + 4))
            offset += 8
            guard offset + length <= data.count else { break }
            let value = data[offset..<offset + length]
            offset += length

            switch tag {
            case "UUID" where !sawKeybagUUID:
                sawKeybagUUID = true
                attributes[tag] = Data(value)
            case "WRAP" where !sawKeybagWRAP && current == nil:
                sawKeybagWRAP = true
                attributes[tag] = Data(value)
            case "UUID":
                if let c = current { classKeys[c.clas & 0xF] = c }
                current = ClassKey(uuid: Data(value))
            case "CLAS":
                current?.clas = Keybag.be32(value, value.startIndex)
            case "WRAP":
                current?.wrap = Keybag.be32(value, value.startIndex)
            case "WPKY":
                current?.wpky = Data(value)
            case "KTYP", "PBKY":
                break
            default:
                attributes[tag] = Data(value)
            }
        }
        if let c = current { classKeys[c.clas & 0xF] = c }
        guard attributes["SALT"] != nil, attributes["ITER"] != nil else {
            throw BackupError.crypto("key bag is missing SALT/ITER")
        }
    }

    /// Derives the passcode key and unwraps every class key wrapped with it. Throws `.wrongPassword` on failure.
    func unlock(password: String) throws {
        guard let salt = attributes["SALT"], let iterData = attributes["ITER"] else { throw BackupError.keybagMissing }
        let iterations = Int(Keybag.be32(iterData, iterData.startIndex))
        var passcodeKey = Data(password.utf8)
        if let dpsl = attributes["DPSL"], let dpicData = attributes["DPIC"] {
            let dpic = Int(Keybag.be32(dpicData, dpicData.startIndex))
            passcodeKey = try Crypto.pbkdf2(password: passcodeKey, salt: dpsl, iterations: dpic, keyLength: 32, sha256: true)
        }
        passcodeKey = try Crypto.pbkdf2(password: passcodeKey, salt: salt, iterations: iterations, keyLength: 32, sha256: false)

        var unlocked = classKeys
        for (clas, var ck) in classKeys {
            guard let wpky = ck.wpky else { continue }
            if ck.wrap & 2 != 0 {
                guard let key = Crypto.aesUnwrap(kek: passcodeKey, wrapped: wpky) else { throw BackupError.wrongPassword }
                ck.key = key
                unlocked[clas] = ck
            }
        }
        classKeys = unlocked
        isUnlocked = true
    }

    /// Unwraps a per-file (or manifest) key that was wrapped with the given protection class key.
    func unwrapKey(protectionClass: Int, wrappedKey: Data) throws -> Data {
        guard let ck = classKeys[UInt32(protectionClass) & 0xF], let classKey = ck.key else {
            throw BackupError.classKeyUnavailable(protectionClass)
        }
        guard wrappedKey.count == 0x28 else { throw BackupError.crypto("wrapped key has unexpected length \(wrappedKey.count)") }
        guard let key = Crypto.aesUnwrap(kek: classKey, wrapped: wrappedKey) else {
            throw BackupError.crypto("could not unwrap key for class \(protectionClass)")
        }
        return key
    }

    private static func be32(_ data: Data, _ index: Int) -> UInt32 {
        guard index + 4 <= data.endIndex else { return 0 }
        return data[index..<index + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
