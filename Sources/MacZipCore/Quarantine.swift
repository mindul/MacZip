import Darwin
import Foundation

/// macOS 격리 표시(com.apple.quarantine). 인터넷에서 받은 zip의 표시를 풀린 파일에도 옮겨,
/// 풀린 앱·스크립트를 처음 실행할 때 Gatekeeper 검사를 거치게 한다(아카이브 유틸리티와 같은 동작).
public enum Quarantine {
    static let attributeName = "com.apple.quarantine"

    /// 파일에 붙은 격리 표시 값. 없으면 nil.
    public static func value(of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, attributeName, &buffer, size, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return Data(buffer.prefix(read))
        }
    }

    /// 격리 표시를 붙인다. 실패하면 false.
    @discardableResult
    public static func apply(_ value: Data, to url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withUnsafeBytes { raw in
                setxattr(path, attributeName, raw.baseAddress, raw.count, 0, XATTR_NOFOLLOW) == 0
            }
        }
    }

    /// root 폴더 자신과 그 안의 모든 폴더에 격리 표시를 붙인다. 하나라도 실패하면 false.
    /// 파일은 읽기 전용 권한이 적용되기 전에 따로 붙인다(권한이 적용된 뒤에는 setxattr가 거부된다).
    static func applyToDirectories(_ value: Data, in root: URL) -> Bool {
        var ok = apply(value, to: root)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return false }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
            if !apply(value, to: url) { ok = false }
        }
        return ok
    }
}
