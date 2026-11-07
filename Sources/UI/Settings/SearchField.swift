// P3-15 (P3-12 QA note): a real NSSearchField for the Rules search box. Esc clears only search fields
// (`EscapeKeyAction`, `KytkinWindow`), and the window tells a search field from any other field by its NSSearchField,
// so a plain SwiftUI TextField would no longer be cleared by Esc.

import AppKit
import SwiftUI

struct SearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeNSView(context: NSViewRepresentableContext<SearchField>) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: NSViewRepresentableContext<SearchField>) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
