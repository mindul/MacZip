import Carbon
import MacZipCore

/// 압축 비밀번호 칸에서 키보드를 영문 자판으로 바꾸고, 벗어나면 원래 자판으로 되돌린다.
@MainActor
enum KeyboardLayout {
    private static var saved: TISInputSource?

    /// 비밀번호 칸에 들어갈 때 호출. 현재 자판이 한글 등이면 ASCII 자판(예: ABC)으로 바꾼다.
    static func enterASCIIField() {
        guard saved == nil else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let ascii: Bool = property(current, kTISPropertyInputSourceIsASCIICapable) ?? false
        let languages: [String] = property(current, kTISPropertyInputSourceLanguages) ?? []
        guard KeyboardSwitchPolicy.shouldSwitchToASCII(isASCIICapable: ascii, languages: languages) else { return }
        let target = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        if TISSelectInputSource(target) == noErr { saved = current }
    }

    /// 비밀번호 칸을 벗어날 때 호출. 바꿨던 경우에만 원래 자판으로 되돌린다.
    static func leaveASCIIField() {
        guard let previous = saved else { return }
        saved = nil
        TISSelectInputSource(previous)
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }
}
