import Foundation

public enum NameEncoding: Equatable, Sendable {
    case utf8, cp949, cp437
}

/// zip 중앙 디렉터리에 저장된 이름 원본.
public struct RawEntryName {
    public let bytes: [UInt8]
    public let utf8Flag: Bool
    public let unicodePath: (crc: UInt32, name: String)?

    public init(bytes: [UInt8], utf8Flag: Bool, unicodePath: (crc: UInt32, name: String)?) {
        self.bytes = bytes
        self.utf8Flag = utf8Flag
        self.unicodePath = unicodePath
    }
}

public enum FilenameCodec {
    /// 압축할 때 쓰는 이름: NFC(합쳐진 한글).
    public static func normalizeForArchive(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// 압축 파일 전체에 대해 한 번 인코딩을 고른다.
    /// 순서: UTF-8 플래그 → 유효한 UTF-8 → CP949 → CP437.
    /// (0x7075 확장 필드는 항목별로 `decode`에서 우선 적용한다.)
    public static func chooseEncoding(_ names: [RawEntryName]) -> NameEncoding {
        if names.contains(where: { $0.utf8Flag }) { return .utf8 }
        if names.allSatisfy({ String(bytes: $0.bytes, encoding: .utf8) != nil }) { return .utf8 }
        if names.allSatisfy({ String(bytes: $0.bytes, encoding: TextEncodings.cp949) != nil }) { return .cp949 }
        return .cp437
    }

    /// 이름을 디코드한다. 항상 NFC 문자열을 반환한다.
    public static func decode(_ name: RawEntryName, using encoding: NameEncoding) -> String {
        if let up = name.unicodePath, up.crc == CRC32.checksum(Data(name.bytes)) {
            return up.name.precomposedStringWithCanonicalMapping
        }
        let decoded: String?
        switch encoding {
        case .utf8:
            decoded = String(bytes: name.bytes, encoding: .utf8)
        case .cp949:
            decoded = String(bytes: name.bytes, encoding: TextEncodings.cp949)
        case .cp437:
            decoded = nil
        }
        // 선택한 인코딩으로 안 되는 이름(예: 플래그가 섞인 파일)은 개별적으로 대체 디코드한다.
        let text = decoded
            ?? String(bytes: name.bytes, encoding: .utf8)
            ?? String(bytes: name.bytes, encoding: TextEncodings.cp437)
            ?? String(decoding: name.bytes, as: UTF8.self)
        return text.precomposedStringWithCanonicalMapping
    }
}
