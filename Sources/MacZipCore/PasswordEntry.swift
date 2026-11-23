import Foundation

/// 압축 비밀번호 두 번 입력의 상태.
public enum PasswordEntry: Equatable, Sendable {
    /// 둘 다 비어 있음: 암호 없이 압축.
    case none
    /// 영문·숫자·키보드 기호 외의 문자(한글 등)가 들어 있음: 압축할 수 없음.
    case invalidCharacters
    /// 두 칸이 다름(한쪽만 비어 있는 경우 포함): 압축할 수 없음.
    case mismatch
    /// 두 칸이 같음: 이 비밀번호로 암호화.
    case ok

    public static func check(password: String, confirmation: String) -> PasswordEntry {
        if password.isEmpty && confirmation.isEmpty { return .none }
        if !isAllowed(password) || !isAllowed(confirmation) { return .invalidCharacters }
        return password == confirmation ? .ok : .mismatch
    }

    /// 윈도우 프로그램마다 비ASCII 비밀번호의 바이트 인코딩이 달라 열리지 않을 수 있으므로,
    /// 압축 비밀번호는 출력 가능한 ASCII(0x20–0x7E: 영문·숫자·기호·공백)만 허용한다.
    public static func isAllowed(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(isAllowedScalar)
    }

    /// 허용되지 않는 문자를 뺀 문자열.
    public static func allowedOnly(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter(isAllowedScalar)))
    }

    private static func isAllowedScalar(_ u: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(u.value)
    }
}

/// 비밀번호 칸에 들어갈 때 키보드를 영문 자판으로 바꿀지 판단한다.
public enum KeyboardSwitchPolicy {
    /// - Parameters:
    ///   - isASCIICapable: 현재 입력 소스가 ASCII를 칠 수 있는지(TIS 속성).
    ///   - languages: 현재 입력 소스의 언어 목록(TIS 속성).
    public static func shouldSwitchToASCII(isASCIICapable: Bool, languages: [String]) -> Bool {
        !isASCIICapable || languages.contains { $0.lowercased().hasPrefix("ko") }
    }
}
