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

    var wordBeforeCaret: String? { executor.wordBeforeCaret }

    func endReplacement() {
        executor.endReplacement()
    }
}
