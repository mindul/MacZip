import AppKit
import Carbon
import MacZipCore
import os

/// 압축 비밀번호 칸에서 키보드를 영문 자판으로 바꾸고, 벗어나면 원래 자판으로 되돌린다.
@MainActor
enum KeyboardLayout {
    private static var saved: TISInputSource?

    /// 비밀번호 칸에 들어갈 때 호출. 현재 자판이 한글 등이면 ASCII 자판(예: ABC)으로 바꾼다.
    /// macOS의 '문서마다 입력 소스 자동 전환'이나 창이 키 창이 되는 과정에서 한글로 되돌려질 수 있어,
    /// 잠시 동안 몇 번 더 확인해서 다시 영문으로 맞춘다.
    static func enterASCIIField() {
        applyASCII()
        for delay in [0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if saved != nil { applyASCII() } }
        }
    }

    private static func applyASCII() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let ascii: Bool = property(current, kTISPropertyInputSourceIsASCIICapable) ?? false
        let languages: [String] = property(current, kTISPropertyInputSourceLanguages) ?? []
        guard KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: ascii, languages: languages) else { return }
        let target = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        let result = TISSelectInputSource(target)
        appLog.notice("영문 자판 전환 시도: 결과 \(result)")
        // 처음 바꿀 때의 원래 자판만 기억한다(되돌릴 때 쓴다).
        if result == noErr, saved == nil { saved = current }
    }

    /// 비밀번호 칸을 벗어날 때 호출. 바꿨던 경우에만 원래 자판으로 되돌린다.
    static func leaveASCIIField() {
        guard let previous = saved else { appLog.notice("자판 복원 없음"); return }
        saved = nil
        let result = TISSelectInputSource(previous)
        appLog.notice("원래 자판으로 복원: 결과 \(result)")
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }
}

/// 칸에 들어가면 영문 자판으로 바꾸는 비밀번호 입력 칸(창 없이 풀 때의 비밀번호 대화상자용).
/// 칸이 포커스를 받는 도중에는 자판 전환이 덮어써질 수 있어, 한 박자 뒤에 바꾼다.
final class ASCIISecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { KeyboardLayout.enterASCIIField() } }
        return ok
    }
}
