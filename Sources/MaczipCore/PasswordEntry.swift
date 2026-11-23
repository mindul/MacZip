import Foundation

/// 압축 비밀번호 두 번 입력의 상태.
public enum PasswordEntry: Equatable, Sendable {
    /// 둘 다 비어 있음: 암호 없이 압축.
    case none
    /// 두 칸이 다름(한쪽만 비어 있는 경우 포함): 압축할 수 없음.
    case mismatch
    /// 두 칸이 같음: 이 비밀번호로 암호화.
    case ok

    public static func check(password: String, confirmation: String) -> PasswordEntry {
        if password.isEmpty && confirmation.isEmpty { return .none }
        // Swift 문자열 비교는 NFC/NFD 같은 정규화 차이를 같은 것으로 본다.
        return password == confirmation ? .ok : .mismatch
    }
}
