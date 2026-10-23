import SwiftUI

/// A number field that commits on Return or when focus leaves.
///
/// It follows `value` unless the user is partway through typing a different one. After a commit it shows the
/// value as it then is: the edit's result once it lands, or the old value if the edit was refused.
struct NumericField: View {
    let label: String
    let value: Double
    /// The smallest change worth committing.
    let tolerance: Double
    let format: (Double) -> String
    let parse: (String) -> Double?
    let commit: (Double) -> Void

    @State private var text = ""
    /// The text last shown for `value`; anything else in the field is uncommitted typing.
    @State private var shown = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(apply)
            .onChange(of: isFocused) { _, focused in if !focused { apply() } }
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused || text == shown { show(newValue) }
            }
    }

    private func apply() {
        if let number = parse(text.trimmingCharacters(in: .whitespaces)), abs(number - value) >= tolerance {
            commit(number)
        }
        // `value` is still the old one here. A committed edit's result arrives through onChange, which
        // replaces this because the field then shows exactly what it last set.
        show(value)
    }

    private func show(_ number: Double) {
        text = format(number)
        shown = text
    }
}
