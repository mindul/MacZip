import Foundation
import MacZipCore

func passwordEntryChecks() {
    Harness.suite("PasswordEntry") {
        Harness.expectEqual(PasswordEntry.check(password: "", confirmation: ""), .none, "둘 다 비면 암호 없음")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: "pw1234"), .ok, "일치")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: "pw123"), .mismatch, "불일치")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: ""), .mismatch, "확인 칸이 비면 불일치")
        Harness.expectEqual(PasswordEntry.check(password: "", confirmation: "x"), .mismatch, "비밀번호 칸만 비면 불일치")
        Harness.expectEqual(PasswordEntry.check(password: "한글비번", confirmation: "한글비번".decomposedStringWithCanonicalMapping),
                            .invalidCharacters, "한글 비밀번호는 허용 안 함")

        // 압축 비밀번호는 영문·숫자·키보드 기호(ASCII 0x20–0x7E)만 허용
        Harness.expectEqual(PasswordEntry.check(password: "Pa$$ w0rd!~", confirmation: "Pa$$ w0rd!~"), .ok, "ASCII 기호·공백 허용")
        Harness.expectEqual(PasswordEntry.check(password: "pw한", confirmation: "pw한"), .invalidCharacters, "한글 섞임")
        Harness.expectEqual(PasswordEntry.check(password: "pw🙂", confirmation: "pw🙂"), .invalidCharacters, "이모지")
        Harness.expectEqual(PasswordEntry.check(password: "pw", confirmation: "pwㅎ"), .invalidCharacters, "확인 칸에만 한글")
        Harness.expectEqual(PasswordEntry.allowedOnly("ab한글c1ㅎ!"), "abc1!", "허용 문자만 남김")
        Harness.expectEqual(PasswordEntry.allowedOnly("tab\there"), "tabhere", "제어 문자 제거")
        Harness.expect(PasswordEntry.isAllowed("Abc123!@#"), "허용 판정")
        Harness.expect(!PasswordEntry.isAllowed("가"), "비허용 판정")

        // 키보드 자동 전환 판단
        Harness.expect(KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: false, languages: ["ko"]), "한글 입력기 → 전환")
        Harness.expect(KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: true, languages: ["ko"]), "한국어 계열이면 ASCII 가능이어도 전환")
        Harness.expect(!KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: true, languages: ["en"]), "ABC 자판은 그대로")
        Harness.expect(KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: false, languages: ["ja"]), "다른 비ASCII 입력기도 전환")
    }
}
