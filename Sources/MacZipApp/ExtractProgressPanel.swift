import AppKit

/// 창 없이 풀거나 압축할 때 오래 걸리면 띄우는 작은 진행 창: zip 이름, 동작, (n/전체), 진행 막대, [취소].
/// 사용자가 Finder에서 하던 일을 방해하지 않도록 포커스를 뺏지 않고 앞에만 띄운다.
@MainActor
final class ExtractProgressPanel: NSObject {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: (@MainActor () -> Void)?

    /// state가 nil이면 닫는다.
    func update(_ state: BackgroundExtractor.ProgressState?) {
        guard let state else {
            panel?.orderOut(nil)
            onCancel = nil
            return
        }
        onCancel = state.onCancel
        let position = state.total > 1 ? " (\(state.index)/\(state.total))" : ""
        label.stringValue = "‘\(state.zipName)’ \(state.action)…\(position)"
        bar.doubleValue = state.fraction
        let p = panel ?? makePanel()
        if !p.isVisible {
            p.center()
            p.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                        styleMask: [.titled], backing: .buffered, defer: true)
        p.title = "맥집"
        p.hidesOnDeactivate = false        // Finder로 돌아가도 계속 보이게
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true

        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancel])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [label, bar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 320),
            label.widthAnchor.constraint(equalTo: bar.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: bar.widthAnchor),
        ])
        p.contentView = content
        panel = p
        return p
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
