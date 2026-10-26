import AppKit
import SwiftUI

/// One editor for both presentations, preserving selection, undo and IME state.
struct ModeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var mode: QuickInputMode
    var placeholder: String
    var focused: Bool
    var enabled: Bool
    var onHeightChange: (CGFloat) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ModeSearchContainer {
        let view = ModeSearchContainer()
        view.editor.delegate = context.coordinator
        view.editor.onModeChange = { [weak coordinator = context.coordinator] mode in
            coordinator?.parent.mode = mode
        }
        view.onHeightChange = { [weak coordinator = context.coordinator] height in
            // Native layout can run during a SwiftUI update.
            DispatchQueue.main.async { [weak coordinator] in coordinator?.parent.onHeightChange(height) }
        }
        return view
    }

    func updateNSView(_ view: ModeSearchContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.editor.mode = mode
        view.placeholder.stringValue = placeholder
        view.editor.setAccessibilityLabel(L10n.text(mode.labelKey))
        view.editor.isEditable = enabled
        view.editor.isSelectable = enabled
        view.toggle.isEnabled = enabled
        if !view.editor.hasMarkedText() {
            if view.editor.string != text {
                view.editor.breakUndoCoalescing()
                view.editor.string = text
                view.editor.undoManager?.removeAllActions()
                view.editor.manuallyCollapsed = false
                view.editor.forcedExpanded = false
            }
            view.refresh()
        }
        let shouldFocus = focused && enabled
        if shouldFocus && !coordinator.requestedFocus {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, coordinator.parent.focused, coordinator.parent.enabled else { return }
                view.window?.makeFirstResponder(view.editor)
            }
        }
        coordinator.requestedFocus = shouldFocus
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ModeSearchField
        var requestedFocus = false
        init(_ parent: ModeSearchField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ModeSearchTextView else { return }
            parent.text = editor.string
            editor.manuallyCollapsed = false
            editor.forcedExpanded = false
            editor.container?.refresh()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}

final class ModeSearchTextView: NSTextView {
    weak var container: ModeSearchContainer?
    var manuallyCollapsed = false
    var forcedExpanded = false
    var isExpanded = false
    var mode: QuickInputMode = .search
    var onModeChange: ((QuickInputMode) -> Void)?
    private var isPasting = false

    /// Only a typed trigger in an empty editor changes mode. Paste is literal.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if isEditable, !isPasting, !hasMarkedText(), string.isEmpty,
           let text, let next = QuickInputMode.trigger(text) {
            changeMode(next)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if isEditable, !hasMarkedText(), string.isEmpty, mode != .search {
            changeMode(.search)
            return
        }
        super.deleteBackward(sender)
    }

    private func changeMode(_ next: QuickInputMode) {
        guard mode != next else { return }
        breakUndoCoalescing()
        let previous = mode
        undoManager?.registerUndo(withTarget: self) { editor in editor.changeMode(previous) }
        mode = next
        onModeChange?(next)
    }

    @discardableResult
    func collapseIfExpanded() -> Bool {
        guard isExpanded, !hasMarkedText() else { return false }
        manuallyCollapsed = true
        forcedExpanded = false
        container?.refresh()
        return true
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func pasteAsPlainText(_ sender: Any?) {
        let previous = isPasting
        isPasting = true
        defer { isPasting = previous }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let previous = isPasting
        isPasting = true
        defer { isPasting = previous }
        return super.readSelection(from: pboard, type: type)
    }
}

final class ModeSearchContainer: NSView {
    let editor = ModeSearchTextView(frame: .zero)
    let scroll = NSScrollView()
    let toggle = NSButton()
    let placeholder = NSTextField(labelWithString: "")
    var onHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 25
    private var refreshing = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editor.container = self
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = editor
        addSubview(scroll)
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = .placeholderTextColor
        placeholder.isSelectable = false
        // Behind the editor so clicks and drag selections reach NSTextView.
        addSubview(placeholder, positioned: .below, relativeTo: scroll)
        toggle.isBordered = false
        toggle.wantsLayer = true
        toggle.layer?.cornerRadius = 4
        toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleExpansion)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 27)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        placeholder.frame = NSRect(x: 0, y: 3, width: width, height: 22)
        toggle.frame = NSRect(x: bounds.width - 23, y: 0, width: 23, height: 24)
        refresh()
    }

    @objc private func toggleExpansion() {
        guard !editor.hasMarkedText() else { return }
        editor.manuallyCollapsed = editor.isExpanded
        editor.forcedExpanded = !editor.isExpanded
        refresh()
        window?.makeFirstResponder(editor)
    }

    func refresh() {
        guard !refreshing, scroll.bounds.width > 1, !editor.hasMarkedText() else { return }
        refreshing = true
        defer { refreshing = false }
        let selection = editor.selectedRanges
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 25
        paragraph.maximumLineHeight = 25
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph, .baselineOffset: 3.5
        ]
        editor.defaultParagraphStyle = paragraph
        if let storage = editor.textStorage {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        editor.typingAttributes = attributes
        editor.selectedRanges = selection

        // Measure wrapped text even while the visible editor is collapsed.
        let storage = NSTextStorage(attributedString: editor.attributedString())
        let manager = NSLayoutManager()
        let measuring = NSTextContainer(size: NSSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude))
        measuring.lineFragmentPadding = 0
        manager.addTextContainer(measuring)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: measuring)
        let lineHeight: CGFloat = 25
        let naturalHeight = max(lineHeight, manager.usedRect(for: measuring).maxY, manager.extraLineFragmentRect.maxY)
        editor.isExpanded = !editor.manuallyCollapsed && (editor.forcedExpanded || naturalHeight > lineHeight + 1)
        let height: CGFloat = editor.isExpanded ? min(max(50, ceil(naturalHeight)), 150) : 25

        let wraps = !editor.manuallyCollapsed
        editor.isHorizontallyResizable = !wraps
        editor.autoresizingMask = wraps ? [.width] : []
        if let container = editor.textContainer {
            container.widthTracksTextView = wraps
            container.containerSize = NSSize(width: wraps ? scroll.bounds.width : 1_000_000, height: .greatestFiniteMagnitude)
            editor.layoutManager?.ensureLayout(for: container)
            let contentWidth = editor.layoutManager?.usedRect(for: container).width ?? 0
            editor.setFrameSize(NSSize(width: wraps ? scroll.bounds.width : max(scroll.bounds.width, contentWidth), height: max(height, naturalHeight)))
        }
        scroll.hasVerticalScroller = editor.isExpanded && naturalHeight > height
        scroll.hasHorizontalScroller = false
        toggle.image = NSImage(systemSymbolName: editor.isExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        toggle.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        toggle.setAccessibilityLabel(L10n.text(editor.isExpanded ? "quick.input.collapse" : "quick.input.expand"))
        toggle.toolTip = L10n.text(editor.isExpanded ? "quick.input.collapse" : "quick.input.expand")
        placeholder.isHidden = !editor.string.isEmpty
        editor.scrollRangeToVisible(editor.selectedRange())
        if reportedHeight != height {
            reportedHeight = height
            onHeightChange?(height)
        }
    }
}

/// Isolated native checks: no clipboard, preferences, history or network writes.
func runModeSearchChecks() -> Bool {
    _ = NSApplication.shared
    let view = ModeSearchContainer(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    var failures = 0
    var count = 0
    func check(_ condition: Bool, _ name: String) {
        count += 1
        if !condition { failures += 1; print("FAIL input: \(name)") }
    }
    var height: CGFloat = 25
    view.onHeightChange = { height = $0 }
    let editor = view.editor
    editor.string = "@ hello"
    view.refresh()
    check(!editor.isExpanded && height == 25, "short text stays single line")
    let text = "@ 请整理以下内容：\n第一项\n第二项\n"
    editor.string = text
    editor.setSelectedRange(NSRange(location: 4, length: 3))
    view.refresh()
    check(editor.isExpanded && height > 24, "explicit newlines expand")
    check(editor.string == text, "newlines preserved")
    check(editor.selectedRange() == NSRange(location: 4, length: 3), "selection preserved")
    check(editor.collapseIfExpanded(), "Escape collapses expanded editor")
    check(height == 25 && editor.string == text, "collapse retains complete text")
    view.refresh()
    check(!editor.isExpanded, "layout does not reopen manual collapse")
    check(!editor.collapseIfExpanded(), "second Escape can close panel")
    editor.manuallyCollapsed = false
    editor.string = String(repeating: "这是中英文 mixed 的长文本。", count: 40)
    view.refresh()
    check(editor.isExpanded && height == 150, "wrapped text capped at six 25pt lines")
    check(view.scroll.hasVerticalScroller, "overflow scrolls vertically")
    editor.string = ""
    editor.forcedExpanded = false
    view.refresh()
    check(!editor.isExpanded && height == 25, "clearing returns to one line")
    check(!view.placeholder.isHidden, "empty editor shows placeholder")
    editor.string = "first\nsecond"
    view.refresh()
    check(editor.isExpanded && !view.scroll.hasVerticalScroller, "two lines expand without overflow")
    check(height == 50, "two lines use explicit 25pt spacing")
    editor.string = ""
    editor.forcedExpanded = true
    view.refresh()
    check(editor.isExpanded && height >= 48, "manual expansion works for empty text")
    editor.string = ""
    editor.forcedExpanded = false
    window.makeFirstResponder(editor)
    editor.undoManager?.removeAllActions()
    editor.insertText("！", replacementRange: NSRange(location: 0, length: 0))
    check(editor.mode == .calculator && editor.string.isEmpty, "full-width trigger changes mode without inserting text")
    check(editor.selectedRange() == NSRange(location: 0, length: 0), "mode trigger leaves caret at original start")
    editor.undoManager?.undo()
    check(editor.mode == .search && editor.string.isEmpty, "undo restores previous mode")
    editor.undoManager?.redo()
    check(editor.mode == .calculator && editor.string.isEmpty, "redo restores calculation mode")
    editor.deleteBackward(nil)
    check(editor.mode == .search, "empty Backspace returns to search")
    editor.insertText("@", replacementRange: NSRange(location: 0, length: 0))
    check(editor.mode == .chat && editor.string.isEmpty, "question trigger is not body text")
    editor.insertText("a@b!", replacementRange: NSRange(location: 0, length: 0))
    check(editor.string == "a@b!" && editor.mode == .chat, "symbols inside body are literal")
    editor.selectAll(nil)
    editor.deleteBackward(nil)
    check(editor.string.isEmpty && editor.mode == .chat, "deleting body retains mode")
    editor.deleteBackward(nil)
    check(editor.mode == .search, "next Backspace exits question mode")
    editor.setMarkedText("@", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
    editor.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
    check(editor.mode == .search && editor.string == "@", "IME marked text is not intercepted")
    editor.string = ""
    editor.undoManager?.removeAllActions()
    editor.insertText("@ pasted question", replacementRange: NSRange(location: 0, length: 0))
    check(editor.mode == .search && editor.string == "@ pasted question", "multi-character insertion remains literal")
    editor.breakUndoCoalescing()
    editor.string = ""
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("@", forType: .string)
    check(editor.readSelection(from: pasteboard, type: .string), "plain text paste imports successfully")
    check(editor.mode == .search && editor.string == "@", "pasted single trigger remains literal")
    pasteboard.releaseGlobally()
    editor.forcedExpanded = false
    editor.breakUndoCoalescing()
    editor.undoManager?.removeAllActions()
    editor.string = "hello"
    view.refresh()
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    editor.insertText(" world", replacementRange: editor.selectedRange())
    view.refresh()
    check(editor.undoManager?.canUndo == true, "styling keeps native undo")
    editor.undoManager?.undo()
    check(editor.string == "hello", "native undo restores input")
    print("\(failures == 0 ? "PASS" : "FAIL") input checks: \(count - failures)/\(count)")
    return failures == 0
}
