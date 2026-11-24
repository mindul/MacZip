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

    /// 링크 대상 경로의 최대 바이트 수(PATH_MAX 1024에서 NUL 제외).
    public static let maxSymlinkTargetBytes = 1023

    /// 심볼릭 링크 대상이 풀린 폴더 안에 머무는지.
    /// - linkComponents: 링크 자신의 경로 조각(맨 끝이 링크 이름). 상위 폴더들은 실제 폴더여야 한다(Archiver가 확인).
    /// - 상대 경로만, `..`는 맨 앞에만 허용하고 올라가는 횟수는 링크가 있는 깊이를 넘지 않아야 한다.
    ///   이름 다음에 `..`가 오면 그 이름이 다른 링크일 때 밖으로 빠져나갈 수 있으므로 거부한다.
    public static func isSafeSymlinkTarget(_ target: String, linkComponents: [String]) -> Bool {
        guard !target.isEmpty, target.utf8.count <= maxSymlinkTargetBytes,
              !target.contains("\u{0}"), !target.contains("\\"), !target.hasPrefix("/") else { return false }
        let parts = target.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.isEmpty else { return false }
        var ups = 0, seenName = false
        for p in parts {
            if p == ".." {
                if seenName { return false }
                ups += 1
            } else {
                seenName = true
            }
        }
        return ups <= linkComponents.count - 1
    }

    /// `C:`, `c:x` 처럼 드라이브 문자로 시작하는 조각.
    private static func isDriveLetter(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":" else { return false }
        return CharacterSet.letters.contains(scalars[0]) && scalars[0].isASCII
    }
}
