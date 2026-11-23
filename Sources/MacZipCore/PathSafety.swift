import Foundation

public enum PathSafety {
    /// zip 항목 이름을 안전한 상대 경로 조각으로 바꾼다. 위험하면 nil.
    public static func safeComponents(_ entryName: String) -> [String]? {
        if entryName.contains("\u{0}") { return nil }
        let normalized = entryName.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first, isDriveLetter(first) { return nil }
        if parts.contains("..") { return nil }
        let kept = parts.filter { $0 != "." }
        return kept.isEmpty ? nil : kept
    }

    /// `C:`, `c:x` 처럼 드라이브 문자로 시작하는 조각.
    private static func isDriveLetter(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":" else { return false }
        return CharacterSet.letters.contains(scalars[0]) && scalars[0].isASCII
    }
}
