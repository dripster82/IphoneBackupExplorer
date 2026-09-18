import Foundation
import AppKit
import CryptoKit

/// Headless helpers driven by launch arguments.
///  -selfTest <backupFolder> [-password <pw>] [-out <dir>]   full open + optional export
///  -diagnose <backupFolder> [-diagOut <file>]               write a diagnosis of why a backup won't open
enum SelfTest {
    static func runIfRequested() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "gcmTest") {
            func hex(_ s: String) -> Data { var d = Data(); var i = s.startIndex
                while i < s.endIndex { let n = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<n], radix: 16)!); i = n }; return d }
            let key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
            let iv = hex("cafebabefacedbaddecaf888")
            let ct = hex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662")
            let tag = hex("b094dac5d93471bdec1a502270e3cc6c")
            // ECB block KAT (AES-256): confirms the block cipher helper.
            let ecbKey = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
            let ecbOut = Crypto.debugAESBlock(key: ecbKey, hex("6bc1bee22e409f96e93d7e117393172a"))
            print("ECB KAT: \(ecbOut.map { String(format: "%02x", $0) }.joined()) expected f3eed1bdb5d2a03c064b5a7e3db181f8")
            let pt = Crypto.aesGCMDecrypt(key: key, iv: iv, ciphertext: ct, tag: tag)
            print("GCM KAT (256,noAAD): \(pt != nil ? "PASS" : "FAIL")")
            // GCM Test Case 4 (AES-128, with AAD)
            let tc4 = Crypto.aesGCMDecrypt(
                key: hex("feffe9928665731c6d6a8f9467308308"),
                iv: hex("cafebabefacedbaddecaf888"),
                ciphertext: hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"),
                tag: hex("5bc94fbc3221a5db94fae95ae7121a47"),
                aad: hex("feedfacedeadbeeffeedfacedeadbeefabaddad2"))
            print("GCM KAT (128,AAD): \(tc4 != nil ? "PASS" : "FAIL")")
            // GCM Test Case 6 (AES-128, 60-byte IV → exercises the non-96-bit J0/GHASH path)
            let tc6 = Crypto.aesGCMDecrypt(
                key: hex("feffe9928665731c6d6a8f9467308308"),
                iv: hex("9313225df88406e555909c5aff5269aa6a7a9538534f7da1e4c303d2a318a728c3c0c95156809539fcf0e2429a6b525416aedbf5a0de6a57a637b39b"),
                ciphertext: hex("8ce24998625615b603a033aca13fb894be9112a5c3a211a8ba262a3cca7e2ca701e4a9a4fba43c90ccdcb281d48c7c6fd62875d2aca417034c34aee5"),
                tag: hex("619cc5aefffe0bfa462af43c1699d050"),
                aad: hex("feedfacedeadbeeffeedfacedeadbeefabaddad2"))
            print("GCM KAT (128,longIV): \(tc6 != nil ? "PASS" : "FAIL")")
            let ptNoVerify = Crypto.debugGCMPlaintext(key: key, iv: iv, ciphertext: ct)
            print("GCM PT (no verify) head: \(ptNoVerify.prefix(16).map { String(format: "%02x", $0) }.joined()) expected d9313225f88406e5a55909c5aff5269a")
            exit(0)
        }
        if let folder = defaults.string(forKey: "diagnose"), !folder.isEmpty {
            diagnose(folder: folder, out: defaults.string(forKey: "diagOut"))
        }
        if defaults.bool(forKey: "diagnosePick") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = "Select the backup folder to diagnose"
            panel.prompt = "Diagnose"
            if panel.runModal() == .OK, let url = panel.url {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                diagnose(folder: url.path, out: defaults.string(forKey: "diagOut"))
            } else {
                exit(0)
            }
        }
        if let list = defaults.string(forKey: "parseWifi"), !list.isEmpty {
            let urls = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            let recs = WiFiStore.networks(from: urls)
            print("wifi networks: \(recs.count)")
            for r in recs.prefix(15) { print("  • \(r.title) | \(r.subtitle)") }
            exit(0)
        }
        if let folder = defaults.string(forKey: "keychainProbe"), !folder.isEmpty {
            do {
                var pw = defaults.string(forKey: "password")
                if let pf = defaults.string(forKey: "passwordFile"),
                   let s = try? String(contentsOfFile: pf, encoding: .utf8) { pw = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                let device = try BackupLocator.load(backupFolder: URL(fileURLWithPath: folder))
                print("encrypted=\(device.isEncrypted)")
                let session = try BackupSession(device: device, password: pw)
                let files = try session.loadFiles()
                guard let kc = files.first(where: { $0.relativePath == "keychain-backup.plist" }) else { print("no keychain-backup.plist"); exit(1) }
                let data = try session.contents(of: kc)
                guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { print("keychain not a plist (len \(data.count))"); exit(1) }
                print("keychain sections: \(plist.keys.sorted())")
                let kcRecords = KeychainStore.records(from: data, session: session)
                print("=== KEYCHAIN DataRecords: \(kcRecords.count) (sample) ===")
                for r in kcRecords.prefix(4) { print("  \(r.title) | \(r.subtitle) | fields=\(r.fields.map { $0.label })") }
                let kcItems = KeychainStore.load(from: data, session: session)
                print("=== DECODED KEYCHAIN ITEMS: \(kcItems.count) ===")
                for it in kcItems.prefix(25) {
                    var secret = "-"
                    if let s = it.secret { secret = s.count > 40 ? String(s.prefix(40)) + "…" : s }
                    else if let d = it.secretData { secret = "<\(d.count) bytes>" }
                    print("  [\(it.kind.rawValue)] acct=\(it.account ?? "-") svc=\(it.service ?? "-") secret=\(secret)")
                }
                // Full attribute dump for the first AirPort (Wi-Fi) item, to locate the password field.
                let airLive = kcItems.filter { $0.service == "AirPort" && ($0.secret != nil || $0.secretData != nil) }
                print("  AirPort items with a password: \(airLive.count) of \(kcItems.filter { $0.service == "AirPort" }.count)")
                for a in airLive.prefix(6) { print("      wifi \(a.account ?? "?") → \(a.secret ?? a.secretData.map { "<\($0.count)b>" } ?? "-")") }
                if let air = kcItems.first(where: { $0.service == "AirPort" }) {
                    print("  --- AirPort item attributes (acct=\(air.account ?? "-")) ---")
                    for (k, v) in air.attributes { print("      \(k) = \(v.prefix(60))") }
                }
                for section in ["genp", "inet"] {
                    guard let items = plist[section] as? [[String: Any]] else { continue }
                    print("\(section): \(items.count) items")
                    if let it = items.first {
                        print("  item keys: \(it.keys.sorted())")
                        if let v = it["v_Data"] as? Data, v.count >= 12 {
                            func le32(_ o: Int) -> UInt32 { v.subdata(in: o..<o+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
                            let clas = Int(le32(4)), wrapLen = Int(le32(8))
                            print("  v_Data: \(v.count) bytes version=\(le32(0)) class=\(clas) wrapLen=\(wrapLen)")
                            let wrapped = v.subdata(in: 12..<12+wrapLen)
                            let ct = v.subdata(in: 12+wrapLen..<v.count)
                            let pref = (it["v_PersistentRef"] as? Data) ?? Data()
                            print("  ct \(ct.count) bytes head: \(ct.prefix(24).map { String(format: "%02x", $0) }.joined())")
                            print("  ct tail: \(ct.suffix(24).map { String(format: "%02x", $0) }.joined())")
                            print("  persistentRef \(pref.count) bytes: \(pref.map { String(format: "%02x", $0) }.joined())")
                            if let key = session.keychainUnwrap(protectionClass: clas, wrappedKey: wrapped) {
                                print("  unwrapped item key: \(key.count) bytes")
                                probeGCM(key: key, ct: ct, header: v.subdata(in: 0..<12), wrapped: wrapped, pref: pref)
                            } else { print("  KEY UNWRAP FAILED for class \(clas)") }
                        }
                        // are attributes plaintext here (unlike the unencrypted backup)?
                        for k in ["acct", "svce", "srvr"] where it[k] != nil { print("  plaintext \(k): present") }
                    }
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let folder = defaults.string(forKey: "listExplore"), !folder.isEmpty {
            do {
                let device = try BackupLocator.load(backupFolder: URL(fileURLWithPath: folder))
                let session = try BackupSession(device: device, password: defaults.string(forKey: "password"))
                let files = try session.loadFiles()
                print("files: \(files.count)")
                func has(_ suffix: String) -> Bool { files.contains { $0.isRegularFile && $0.relativePath.hasSuffix(suffix) } }
                print("contacts file: \(has("AddressBook.sqlitedb"))")
                print("messages file: \(has("SMS/sms.db"))")
                for kind in DataKind.allCases where has(kind.pathSuffix) {
                    print("explore kind available: \(kind.rawValue) (\(kind.title))")
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let raw = defaults.string(forKey: "parseData"), !raw.isEmpty,
           let db = defaults.string(forKey: "db"), !db.isEmpty {
            if raw == "remindersModern" {
                let recs = ExploreParser.remindersModern(url: URL(fileURLWithPath: db))
                print("remindersModern: \(recs.count) records")
                for r in recs.prefix(8) { print("  • \(r.title) | \(r.subtitle)") }
                exit(0)
            }
            guard let kind = DataKind(rawValue: raw) else { print("unknown kind \(raw)"); exit(1) }
            do {
                let recs = try ExploreParser.parse(kind, url: URL(fileURLWithPath: db), resolver: nil)
                print("\(kind.title): \(recs.count) records")
                let withAlbum = recs.filter { $0.fields.contains { $0.label == "Album" } }
                if !withAlbum.isEmpty {
                    print("  records in albums: \(withAlbum.count); sample: \(withAlbum.first!.title) → \(withAlbum.first!.fields.first { $0.label == "Album" }!.value)")
                }
                for r in recs.prefix(12) {
                    print("  • \(r.title) | \(r.subtitle)")
                    for f in r.fields where !["Username","Type"].contains(f.label) { print("        \(f.label): \(f.value)") }
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if defaults.bool(forKey: "checkUpdate") {
            let current = defaults.string(forKey: "asVersion") ?? "1.0.0"
            let sem = DispatchSemaphore(value: 0)
            Task {
                defer { sem.signal() }
                struct GHAsset: Decodable { let name: String; let browser_download_url: String }
                struct GHRelease: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let assets: [GHAsset] }
                let url = URL(string: "https://api.github.com/repos/dripster82/IphoneBackupExplorer/releases?per_page=30")!
                var req = URLRequest(url: url); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    print("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    let releases = try JSONDecoder().decode([GHRelease].self, from: data)
                    let cur = AppVersion(current)!
                    for r in releases {
                        let v = AppVersion(r.tag_name)
                        print("  release \(r.tag_name) -> parsed \(v?.raw ?? "nil") channel=\(v.map { "\($0.channel)" } ?? "-") draft=\(r.draft) assets=\(r.assets.map(\.name))")
                    }
                    let best = releases.compactMap { r -> (AppVersion, GHRelease)? in
                        guard !r.draft, let v = AppVersion(r.tag_name) else { return nil }; return (v, r)
                    }.max(by: { $0.0 < $1.0 })
                    if let best {
                        let asset = Updater.pickDMGAsset(best.1.assets.map { ($0.name, $0.browser_download_url) })
                        print("current=\(current) best=\(best.0.raw) newer=\(cur < best.0) dmg=\(asset?.lastPathComponent ?? "none")")
                    } else { print("no candidate releases") }
                } catch { print("ERROR: \(error.localizedDescription)") }
            }
            sem.wait()
            exit(0)
        }
        if let db = defaults.string(forKey: "parseContacts"), !db.isEmpty {
            do {
                let contacts = try ContactsStore.load(from: URL(fileURLWithPath: db))
                print("contacts: \(contacts.count)")
                for c in contacts.prefix(10) { print("  \(c.fullName) | phones=\(c.phones) emails=\(c.emails) org=\(c.organization)") }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let db = defaults.string(forKey: "parseWhatsApp"), !db.isEmpty {
            do {
                var convos = try WhatsAppStore.load(from: URL(fileURLWithPath: db), resolver: nil)
                if let ab = defaults.string(forKey: "withContacts"), !ab.isEmpty {
                    let contacts = try ContactsStore.load(from: URL(fileURLWithPath: ab))
                    convos = try WhatsAppStore.load(from: URL(fileURLWithPath: db), resolver: ContactResolver(contacts))
                }
                print("whatsapp conversations: \(convos.count)")
                for c in convos.prefix(8) {
                    print("  [\(c.name)] msgs=\(c.messages.count) last=\(c.lastDate.map { "\($0)" } ?? "-")")
                    for m in c.messages.suffix(2) { print("      \(m.sender): \(m.text.prefix(50))") }
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let db = defaults.string(forKey: "parseMessages"), !db.isEmpty {
            do {
                var convos = try MessagesStore.load(from: URL(fileURLWithPath: db))
                if let ab = defaults.string(forKey: "withContacts"), !ab.isEmpty {
                    let contacts = try ContactsStore.load(from: URL(fileURLWithPath: ab))
                    convos = MessagesStore.resolve(convos, with: ContactResolver(contacts))
                    print("(resolved against \(contacts.count) contacts)")
                }
                print("conversations: \(convos.count)")
                for c in convos.prefix(10) {
                    print("  [\(c.name)] handles=\(c.handles) msgs=\(c.messages.count) last=\(c.lastDate.map { "\($0)" } ?? "-")")
                    for m in c.messages.prefix(4) { print("      \(m.isFromMe ? "Me" : m.sender): \(m.text)") }
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        guard let folder = defaults.string(forKey: "selfTest"), !folder.isEmpty else { return }
        let password = defaults.string(forKey: "password")
        let out = defaults.string(forKey: "out").map { URL(fileURLWithPath: $0) }
        do {
            let device = try BackupLocator.load(backupFolder: URL(fileURLWithPath: folder))
            print("device: \(device.title) \(device.subtitle) encrypted=\(device.isEncrypted) apps=\(device.installedApps.count)")
            let session = try BackupSession(device: device, password: password)
            let files = try session.loadFiles()
            print("files: \(files.count)")
            for f in files.sorted(by: { $0.relativePath < $1.relativePath }) {
                print("  [\(f.isDirectory ? "D" : "F")] \(f.domain) \(f.relativePath) size=\(f.size) cat=\(f.category.rawValue) class=\(f.protectionClass) key=\(f.encryptionKey?.count ?? 0)")
            }
            if let out {
                let regular = files.filter(\.isRegularFile)
                let result = Exporter.export(files: regular, from: session, to: out, options: ExportOptions(), isCancelled: { false }, progress: { _ in })
                print("exported: \(result.completed - result.failures.count)/\(result.total)")
                for (f, e) in result.failures { print("  FAIL \(f.relativePath): \(e.localizedDescription)") }
            }
            exit(0)
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Try candidate AES-GCM layouts on a keychain item's ciphertext; report which yields a plist.
    static func probeGCM(key fullKey: Data, ct: Data, header: Data, wrapped: Data, pref: Data = Data()) {
        // DECISIVE: dump unverified plaintext. GCM confidentiality depends only on key+IV,
        // not AAD. If any of these yields bplist00 / recognisable structure, the key & IV are
        // correct and only the tag's AAD is unknown.
        func dump(_ label: String, key: Data, iv: Data, body: Data) {
            let pt = Crypto.debugGCMPlaintext(key: key, iv: iv, ciphertext: body)
            let head = pt.prefix(32)
            let hex = head.map { String(format: "%02x", $0) }.joined()
            let asc = String(head.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            print("    [noverify] \(label): \(asc)  | \(hex)")
        }
        if ct.count > 16 {
            let bodyEnd = ct.subdata(in: 0..<ct.count-16)   // tag assumed at end
            dump("k32 iv16zero tag@end", key: fullKey, iv: Data(count: 16), body: bodyEnd)
        }
        // Layout is now KNOWN (iv=16 zero, body=ct[..<n-16], tag=ct[n-16..]). Find the AAD:
        // try every prefix of (version||class||wraplen||wrapped) and a few external candidates.
        if ct.count > 16 {
            let iv = Data(count: 16)
            let body = ct.subdata(in: 0..<ct.count-16)
            let tag = ct.subdata(in: ct.count-16..<ct.count)
            let blobHdr = header + wrapped     // 12 + 40 = 52 bytes
            var candidates: [(String, Data)] = []
            for n in 0...blobHdr.count { candidates.append(("hdrPrefix(\(n))", blobHdr.prefix(n))) }
            candidates.append(("pref20", pref))
            candidates.append(("prefUUID16", Data(pref.suffix(16))))
            candidates.append(("hdr12+pref20", header + pref))
            for (name, aad) in candidates {
                if Crypto.aesGCMDecrypt(key: fullKey, iv: iv, ciphertext: body, tag: tag, aad: aad) != nil {
                    print("    ★★★ TAG VERIFIED with AAD=\(name) (\(aad.count) bytes) ★★★")
                }
            }
            print("    (aad search done)")
            for ivLen in [0, 12, 16] {
                let testIV = Data(count: ivLen)
                let pt = Crypto.debugGCMPlaintext(key: fullKey, iv: testIV, ciphertext: body)
                let asc = String(pt.prefix(16).map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
                let verified = Crypto.aesGCMDecrypt(key: fullKey, iv: testIV, ciphertext: body, tag: tag, aad: Data()) != nil
                print("    iv=\(ivLen)zero emptyAAD: pt=\"\(asc)\" tagVerified=\(verified)")
            }
            let storedTag = tag.map { String(format: "%02x", $0) }.joined()
            print("    stored tag:       \(storedTag)")
            for (nm, aad) in [("empty", Data()), ("hdr52", blobHdr)] {
                let t = Crypto.debugGCMTag(key: fullKey, iv: iv, ciphertext: body, aad: aad)
                print("    computed(\(nm)):  \(t.map { String(format: "%02x", $0) }.joined())")
            }
            // Is the last 16 bytes maybe padding and the true tag elsewhere? show DER length.
            let ptFull = Crypto.debugGCMPlaintext(key: fullKey, iv: iv, ciphertext: ct)
            print("    full-ct pt len \(ptFull.count) tail16: \(ptFull.suffix(16).map { String(format: "%02x", $0) }.joined())")
            return
        }
        let keyVariants: [(String, Data)] = [("k32", fullKey), ("k16first", fullKey.prefix(16)), ("k16last", fullKey.suffix(16))]
      for (kn, key) in keyVariants {
        func tryLayout(_ label0: String, iv: Data, body: Data, tag: Data, aad: Data) {
            let label = "\(kn) \(label0)"
            if let pt = Crypto.aesGCMDecrypt(key: key, iv: iv, ciphertext: body, tag: tag, aad: aad) {
                let magic = String(decoding: pt.prefix(8), as: UTF8.self).filter { $0.isASCII }
                print("    ✓ \(label): \(pt.count) bytes, starts \"\(magic)\"")
                if let obj = try? PropertyListSerialization.propertyList(from: pt, options: [], format: nil) as? [String: Any] {
                    print("      plist keys: \(obj.keys.sorted())")
                }
            }
        }
        guard ct.count > 16 else { return }
        let tagEnd = ct.subdata(in: ct.count-16..<ct.count)
        let bodyEnd = ct.subdata(in: 0..<ct.count-16)
        let tagFront = ct.subdata(in: 0..<16)
        let bodyFront = ct.subdata(in: 16..<ct.count)
        let aads: [(String, Data)] = [("noAAD", Data()),
                                      ("aad8", header.subdata(in: 0..<8)),
                                      ("aad12", header),
                                      ("aadHdr+wrapped", header + wrapped),
                                      ("aad8+wrapped", header.subdata(in: 0..<8) + wrapped),
                                      ("aadPref", pref),
                                      ("aadHdr+pref", header + pref)]
        for (an, aad) in aads {
            for ivLen in [16, 12] {
                tryLayout("iv=\(ivLen)zero tag@end \(an)", iv: Data(count: ivLen), body: bodyEnd, tag: tagEnd, aad: aad)
                tryLayout("iv=\(ivLen)zero tag@front \(an)", iv: Data(count: ivLen), body: bodyFront, tag: tagFront, aad: aad)
            }
            // embedded IV at front (12 or 16 bytes), tag at end
            if ct.count > 12+16 {
                tryLayout("iv=embed12 tag@end \(an)", iv: ct.subdata(in: 0..<12), body: ct.subdata(in: 12..<ct.count-16), tag: tagEnd, aad: aad)
            }
            if ct.count > 16+16 {
                tryLayout("iv=embed16 tag@end \(an)", iv: ct.subdata(in: 0..<16), body: ct.subdata(in: 16..<ct.count-16), tag: tagEnd, aad: aad)
            }
            // per-item IV = persistent-ref UUID (last 16 bytes of pref)
            if pref.count >= 16 {
                let uuid = pref.suffix(16)
                tryLayout("iv=prefUUID tag@end \(an)", iv: Data(uuid), body: bodyEnd, tag: tagEnd, aad: aad)
                tryLayout("iv=prefUUID tag@front \(an)", iv: Data(uuid), body: bodyFront, tag: tagFront, aad: aad)
            }
        }
      }
        print("    (probe done)")
    }

    /// Produces a plain-text diagnosis without needing a password, and writes it to `out` (or stdout).
    private static func diagnose(folder: String, out: String?) {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }
        let url = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        log("Backup folder: \(folder)")
        log("Readable: \(fm.isReadableFile(atPath: folder))")

        for name in ["Manifest.db", "Manifest.plist", "Info.plist", "Status.plist", "Manifest.mbdb", "Manifest.db-wal", "Manifest.db-shm"] {
            let p = url.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: p) {
                log("  \(name): \(attrs[.size] as? Int ?? -1) bytes")
            }
        }

        let manifestDB = url.appendingPathComponent("Manifest.db")
        if let handle = try? FileHandle(forReadingFrom: manifestDB) {
            let header = handle.readData(ofLength: 16)
            try? handle.close()
            let hex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(decoding: header, as: UTF8.self).map { $0.isASCII && $0 != "\0" ? $0 : "." }
            log("Manifest.db header hex : \(hex)")
            log("Manifest.db header text: \(String(ascii))")
            log("Looks like SQLite      : \(header.starts(with: Data("SQLite format 3".utf8)))")
        } else {
            log("Manifest.db: could not open for reading (permission or missing)")
        }

        let mpData = (try? Data(contentsOf: url.appendingPathComponent("Manifest.plist"))) ?? Data()
        let mp = ((try? PropertyListSerialization.propertyList(from: mpData, options: [], format: nil)) as? [String: Any]) ?? [:]
        if mp.isEmpty {
            log("Manifest.plist: empty or unreadable")
        } else {
            log("Manifest.plist IsEncrypted : \(mp["IsEncrypted"].map { "\($0)" } ?? "absent")")
            log("Manifest.plist Version     : \(mp["Version"].map { "\($0)" } ?? "absent")")
            log("Manifest.plist BackupKeyBag: \((mp["BackupKeyBag"] as? Data)?.count.description ?? "absent") bytes")
            log("Manifest.plist ManifestKey : \((mp["ManifestKey"] as? Data)?.count.description ?? "absent") bytes")
        }

        do {
            let device = try BackupLocator.load(backupFolder: url)
            log("Parsed device: \(device.title) | \(device.subtitle) | encrypted=\(device.isEncrypted)")
        } catch {
            log("Parse Info/Manifest: ERROR \(error.localizedDescription)")
        }

        // Try opening without a password to reproduce the DB error the UI shows.
        do {
            let device = try BackupLocator.load(backupFolder: url)
            let session = try BackupSession(device: device, password: nil)
            let files = try session.loadFiles()
            log("Open (no password): SUCCESS, \(files.count) files")
        } catch {
            log("Open (no password): \(error.localizedDescription)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        if let out {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
        print(text)
        exit(0)
    }
}
