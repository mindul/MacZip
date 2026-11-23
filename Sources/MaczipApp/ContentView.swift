import SwiftUI
import MaczipCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var sheetPassword = ""
    @FocusState private var focusedPasswordField: PasswordField?

    private enum PasswordField { case password, confirmation }

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            controls
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        // 압축 비밀번호 칸에 들어가면 영문 자판으로, 벗어나면 원래 자판으로.
        .onChange(of: focusedPasswordField) { _, field in
            if field != nil { KeyboardLayout.enterASCIIField() } else { KeyboardLayout.leaveASCIIField() }
        }
        .sheet(isPresented: needsPasswordBinding) { passwordSheet }
        .alert("큰 압축 파일", isPresented: confirmLargeBinding) {
            Button("계속") { model.confirmLargeExtract() }
            Button("취소", role: .cancel) { model.reset() }
        } message: {
            if case let .confirmLarge(bytes, _) = model.phase {
                Text("풀면 약 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))가 됩니다. 계속할까요?")
            }
        }
    }

    // MARK: 끌어다 놓기 영역

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            VStack(spacing: 8) {
                Image(systemName: headlineIcon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding()
        }
        .frame(minHeight: 160)
        .contentShape(Rectangle())
        .onTapGesture { model.chooseFilesToCompress() }
        .help(model.canPick ? "클릭해서 압축할 파일과 폴더를 고르세요" : "")
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isWorking else { return false }
            model.handleDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var headline: String {
        switch model.phase {
        case .idle, .needsPassword, .confirmLarge:
            if case .idle = model.phase { return "파일이나 폴더를 여기에 끌어다 놓거나\n클릭해서 고르세요" }
            return "압축 풀기: \(model.currentURLs.first?.lastPathComponent ?? "")"
        case let .ready(mode, urls):
            return mode == .extract ? "압축 풀기: \(urls.first?.lastPathComponent ?? "")"
                                    : "압축하기: \(urls.count)개 항목"
        case .working:
            return model.workingMode == .extract ? "푸는 중…" : "압축하는 중…"
        case .done: return "완료"
        case .failed: return "실패"
        }
    }

    private var headlineIcon: String {
        switch model.phase {
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case let .ready(mode, _): return mode == .extract ? "archivebox" : "doc.zipper"
        default: return "tray.and.arrow.down"
        }
    }

    // MARK: 아래쪽 조작부

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .ready(.compress, _):
            VStack(alignment: .leading, spacing: 8) {
                SecureField("비밀번호 (비워 두면 암호 없음)", text: Binding(get: { model.password }, set: { model.updatePassword($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPasswordField, equals: .password)
                SecureField("비밀번호 확인", text: Binding(get: { model.passwordConfirmation }, set: { model.updatePasswordConfirmation($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPasswordField, equals: .confirmation)
                    .onSubmit { model.startCompress() }
                if model.rejectedPasswordInput {
                    Text("비밀번호에는 영문·숫자·기호만 쓸 수 있습니다. 한글은 입력되지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.passwordStatus == .mismatch && !model.passwordConfirmation.isEmpty {
                    Text("비밀번호가 서로 다릅니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("취소") { model.reset() }
                    Spacer()
                    Button("압축") { model.startCompress() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.passwordStatus == .mismatch || model.passwordStatus == .invalidCharacters)
                }
            }
        case let .working(progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction)
                Text(progress.currentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack { Spacer(); Button("취소") { model.cancel() } }
            }
        case let .done(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.resultURL != nil { Button("Finder에서 보기") { model.revealResult() } }
                    Spacer()
                    Button("확인") { model.reset() }.keyboardShortcut(.defaultAction)
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("확인") { model.reset() }.keyboardShortcut(.defaultAction) }
            }
        default:
            EmptyView()
        }
    }

    // MARK: 비밀번호 시트

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("비밀번호가 필요합니다").font(.headline)
            Text(model.currentURLs.first?.lastPathComponent ?? "").foregroundStyle(.secondary)
            SecureField("비밀번호", text: $sheetPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitPassword)
            if let error = model.passwordError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("취소") { model.reset() }
                Spacer()
                Button("풀기", action: submitPassword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheetPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { sheetPassword = "" }
    }

    private func submitPassword() {
        guard !sheetPassword.isEmpty else { return }
        model.submitExtractPassword(sheetPassword)
        sheetPassword = ""
    }

    private var needsPasswordBinding: Binding<Bool> {
        Binding(get: { if case .needsPassword = model.phase { return true } else { return false } },
                set: { _ in })
    }

    private var confirmLargeBinding: Binding<Bool> {
        Binding(get: { if case .confirmLarge = model.phase { return true } else { return false } },
                set: { _ in })
    }
}
