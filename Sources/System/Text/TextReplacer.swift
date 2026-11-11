// P2-18: The live text replacer (001 §2.2 `TextReplacer`, System/Text). It plugs the real AX and CGEvent
// adapters into Core's `ReplacementExecutor`, where every decision lives (and is unit-tested with fakes).
// Runs on @TextActor (001 §2.1). The composition root (P2-20/P2-21) creates one; nothing wires it yet.
// Not compiled into the test target.

import Foundation

@TextActor final class TextReplacer: TextReplacing {
    private let executor = ReplacementExecutor(focusProvider: AXFocusedElementProvider(), poster: CGEventKeyPoster())

    init() {}

    func focusInfo(timeout: Double = ReplacementExecutor.axTimeout) -> FocusInfo? {
        executor.focusInfo(timeout: timeout)
    }

    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome {
        executor.perform(step, old: old, new: new)
    }

    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        executor.readRunBeforeCaret(maxChars: maxChars, locate: locate)
    }

    func readField(maxChars: Int, locate: (FieldWindow) -> FieldEdit?) -> StepOutcome {
        executor.readField(maxChars: maxChars, locate: locate)
    }

    var wordBeforeCaret: String? { executor.wordBeforeCaret }

    var readRangeEndsAtCaret: Bool { executor.readRangeEndsAtCaret }

    var focusedElement: (any FocusedElementIdentity)? { executor.focusedElement }

    func endReplacement() {
        executor.endReplacement()
    }

    func currentFocusedElement(timeout: Double) -> (any FocusedElementIdentity)? {   // P3-37
        executor.currentFocusedElement(timeout: timeout)
    }
}
