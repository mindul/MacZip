import Foundation

public struct ZipEntry {
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let method: UInt16
    public let isEncrypted: Bool
    public let usesAES: Bool
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let crc32: UInt32
    public let unixMode: UInt16?
    public let modified: Date

    let flags: UInt16
    let dosTime: UInt16
    let localHeaderOffset: UInt64
}

/// zip 파일을 읽는다. 중앙 디렉터리 기준이며 항목별로 스트리밍 해제한다.
public final class ZipReader {
    public let entries: [ZipEntry]
    public let nameEncoding: NameEncoding

    private let handle: FileHandle
    private let fileSize: UInt64
    private static let readChunk = 256 * 1024

    public init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ZipError.io("열 수 없음: \(url.lastPathComponent)") }
        handle = h
        let size = (try? h.seekToEnd()) ?? 0
        fileSize = size

        // EOCD 찾기
        let tailLen = min(size, 65_557)
        let tail = try Self.read(h, at: size - tailLen, count: Int(tailLen))
        guard tail.count >= 22,
              let eocdRel = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32(at: $0) == ZipSig.end })
        else { throw ZipError.notAZip }
        let eocdPos = size - tailLen + UInt64(eocdRel)
        let count = Int(tail.u16(at: eocdRel + 10))
        let cdSize = UInt64(tail.u32(at: eocdRel + 12))
        let cdOffset = UInt64(tail.u32(at: eocdRel + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.tooLarge("ZIP64") }
        guard cdOffset + cdSize <= eocdPos else { throw ZipError.corrupt("중앙 디렉터리 위치") }

        // 중앙 디렉터리 파싱
        let cd = try Self.read(h, at: cdOffset, count: Int(cdSize))
        struct Raw {
            let raw: RawEntryName; let versionMadeBy: UInt16; let flags: UInt16; let method: UInt16
            let time: UInt16; let date: UInt16; let crc: UInt32; let csize: UInt32; let usize: UInt32
            let external: UInt32; let offset: UInt32; let aes: Bool
        }
        var raws: [Raw] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(at: p) == ZipSig.central else { throw ZipError.corrupt("중앙 디렉터리") }
            let nameLen = Int(cd.u16(at: p + 28)), extraLen = Int(cd.u16(at: p + 30)), commentLen = Int(cd.u16(at: p + 32))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw ZipError.corrupt("중앙 디렉터리") }
            let s = cd.startIndex + p + 46
            let nameBytes = Array(cd[s..<(s + nameLen)])
            let extra = Data(cd[(s + nameLen)..<(s + nameLen + extraLen)])
            let csize = cd.u32(at: p + 20), usize = cd.u32(at: p + 24), offset = cd.u32(at: p + 42)
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw ZipError.tooLarge("ZIP64") }
            let flags = cd.u16(at: p + 8)
            let (unicodePath, aes) = Self.parseExtra(extra)
            raws.append(Raw(raw: RawEntryName(bytes: nameBytes, utf8Flag: flags & ZipFlag.utf8 != 0, unicodePath: unicodePath),
                            versionMadeBy: cd.u16(at: p + 4), flags: flags, method: cd.u16(at: p + 10),
                            time: cd.u16(at: p + 12), date: cd.u16(at: p + 14), crc: cd.u32(at: p + 16),
                            csize: csize, usize: usize, external: cd.u32(at: p + 38), offset: offset, aes: aes))
            p += 46 + nameLen + extraLen + commentLen
        }

        let encoding = FilenameCodec.chooseEncoding(raws.map(\.raw))
        nameEncoding = encoding
        entries = raws.map { r in
            let name = FilenameCodec.decode(r.raw, using: encoding)
            let mode: UInt16? = (r.versionMadeBy >> 8) == 3 && (r.external >> 16) != 0 ? UInt16(r.external >> 16) : nil
            return ZipEntry(
                name: name,
                isDirectory: name.hasSuffix("/") || name.hasSuffix("\\"),
                isSymlink: mode.map { $0 & 0o170000 == 0o120000 } ?? false,
                method: r.method, isEncrypted: r.flags & ZipFlag.encrypted != 0,
                usesAES: r.method == 99 || r.aes,
                compressedSize: UInt64(r.csize), uncompressedSize: UInt64(r.usize), crc32: r.crc,
                unixMode: mode, modified: DosTime.decode(time: r.time, date: r.date),
                flags: r.flags, dosTime: r.time, localHeaderOffset: UInt64(r.offset))
        }
    }

    deinit { try? handle.close() }

    /// 항목 하나를 destination 파일로 푼다. 실패하면 불완전한 파일을 남기지 않는다.
    public func extract(_ entry: ZipEntry, to destination: URL, password: String?,
                        isCancelled: () -> Bool, bytesProcessed: (Int64) -> Void) throws {
        if entry.usesAES { throw ZipError.unsupportedAES(entry: entry.name) }
        if entry.isDirectory {
            do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            catch { throw ZipError.io("폴더를 만들 수 없음: \(entry.name)") }
            return
        }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.method) }

        let local = try Self.read(handle, at: entry.localHeaderOffset, count: 30)
        guard local.count == 30, local.u32(at: 0) == ZipSig.local else { throw ZipError.corrupt("로컬 헤더") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(local.u16(at: 26)) + UInt64(local.u16(at: 28))
        guard dataStart + entry.compressedSize <= fileSize else { throw ZipError.corrupt("데이터 범위") }

        guard entry.isEncrypted else {
            try stream(entry, from: dataStart, length: entry.compressedSize, decryptor: nil,
                       to: destination, isCancelled: isCancelled, bytesProcessed: bytesProcessed)
            return
        }

        guard let password, !password.isEmpty else { throw ZipError.passwordRequired }
        guard entry.compressedSize >= 12 else { throw ZipError.corrupt("암호 헤더") }
        let header = Array(try Self.read(handle, at: dataStart, count: 12))
        let expected = entry.flags & ZipFlag.dataDescriptor != 0
            ? UInt8(truncatingIfNeeded: entry.dosTime >> 8)
            : UInt8(truncatingIfNeeded: entry.crc32 >> 24)
        for candidate in ZipPassword.candidates(password) {
            let dec = ZipCryptoDecryptor(password: candidate, header: header)
            guard dec.checkByte == expected else { continue }
            do {
                try stream(entry, from: dataStart + 12, length: entry.compressedSize - 12, decryptor: dec,
                           to: destination, isCancelled: isCancelled, bytesProcessed: bytesProcessed)
                return
            } catch let e as ZipError {
                switch e {
                case .corrupt, .crcMismatch: continue   // 검사 바이트 우연 일치 → 다음 후보
                default: throw e
                }
            }
        }
        throw ZipError.wrongPassword
    }

    // MARK: - 내부

    private func stream(_ entry: ZipEntry, from start: UInt64, length: UInt64, decryptor: ZipCryptoDecryptor?,
                        to destination: URL, isCancelled: () -> Bool, bytesProcessed: (Int64) -> Void) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination) else {
            throw ZipError.io("만들 수 없음: \(entry.name)")
        }
        var ok = false
        defer {
            try? out.close()
            if !ok { try? fm.removeItem(at: destination) }
        }

        var dec = decryptor
        let inflater = entry.method == 8 ? RawInflater() : nil
        var crc: UInt32 = 0
        func emit(_ d: Data) throws {
            crc = CRC32.update(crc, d)
            do { try out.write(contentsOf: d) } catch { throw ZipError.io("쓰기 실패: \(entry.name)") }
            bytesProcessed(Int64(d.count))
        }

        do { try handle.seek(toOffset: start) } catch { throw ZipError.corrupt("데이터 위치") }
        var remaining = length
        while remaining > 0 {
            if isCancelled() { throw ZipError.cancelled }
            let n = Int(min(remaining, UInt64(Self.readChunk)))
            // FileHandle이 돌려주는 버퍼는 autorelease되므로 반복마다 풀을 비운다.
            try autoreleasepool {
                guard var chunk = try? handle.read(upToCount: n), chunk.count == n else { throw ZipError.corrupt("데이터가 짧음") }
                dec?.decrypt(&chunk)
                if let inflater { try inflater.write(chunk, sink: emit) } else { try emit(chunk) }
            }
            remaining -= UInt64(n)
        }
        if let inflater, !inflater.isFinished { throw ZipError.corrupt("inflate") }
        guard crc == entry.crc32 else { throw ZipError.crcMismatch(entry: entry.name) }

        var attrs: [FileAttributeKey: Any] = [.modificationDate: entry.modified]
        let perms = entry.unixMode.map { Int($0 & 0o777) } ?? 0
        attrs[.posixPermissions] = perms == 0 ? 0o644 : perms
        try? out.close()
        try? fm.setAttributes(attrs, ofItemAtPath: destination.path)
        ok = true
    }

    private static func read(_ h: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        do {
            try h.seek(toOffset: offset)
            return try h.read(upToCount: count) ?? Data()
        } catch {
            throw ZipError.corrupt("읽기 위치")
        }
    }

    /// 확장 필드에서 0x7075(유니코드 경로)와 0x9901(AES) 찾기.
    private static func parseExtra(_ extra: Data) -> ((crc: UInt32, name: String)?, Bool) {
        var p = 0
        var unicodePath: (crc: UInt32, name: String)?
        var aes = false
        while p + 4 <= extra.count {
            let id = extra.u16(at: p), len = Int(extra.u16(at: p + 2))
            guard p + 4 + len <= extra.count else { break }
            if id == 0x9901 { aes = true }
            if id == 0x7075, len >= 5, extra[extra.startIndex + p + 4] == 1 {
                let s = extra.startIndex + p + 9
                if let name = String(bytes: extra[s..<(extra.startIndex + p + 4 + len)], encoding: .utf8) {
                    unicodePath = (extra.u32(at: p + 5), name)
                }
            }
            p += 4 + len
        }
        return (unicodePath, aes)
    }
}
