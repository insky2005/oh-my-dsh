import AppKit

// Scaffold 面板的无头测试桩：ScaffoldPanel.swift 引用 CodeEditorView，但该测试
// 只跑引擎层（解析/渲染/规划/落盘），不渲染编辑器 —— 这里给一个同签名的最小桩。
// 注意：不要放进 tests/terminal-emulator/stubs.swift —— tests/file-panel/run.sh 会
// 把共享桩与真实 platforms/macos/src/CodeEditorView.swift 一起编译，放共享桩会导致
// 重复声明（invalid redeclaration）。真实实现由 FilePanel 使用。

final class LineNumberGutterView: NSView {
    weak var codeTextView: NSTextView?
}
final class CodeEditorView: NSView {
    static func language(forExtension ext: String) -> String? { nil }
    let path: String
    var onDirtyChange: ((Bool) -> Void)?
    var onSaveError: ((String) -> Void)?
    private(set) var isDirty = false
    var text = ""
    init(path: String, text: String, language: String?, dark: Bool) {
        self.path = path
        self.text = text
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult
    func writeBack() -> Bool { isDirty = false; return true }
    func markClean() { isDirty = false }
    func reloadFromDisk() {}
}
