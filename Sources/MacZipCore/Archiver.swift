import Foundation

public struct ArchiveProgress: Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var currentName: String

    public init(completedBytes: Int64, totalBytes: Int64, currentName: String) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentName = currentName
    }

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

public enum OperationMode: Sendable { case compress, extract }

public enum DropClassifier {
    /// `.zip` 파일 하나면 해제, 그 외에는 압축.
    public static func mode(for urls: [URL]) -> OperationMode? {
        guard let first = urls.first else { return nil }
        if urls.count == 1, first.pathExtension.lowercased() == "zip" {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            if !(exists && isDir.boolValue) { return .extract }
        }
        return .compress
    }
}

public struct CompressResult: Sendable {
    public let output: URL
    public let entryCount: Int
    public let skippedSymlinks: Int
}

public struct ExtractResult: @unchecked Sendable {
    public let outputFolder: URL
    public let extractedCount: Int
    public let skippedSymlinks: Int
    public let failures: [(name: String, error: ZipError)]

    /// 실패 항목을 사유별로 묶은 문구. 실패가 없으면 nil.
    public var failureSummary: String? {
        guard !failures.isEmpty else { return nil }
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for f in failures {
            let key = f.error.reasonLabel
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f.name)
        }
        return order.map { key in
            let names = groups[key]!
            let shown = names.prefix(3).joined(separator: ", ")
            return "\(key) (\(names.count)개): \(shown)\(names.count > 3 ? " 외" : "")"
        }.joined(separator: "\n")
    }
}

public struct ArchiveInfo: Sendable {
    public let entryCount: Int
    public let totalUncompressedBytes: UInt64
    public let isEncrypted: Bool
    public let nameEncoding: NameEncoding
}

extension ZipEntry {
    /// 풀 때 비밀번호가 필요한 항목(ZipCrypto, 또는 지원하는 AES). 지원하지 않는 AES 형식은 제외.
    var needsPassword: Bool {
        isEncrypted && (!usesAES || aes.flatMap { WinZipAES.sizes(strength: $0.strength) } != nil)
    }
}

public enum Archiver {
    /// 해제 전 사용자 확인을 받는 총 크기 기준(4GiB).
    public static let confirmBytes: UInt64 = 4 << 30

    // MARK: 압축

    private struct Item {
        let url: URL
        let entryName: String
        let isDirectory: Bool
        /// 심볼릭 링크면 그 대상 경로(풀린 폴더 안을 가리키는 것만 담는다).
        var linkTarget: String? = nil
    }

    public static func compress(inputs: [URL], password: String?, encryption: EncryptionMethod = .zipCrypto,
                                progress: (ArchiveProgress) -> Void,
                                isCancelled: () -> Bool) throws -> CompressResult {
        guard let first = inputs.first else { throw ZipError.io("압축할 항목이 없음") }
        let fm = FileManager.default
        let parent = first.deletingLastPathComponent()
        let zipName = inputs.count == 1 ? first.lastPathComponent + ".zip" : "archive.zip"
        let output = UniqueName.url(for: parent.appendingPathComponent(zipName))
        let outputPath = output.standardizedFileURL.path

        // 항목 수집
        var items: [Item] = []
        var skipped = 0
        var usedRoots = Set<String>()
        for input in inputs {
            if isSymlink(input) { skipped += 1; continue }
            let rootURL = UniqueName.url(for: URL(fileURLWithPath: "/" + input.lastPathComponent),
                                         exists: { usedRoots.contains($0.lastPathComponent.lowercased()) })
            let root = rootURL.lastPathComponent
            usedRoots.insert(root.lowercased())
            guard isDirectory(input) else {
                items.append(Item(url: input, entryName: root, isDirectory: false))
                continue
            }
            items.append(Item(url: input, entryName: root + "/", isDirectory: true))
            let base = input.standardizedFileURL.pathComponents
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            var unreadable: [URL] = []
            guard let walker = fm.enumerator(at: input, includingPropertiesForKeys: keys,
                                             errorHandler: { url, _ in unreadable.append(url); return true }) else {
                throw ZipError.io("읽을 수 없음: \(input.lastPathComponent)")
            }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name == "__MACOSX" { walker.skipDescendants(); continue }
                if name == ".DS_Store" || name.hasPrefix("._") { continue }
                if url.standardizedFileURL.path == outputPath { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                // 상위 폴더(항상 실제 폴더)만 표준화한다. 대상이 없는 링크는 표준화 결과가 달라(/var ↔ /private/var)
                // 경로 조각 수가 어긋나기 때문이다.
                let rel = (url.deletingLastPathComponent().standardizedFileURL.pathComponents + [url.lastPathComponent])
                    .dropFirst(base.count).joined(separator: "/")
                if values?.isSymbolicLink == true {
                    // 앱 안의 링크(Versions/Current 등)는 담고, 폴더 밖을 가리키는 링크는 건너뛴다.
                    let entryName = root + "/" + rel
                    if let target = try? fm.destinationOfSymbolicLink(atPath: url.path),
                       PathSafety.isSafeSymlinkTarget(target, linkComponents: entryName.split(separator: "/").map(String.init)) {
                        items.append(Item(url: url, entryName: entryName, isDirectory: false, linkTarget: target))
                    } else {
                        skipped += 1
                    }
                    continue
                }
                let dir = values?.isDirectory == true
                items.append(Item(url: url, entryName: root + "/" + rel + (dir ? "/" : ""), isDirectory: dir))
            }
            // 읽을 수 없는 폴더를 조용히 빠뜨리면 사용자는 불완전한 zip을 보내게 된다.
            if let first = unreadable.first {
                throw ZipError.io("읽을 수 없음: \(first.lastPathComponent)")
            }
        }

        let total = items.reduce(Int64(0)) { sum, item in
            guard !item.isDirectory, item.linkTarget == nil else { return sum }
            return sum + ((try? fm.attributesOfItem(atPath: item.url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }

        let writer = try ZipWriter(destination: output)
        var completed: Int64 = 0
        do {
            for item in items {
                if isCancelled() { throw ZipError.cancelled }
                progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: item.entryName))
                if let target = item.linkTarget {
                    let attrs = try? fm.attributesOfItem(atPath: item.url.path)   // 링크 자신(따라가지 않음)
                    try writer.addSymlink(entryName: item.entryName, target: target,
                                          modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                                          password: password, encryption: encryption)
                } else if item.isDirectory {
                    let attrs = try? fm.attributesOfItem(atPath: item.url.path)
                    try writer.addDirectory(entryName: item.entryName,
                                            modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                                            unixMode: UInt16((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o755))
                } else {
                    try writer.addFile(at: item.url, entryName: item.entryName, password: password,
                                       encryption: encryption, isCancelled: isCancelled, bytesProcessed: { n in
                        completed += n
                        progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: item.entryName))
                    })
                }
            }
            try writer.finish()
        } catch {
            try? fm.removeItem(at: output)
            throw asZipError(error)
        }
        return CompressResult(output: output, entryCount: items.count, skippedSymlinks: skipped)
    }

    // MARK: 검사

    public static func inspect(zip: URL) throws -> ArchiveInfo {
        let r = try ZipReader(url: zip)
        return ArchiveInfo(entryCount: r.entries.count,
                           totalUncompressedBytes: r.entries.reduce(0) { $0 + $1.uncompressedSize },
                           isEncrypted: r.entries.contains { $0.needsPassword },
                           nameEncoding: r.nameEncoding)
    }

    // MARK: 해제

    public static func extract(zip: URL, password: String?, progress: (ArchiveProgress) -> Void,
                               isCancelled: () -> Bool) throws -> ExtractResult {
        let fm = FileManager.default
        let reader = try ZipReader(url: zip)
        // 인터넷에서 받은 zip이면 그 격리 표시를 풀린 파일·폴더에도 옮긴다(Gatekeeper 검사 유지).
        let quarantine = Quarantine.value(of: zip)
        reader.quarantine = quarantine
        if reader.entries.contains(where: { $0.needsPassword }), password?.isEmpty ?? true {
            throw ZipError.passwordRequired
        }

        let parent = zip.deletingLastPathComponent()
        let base = zip.deletingPathExtension().lastPathComponent
        let temp = UniqueName.url(for: parent.appendingPathComponent(".\(base).maczip-tmp"))
        do { try fm.createDirectory(at: temp, withIntermediateDirectories: false) }
        catch { throw ZipError.io("폴더를 만들 수 없음: \(parent.lastPathComponent)") }

        let total = Int64(reader.entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize })
        var completed: Int64 = 0
        var extracted = 0
        var failures: [(name: String, error: ZipError)] = []
        var usedPaths = Set<String>()   // 대소문자 무시 충돌 감지
        var encryptedOK = 0, encryptedDamaged = 0
        // 심볼릭 링크는 다른 항목을 모두 푼 뒤 마지막에 만든다(파일이 링크를 거쳐 밖에 써지지 않게).
        var pendingLinks: [(name: String, parts: [String], target: String)] = []

        /// 항목 하나의 해제 오류를 기록한다. 계속할 수 없는 오류는 다시 던진다.
        func record(_ e: ZipError, for entry: ZipEntry) throws {
            if entry.isEncrypted, e == .crcMismatch(entry: entry.name) || { if case .corrupt = e { return true }; return false }() {
                encryptedDamaged += 1
            }
            switch e {
            case .crcMismatch, .unsupportedMethod, .unsupportedAES, .corrupt, .io:
                failures.append((entry.name, e))
            default:
                throw e
            }
        }

        do {
            for entry in reader.entries {
                if isCancelled() { throw ZipError.cancelled }
                guard let parts = PathSafety.safeComponents(entry.name) else {
                    failures.append((entry.name, .unsafePath(entry.name)))
                    continue
                }
                var dest = parts.reduce(temp) { $0.appendingPathComponent($1) }
                progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: entry.name))
                if entry.isSymlink {
                    // 링크 내용(대상 경로)은 일반 파일처럼 풀어서 읽는다: 암호·CRC·인증 코드 검사를 그대로 거친다.
                    guard entry.uncompressedSize <= UInt64(PathSafety.maxSymlinkTargetBytes) else {
                        failures.append((entry.name, .unsafePath(entry.name)))
                        continue
                    }
                    let scratch = temp.appendingPathComponent(".maczip-link-\(UUID().uuidString)")
                    do {
                        try reader.extract(entry, to: scratch, password: password, isCancelled: isCancelled,
                                           bytesProcessed: { n in
                                           completed += n
                                           progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: entry.name))
                                       })
                        if entry.isEncrypted { encryptedOK += 1 }
                        let data = try? Data(contentsOf: scratch)
                        try? fm.removeItem(at: scratch)
                        guard let data, let target = String(data: data, encoding: .utf8) else {
                            failures.append((entry.name, .unsafePath(entry.name)))
                            continue
                        }
                        pendingLinks.append((entry.name, parts, target.precomposedStringWithCanonicalMapping))
                    } catch let e as ZipError {
                        try? fm.removeItem(at: scratch)
                        try record(e, for: entry)
                    }
                    continue
                }
                if entry.isDirectory {
                    do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) }
                    catch { failures.append((entry.name, .io("폴더를 만들 수 없음"))) }
                    usedPaths.insert(dest.path.lowercased())
                    continue
                }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    // 같은 이름의 파일과 폴더 충돌 등: 이 항목만 실패로 기록한다.
                    failures.append((entry.name, .io("폴더를 만들 수 없음")))
                    continue
                }
                dest = UniqueName.url(for: dest, exists: { fm.fileExists(atPath: $0.path) || usedPaths.contains($0.path.lowercased()) })
                usedPaths.insert(dest.path.lowercased())
                do {
                    try reader.extract(entry, to: dest, password: password, isCancelled: isCancelled,
                                       bytesProcessed: { n in
                                           completed += n
                                           progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: entry.name))
                                       })
                    extracted += 1
                    if entry.isEncrypted { encryptedOK += 1 }
                } catch let e as ZipError {
                    try record(e, for: entry)
                }
            }
            // 암호화 항목이 하나도 안 풀리고 전부 '손상'이면 틀린 비밀번호의 우연 일치로 본다.
            if encryptedOK == 0 && encryptedDamaged > 0 { throw ZipError.wrongPassword }
            for link in pendingLinks {
                if isCancelled() { throw ZipError.cancelled }
                guard PathSafety.isSafeSymlinkTarget(link.target, linkComponents: link.parts),
                      let made = makeSymlink(in: temp, parts: link.parts, target: link.target) else {
                    failures.append((link.name, .unsafePath(link.name)))
                    continue
                }
                if let quarantine { Quarantine.apply(quarantine, to: made) }   // 링크 자신(따라가지 않음)
                extracted += 1
            }
            if let quarantine, !Quarantine.applyToDirectories(quarantine, in: temp) {
                throw ZipError.io("보안 표시를 붙일 수 없음")
            }
            let final = UniqueName.url(for: parent.appendingPathComponent(base))
            do { try fm.moveItem(at: temp, to: final) } catch { throw ZipError.io("결과 폴더를 만들 수 없음") }
            return ExtractResult(outputFolder: final, extractedCount: extracted, skippedSymlinks: 0, failures: failures)
        } catch {
            try? fm.removeItem(at: temp)
            throw asZipError(error)
        }
    }

    // MARK: 도우미

    /// root 아래 parts 위치에 링크를 만든다. 상위 경로가 모두 실제 폴더여야 하며(링크를 거치지 않음),
    /// 같은 이름이 이미 있으면 만들지 않는다. 성공하면 링크 URL.
    private static func makeSymlink(in root: URL, parts: [String], target: String) -> URL? {
        let fm = FileManager.default
        var dir = root
        for name in parts.dropLast() {
            dir = dir.appendingPathComponent(name)
            // attributesOfItem은 마지막 링크를 따라가지 않는다(lstat).
            if let type = (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType {
                guard type == .typeDirectory else { return nil }
            } else {
                guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false)) != nil else { return nil }
            }
        }
        let link = dir.appendingPathComponent(parts[parts.count - 1])
        guard (try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)) != nil else { return nil }
        return link
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func asZipError(_ error: Error) -> ZipError {
        (error as? ZipError) ?? .io(error.localizedDescription)
    }
}
