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
