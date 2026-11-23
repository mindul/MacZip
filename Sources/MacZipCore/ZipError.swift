import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16)
    case unsupportedAES(entry: String)
    case passwordRequired
    case wrongPassword
    case crcMismatch(entry: String)
    case unsafePath(String)
    case tooLarge(String)
    case cancelled
    case io(String)
}

extension ZipError {
    /// 사용자에게 보여 줄 한국어 문장.
    public var userMessage: String {
        switch self {
        case .notAZip: return "zip 파일이 아니거나 손상되었습니다."
        case .corrupt: return "압축 파일이 손상되었습니다."
        case let .unsupportedMethod(m): return "지원하지 않는 압축 방식입니다. (방식 \(m))"
        case .unsupportedAES: return "AES 암호화는 지원하지 않습니다."
        case .passwordRequired: return "비밀번호가 필요합니다."
        case .wrongPassword: return "비밀번호가 맞지 않습니다."
        case let .crcMismatch(entry): return "파일이 손상되었습니다: \(entry)"
        case let .unsafePath(name): return "안전하지 않은 경로라서 건너뛰었습니다: \(name)"
        case .tooLarge: return "4GB 이상의 파일은 지원하지 않습니다."
        case .cancelled: return "취소했습니다."
        case let .io(detail): return "파일을 읽거나 쓸 수 없습니다. (\(detail))"
        }
    }

    /// 여러 항목의 실패를 사유별로 묶기 위한 분류 문구(항목 이름 제외).
    var reasonLabel: String {
        switch self {
        case .unsupportedAES: return "AES 암호화는 지원하지 않습니다"
        case .unsupportedMethod: return "지원하지 않는 압축 방식입니다"
        case .crcMismatch, .corrupt: return "파일이 손상되었습니다"
        case .unsafePath: return "안전하지 않은 경로라서 건너뛰었습니다"
        case .tooLarge: return "4GB 이상의 파일은 지원하지 않습니다"
        default: return "파일을 만들 수 없습니다"
        }
    }
}
