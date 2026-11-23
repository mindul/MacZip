import Foundation
import MaczipCore

func passwordEntryChecks() {
    Harness.suite("PasswordEntry") {
        Harness.expectEqual(PasswordEntry.check(password: "", confirmation: ""), .none, "둘 다 비면 암호 없음")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: "pw1234"), .ok, "일치")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: "pw123"), .mismatch, "불일치")
        Harness.expectEqual(PasswordEntry.check(password: "pw1234", confirmation: ""), .mismatch, "확인 칸이 비면 불일치")
        Harness.expectEqual(PasswordEntry.check(password: "", confirmation: "x"), .mismatch, "비밀번호 칸만 비면 불일치")
        Harness.expectEqual(PasswordEntry.check(password: "한글비번", confirmation: "한글비번".decomposedStringWithCanonicalMapping),
                            .ok, "NFC/NFD 차이는 같은 비밀번호로 봄")
    }
}
