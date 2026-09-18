import Foundation
import CommonCrypto

enum Crypto {
    static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int, sha256: Bool) throws -> Data {
        var derived = Data(count: keyLength)
        let algorithm = sha256 ? CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256) : CCPBKDFAlgorithm(kCCPRFHmacAlgSHA1)
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            password.withUnsafeBytes { pw -> Int32 in
                salt.withUnsafeBytes { s -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         algorithm, UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.crypto("PBKDF2 failed (\(status))") }
        return derived
    }

    /// RFC 3394 AES key unwrap. Returns nil if the integrity check fails (i.e. wrong KEK).
    static func aesUnwrap(kek: Data, wrapped: Data) -> Data? {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { return nil }
        var rawLength = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var raw = Data(count: rawLength)
        let status = raw.withUnsafeMutableBytes { out -> Int32 in
            kek.withUnsafeBytes { k -> Int32 in
                wrapped.withUnsafeBytes { w -> Int32 in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES),
                                         CCrfc3394_iv, CCrfc3394_ivLen,
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), kek.count,
                                         w.baseAddress?.assumingMemoryBound(to: UInt8.self), wrapped.count,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), &rawLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return raw.prefix(rawLength)
    }

    /// AES-256-CBC with a zero IV and no padding handling; the caller strips PKCS#7 padding.
    static func aesCBCDecryptNoPadding(key: Data, data: Data) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0 else { throw BackupError.crypto("ciphertext is not block aligned") }
        let outLength = data.count
        var out = Data(count: outLength)
        var moved = 0
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { o -> Int32 in
            key.withUnsafeBytes { k -> Int32 in
                data.withUnsafeBytes { d -> Int32 in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                            k.baseAddress, key.count, iv,
                            d.baseAddress, data.count,
                            o.baseAddress, outLength, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.crypto("AES decrypt failed (\(status))") }
        return stripPKCS7(out.prefix(moved))
    }

    static func stripPKCS7(_ data: Data) -> Data {
        guard let last = data.last, last >= 1, last <= 16, data.count >= Int(last) else { return data }
        let padStart = data.count - Int(last)
        for b in data[padStart...] where b != last { return data }
        return data.prefix(padStart)
    }

    /// Streams an AES-256-CBC (zero IV) decryption from one file to another, stripping PKCS#7 padding at the end.
    static func aesCBCDecryptFile(key: Data, from source: URL, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forUpdating: destination)
        defer { try? output.close() }

        var cryptor: CCCryptorRef?
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let createStatus = key.withUnsafeBytes { k in
            CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, iv, &cryptor)
        }
        guard createStatus == kCCSuccess, let cryptor else { throw BackupError.crypto("could not create cryptor") }
        defer { CCCryptorRelease(cryptor) }

        let chunkSize = 4 * 1024 * 1024
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize + kCCBlockSizeAES128)
        while true {
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var moved = 0
            let status = chunk.withUnsafeBytes { c in
                CCCryptorUpdate(cryptor, c.baseAddress, chunk.count, &buffer, buffer.count, &moved)
            }
            guard status == kCCSuccess else { throw BackupError.crypto("AES update failed (\(status))") }
            if moved > 0 { output.write(Data(bytes: buffer, count: moved)) }
            total += Int64(chunk.count)
            progress?(total)
        }
        var moved = 0
        let finalStatus = CCCryptorFinal(cryptor, &buffer, buffer.count, &moved)
        guard finalStatus == kCCSuccess else { throw BackupError.crypto("AES final failed (\(finalStatus))") }
        if moved > 0 { output.write(Data(bytes: buffer, count: moved)) }

        // Strip PKCS#7 padding by truncating the output file.
        let length = try output.seekToEnd()
        if length >= 1 {
            try output.seek(toOffset: length - 1)
            let lastByte = output.readData(ofLength: 1).first ?? 0
            if lastByte >= 1, lastByte <= 16, UInt64(lastByte) <= length {
                try output.truncate(atOffset: length - UInt64(lastByte))
            }
        }
    }
}

extension Crypto {
    /// AES-256-GCM decrypt with an arbitrary-length IV (Apple keychain items use a 16-byte zero IV).
    /// Returns nil if the authentication tag does not verify.
    /// AES-256 single-block ECB encrypt (used to build GCM).
    private static func aesEncryptBlock(key: Data, _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16); var moved = 0
        _ = key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    k.baseAddress, key.count, nil, block, 16, &out, 16, &moved)
        }
        return out
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var r = a; for i in 0..<min(a.count, b.count) { r[i] ^= b[i] }; return r
    }

    /// GF(2^128) multiply (GCM), big-endian bit order with reduction poly 0xe1.
    private static func gmul(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var z = [UInt8](repeating: 0, count: 16)
        var v = y
        for i in 0..<128 {
            if (x[i >> 3] >> (7 - (i & 7))) & 1 == 1 { z = xor(z, v) }
            let lsb = v[15] & 1
            // v >>= 1
            for j in stride(from: 15, through: 1, by: -1) { v[j] = (v[j] >> 1) | ((v[j-1] & 1) << 7) }
            v[0] >>= 1
            if lsb == 1 { v[0] ^= 0xe1 }
        }
        return z
    }

    private static func ghash(_ h: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)
        var i = 0
        while i < data.count {
            var block = [UInt8](repeating: 0, count: 16)
            let n = min(16, data.count - i)
            for j in 0..<n { block[j] = data[i + j] }
            y = gmul(xor(y, block), h)
            i += 16
        }
        return y
    }

    private static func inc32(_ block: inout [UInt8]) {
        var c = (UInt32(block[12]) << 24) | (UInt32(block[13]) << 16) | (UInt32(block[14]) << 8) | UInt32(block[15])
        c &+= 1
        block[12] = UInt8((c >> 24) & 0xff); block[13] = UInt8((c >> 16) & 0xff)
        block[14] = UInt8((c >> 8) & 0xff); block[15] = UInt8(c & 0xff)
    }

    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - 8 * $0)) & 0xff) } }

    /// AES-256-GCM decrypt with an arbitrary-length IV (Apple keychain items use a 16-byte zero IV).
    /// Returns nil if the authentication tag does not verify. Implemented in Swift because this SDK's
    /// CommonCrypto does not expose GCM.
    static func aesGCMDecrypt(key: Data, iv: Data, ciphertext: Data, tag: Data, aad: Data = Data()) -> Data? {
        let ct = [UInt8](ciphertext), ivb = [UInt8](iv), aadb = [UInt8](aad), tagb = [UInt8](tag)
        let h = aesEncryptBlock(key: key, [UInt8](repeating: 0, count: 16))

        // J0
        var j0 = [UInt8](repeating: 0, count: 16)
        if ivb.count == 12 {
            for i in 0..<12 { j0[i] = ivb[i] }; j0[15] = 1
        } else {
            var s = ghash(h, ivb + [UInt8](repeating: 0, count: (16 - ivb.count % 16) % 16))
            s = gmul(xor(s, be64(0) + be64(UInt64(ivb.count) * 8)), h)
            j0 = s
        }

        // CTR decrypt (keystream from inc32(J0)…)
        var counter = j0; inc32(&counter)
        var pt = [UInt8](repeating: 0, count: ct.count)
        var off = 0
        while off < ct.count {
            let ks = aesEncryptBlock(key: key, counter)
            let n = min(16, ct.count - off)
            for j in 0..<n { pt[off + j] = ct[off + j] ^ ks[j] }
            inc32(&counter)
            off += 16
        }

        // Auth tag: GHASH(H, AAD_pad || CT_pad || [aadBits][ctBits]) XOR E(K, J0)
        var g = aadb
        if g.count % 16 != 0 { g += [UInt8](repeating: 0, count: 16 - g.count % 16) }
        var ctPad = ct
        if ctPad.count % 16 != 0 { ctPad += [UInt8](repeating: 0, count: 16 - ctPad.count % 16) }
        g += ctPad
        g += be64(UInt64(aadb.count) * 8) + be64(UInt64(ct.count) * 8)
        let s = ghash(h, g)
        let computed = xor(s, aesEncryptBlock(key: key, j0))

        // Constant-time compare over the provided tag length.
        guard tagb.count <= 16 else { return nil }
        var diff: UInt8 = 0
        for i in 0..<tagb.count { diff |= computed[i] ^ tagb[i] }
        return diff == 0 ? Data(pt) : nil
    }
}

extension Crypto {
    /// Returns the GCM tag this implementation computes for the given (key, iv, ciphertext, aad).
    static func debugGCMTag(key: Data, iv: Data, ciphertext: Data, aad: Data = Data()) -> [UInt8] {
        let ct = [UInt8](ciphertext), ivb = [UInt8](iv), aadb = [UInt8](aad)
        let h = aesEncryptBlock(key: key, [UInt8](repeating: 0, count: 16))
        var j0 = [UInt8](repeating: 0, count: 16)
        if ivb.count == 12 { for i in 0..<12 { j0[i] = ivb[i] }; j0[15] = 1 }
        else {
            var s = ghash(h, ivb + [UInt8](repeating: 0, count: (16 - ivb.count % 16) % 16))
            s = gmul(xor(s, be64(0) + be64(UInt64(ivb.count) * 8)), h)
            j0 = s
        }
        var g = aadb
        if g.count % 16 != 0 { g += [UInt8](repeating: 0, count: 16 - g.count % 16) }
        var ctPad = ct
        if ctPad.count % 16 != 0 { ctPad += [UInt8](repeating: 0, count: 16 - ctPad.count % 16) }
        g += ctPad
        g += be64(UInt64(aadb.count) * 8) + be64(UInt64(ct.count) * 8)
        return xor(ghash(h, g), aesEncryptBlock(key: key, j0))
    }

    static func debugAESBlock(key: Data, _ block: Data) -> [UInt8] { aesEncryptBlock(key: key, [UInt8](block)) }
    /// GCM decrypt without tag verification (for debugging the keystream/counter path).
    static func debugGCMPlaintext(key: Data, iv: Data, ciphertext: Data) -> [UInt8] {
        let ct = [UInt8](ciphertext), ivb = [UInt8](iv)
        var j0 = [UInt8](repeating: 0, count: 16)
        if ivb.count == 12 { for i in 0..<12 { j0[i] = ivb[i] }; j0[15] = 1 }
        var counter = j0; inc32(&counter)
        var pt = [UInt8](repeating: 0, count: ct.count); var off = 0
        while off < ct.count {
            let ks = aesEncryptBlock(key: key, counter); let n = min(16, ct.count - off)
            for j in 0..<n { pt[off + j] = ct[off + j] ^ ks[j] }
            inc32(&counter); off += 16
        }
        return pt
    }
}
