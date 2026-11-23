import Foundation

/// zip 파일을 순차적으로 쓴다. 이름은 NFC + UTF-8 플래그, 파일 항목은 데이터 디스크립터 사용.
public final class ZipWriter {
    public static let storedExtensions: Set<String> = [
        "zip", "jpg", "jpeg", "png", "gif", "heic", "mp3", "mp4", "mov", "m4a",
        "7z", "rar", "gz", "bz2", "xz", "pdf",
    ]

    private static let readChunk = 256 * 1024
    private static let versionMadeBy: UInt16 = (3 << 8) | 20   // 유닉스, 2.0
    private static let versionNeeded: UInt16 = 20

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0

    public init(destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let h = try? FileHandle(forWritingTo: destination) else {
            throw ZipError.io("만들 수 없음: \(destination.lastPathComponent)")
        }
        handle = h
    }

    deinit { try? handle.close() }

    public func addDirectory(entryName: String, modified: Date, unixMode: UInt16) throws {
        var name = FilenameCodec.normalizeForArchive(entryName)
        if !name.hasSuffix("/") { name += "/" }
        let nameBytes = Data(name.utf8)
        let (t, d) = DosTime.encode(modified)
        let localOffset = offset
        try writeLocalHeader(flags: ZipFlag.utf8, method: 0, time: t, date: d, name: nameBytes)
        let mode = UInt32(unixMode & 0o7777) | 0o040000
        try appendCentral(flags: ZipFlag.utf8, method: 0, time: t, date: d, crc: 0, csize: 0, usize: 0,
                          name: nameBytes, external: mode << 16 | 0x10, localOffset: localOffset)
    }

    public func addFile(at source: URL, entryName: String, password: String?,
                        isCancelled: () -> Bool, bytesProcessed: (Int64) -> Void) throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let input = try? FileHandle(forReadingFrom: source) else {
            throw ZipError.io("읽을 수 없음: \(source.lastPathComponent)")
        }
        defer { try? input.close() }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let modified = (attrs[.modificationDate] as? Date) ?? Date()

        let name = FilenameCodec.normalizeForArchive(entryName)
        let nameBytes = Data(name.utf8)
        let ext = (name as NSString).pathExtension.lowercased()
        let method: UInt16 = (size == 0 || Self.storedExtensions.contains(ext)) ? 0 : 8
        let pw = password.flatMap { $0.isEmpty ? nil : ZipPassword.candidates($0).first }
        var flags = ZipFlag.utf8 | ZipFlag.dataDescriptor
        if pw != nil { flags |= ZipFlag.encrypted }
        let (t, d) = DosTime.encode(modified)

        let localOffset = offset
        try writeLocalHeader(flags: flags, method: method, time: t, date: d, name: nameBytes)

        var encryptor: ZipCryptoEncryptor?
        var csize: UInt64 = 0
        if let pw {
            // 데이터 디스크립터 사용 시 검사 바이트는 DOS 시간의 상위 바이트.
            let e = ZipCryptoEncryptor(password: pw, checkByte: UInt8(t >> 8))
            try write(Data(e.header))
            csize += 12
            encryptor = e
        }
        func emit(_ chunk: Data) throws {
            var c = chunk
            encryptor?.encrypt(&c)
            try write(c)
            csize += UInt64(c.count)
        }

        let deflater = method == 8 ? RawDeflater() : nil
        var crc: UInt32 = 0
        var usize: UInt64 = 0
        while true {
            if isCancelled() { throw ZipError.cancelled }
            let chunk: Data
            do {
                guard let c = try input.read(upToCount: Self.readChunk), !c.isEmpty else { break }
                chunk = c
            } catch {
                throw ZipError.io("읽기 실패: \(source.lastPathComponent)")
            }
            crc = CRC32.update(crc, chunk)
            usize += UInt64(chunk.count)
            if let deflater { try deflater.write(chunk, sink: emit) } else { try emit(chunk) }
            bytesProcessed(Int64(chunk.count))
        }
        if let deflater { try deflater.finish(sink: emit) }

        guard usize < 0xFFFF_FFFF, csize < 0xFFFF_FFFF else { throw ZipError.tooLarge("ZIP64") }
        var desc = Data()
        desc.le32(ZipSig.descriptor); desc.le32(crc); desc.le32(UInt32(csize)); desc.le32(UInt32(usize))
        try write(desc)

        let mode = (perms & 0o7777) | 0o100000
        try appendCentral(flags: flags, method: method, time: t, date: d, crc: crc, csize: UInt32(csize),
                          usize: UInt32(usize), name: nameBytes, external: mode << 16, localOffset: localOffset)
    }

    public func finish() throws {
        guard count < 0xFFFF else { throw ZipError.tooLarge("ZIP64") }
        let cdOffset = offset
        try write(central)
        guard offset < 0xFFFF_FFFF else { throw ZipError.tooLarge("ZIP64") }
        var end = Data()
        end.le32(ZipSig.end); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(cdOffset)); end.le16(0)
        try write(end)
        do { try handle.synchronize(); try handle.close() } catch { throw ZipError.io("저장 실패") }
    }

    // MARK: - 내부

    private func write(_ d: Data) throws {
        do { try handle.write(contentsOf: d) } catch { throw ZipError.io("쓰기 실패") }
        offset += UInt64(d.count)
    }

    private func writeLocalHeader(flags: UInt16, method: UInt16, time: UInt16, date: UInt16, name: Data) throws {
        guard offset < 0xFFFF_FFFF else { throw ZipError.tooLarge("ZIP64") }
        var h = Data()
        h.le32(ZipSig.local); h.le16(Self.versionNeeded); h.le16(flags); h.le16(method)
        h.le16(time); h.le16(date); h.le32(0); h.le32(0); h.le32(0)
        h.le16(UInt16(name.count)); h.le16(0)
        h.append(name)
        try write(h)
    }

    private func appendCentral(flags: UInt16, method: UInt16, time: UInt16, date: UInt16, crc: UInt32,
                               csize: UInt32, usize: UInt32, name: Data, external: UInt32, localOffset: UInt64) throws {
        count += 1
        guard count < 0xFFFF else { throw ZipError.tooLarge("ZIP64") }
        var c = Data()
        c.le32(ZipSig.central); c.le16(Self.versionMadeBy); c.le16(Self.versionNeeded)
        c.le16(flags); c.le16(method); c.le16(time); c.le16(date)
        c.le32(crc); c.le32(csize); c.le32(usize)
        c.le16(UInt16(name.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0)
        c.le32(external); c.le32(UInt32(localOffset))
        c.append(name)
        central.append(c)
    }
}
