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

public enum Archiver {
    /// 해제 전 사용자 확인을 받는 총 크기 기준(4GiB).
    public static let confirmBytes: UInt64 = 4 << 30

    // MARK: 압축

    private struct Item {
        let url: URL
        let entryName: String
        let isDirectory: Bool
    }

    public static func compress(inputs: [URL], password: String?, progress: (ArchiveProgress) -> Void,
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
                if values?.isSymbolicLink == true { skipped += 1; continue }
                let rel = url.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
                let dir = values?.isDirectory == true
                items.append(Item(url: url, entryName: root + "/" + rel + (dir ? "/" : ""), isDirectory: dir))
            }
            // 읽을 수 없는 폴더를 조용히 빠뜨리면 사용자는 불완전한 zip을 보내게 된다.
            if let first = unreadable.first {
                throw ZipError.io("읽을 수 없음: \(first.lastPathComponent)")
            }
        }

        let total = items.reduce(Int64(0)) { sum, item in
            guard !item.isDirectory else { return sum }
            return sum + ((try? fm.attributesOfItem(atPath: item.url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }

        let writer = try ZipWriter(destination: output)
        var completed: Int64 = 0
        do {
            for item in items {
                if isCancelled() { throw ZipError.cancelled }
                progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: item.entryName))
                if item.isDirectory {
                    let attrs = try? fm.attributesOfItem(atPath: item.url.path)
                    try writer.addDirectory(entryName: item.entryName,
                                            modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                                            unixMode: UInt16((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o755))
                } else {
                    try writer.addFile(at: item.url, entryName: item.entryName, password: password,
                                       isCancelled: isCancelled, bytesProcessed: { n in
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
                           isEncrypted: r.entries.contains { $0.isEncrypted && !$0.usesAES },
                           nameEncoding: r.nameEncoding)
    }

    // MARK: 해제

    public static func extract(zip: URL, password: String?, progress: (ArchiveProgress) -> Void,
                               isCancelled: () -> Bool) throws -> ExtractResult {
        let fm = FileManager.default
        let reader = try ZipReader(url: zip)
        if reader.entries.contains(where: { $0.isEncrypted && !$0.usesAES }), password?.isEmpty ?? true {
            throw ZipError.passwordRequired
        }

        let parent = zip.deletingLastPathComponent()
        let base = zip.deletingPathExtension().lastPathComponent
        let temp = UniqueName.url(for: parent.appendingPathComponent(".\(base).maczip-tmp"))
        do { try fm.createDirectory(at: temp, withIntermediateDirectories: false) }
        catch { throw ZipError.io("폴더를 만들 수 없음: \(parent.lastPathComponent)") }

        let total = Int64(reader.entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize })
        var completed: Int64 = 0
        var extracted = 0, skipped = 0
        var failures: [(name: String, error: ZipError)] = []
        var usedPaths = Set<String>()   // 대소문자 무시 충돌 감지
        var encryptedOK = 0, encryptedDamaged = 0

        do {
            for entry in reader.entries {
                if isCancelled() { throw ZipError.cancelled }
                if entry.isSymlink { skipped += 1; continue }
                guard let parts = PathSafety.safeComponents(entry.name) else {
                    failures.append((entry.name, .unsafePath(entry.name)))
                    continue
                }
                var dest = parts.reduce(temp) { $0.appendingPathComponent($1) }
                progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: entry.name))
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
                    try reader.extract(entry, to: dest, password: password, isCancelled: isCancelled, bytesProcessed: { n in
                        completed += n
                        progress(ArchiveProgress(completedBytes: completed, totalBytes: total, currentName: entry.name))
                    })
                    extracted += 1
                    if entry.isEncrypted { encryptedOK += 1 }
                } catch let e as ZipError {
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
            }
            // 암호화 항목이 하나도 안 풀리고 전부 '손상'이면 틀린 비밀번호의 우연 일치로 본다.
            if encryptedOK == 0 && encryptedDamaged > 0 { throw ZipError.wrongPassword }
            let final = UniqueName.url(for: parent.appendingPathComponent(base))
            do { try fm.moveItem(at: temp, to: final) } catch { throw ZipError.io("결과 폴더를 만들 수 없음") }
            return ExtractResult(outputFolder: final, extractedCount: extracted, skippedSymlinks: skipped, failures: failures)
        } catch {
            try? fm.removeItem(at: temp)
            throw asZipError(error)
        }
    }

    // MARK: 도우미

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
