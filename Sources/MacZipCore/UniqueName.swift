import Foundation

public enum UniqueName {
    /// `desired`가 이미 있으면 `이름 2.확장자`, `이름 3.확장자`… 중 처음 비어 있는 URL.
    public static func url(for desired: URL,
                           exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard exists(desired) else { return desired }
        let dir = desired.deletingLastPathComponent()
        let ext = desired.pathExtension
        let stem = desired.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
