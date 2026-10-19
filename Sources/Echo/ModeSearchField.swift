import AppKit
import SwiftUI

/// A single native editor: prefix spacing is an attribute, never an input character.
struct ModeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focused: Bool
    var enabled: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.isEnabled = enabled
        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true {
            if field.stringValue != text { field.stringValue = text }
            coordinator.style(field)
        }
        let shouldFocus = focused && enabled
        if shouldFocus && !coordinator.requestedFocus {
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator,
                      coordinator.parent.focused, coordinator.parent.enabled else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        coordinator.requestedFocus = shouldFocus
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ModeSearchField
        var requestedFocus = false
        init(_ parent: ModeSearchField) { self.parent = parent }

        func style(_ field: NSTextField) {
            let editor = field.currentEditor() as? NSTextView
            guard editor?.hasMarkedText() != true else { return }
            let value = editor?.string ?? field.stringValue
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor
            ]
            let styled = NSMutableAttributedString(string: value, attributes: base)
            if let first = value.first, ["!", "！", "@"].contains(String(first)) {
                styled.addAttributes([
                    .kern: 6
                ], range: NSRange(value.startIndex..<value.index(after: value.startIndex), in: value))
            }
            if let editor, let storage = editor.textStorage {
                let selection = editor.selectedRanges
                // Attributes only: preserve text, undo history, selection and input semantics.
                storage.beginEditing()
                storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
                if styled.length > 0 {
                    styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                        storage.addAttributes(attrs, range: range)
                    }
                }
                storage.endEditing()
                editor.selectedRanges = selection
                editor.typingAttributes = base
            } else {
                field.attributedStringValue = styled
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            style(field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            (field.currentEditor() as? NSTextView)?.allowsUndo = true
            style(field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
