// P2-17: KeyWatcher with the real CGEventTap backend. Kept apart (and excluded from the test target in
// project.yml) so tests can only ever build a KeyWatcher with a fake backend: no test installs a tap.

import Foundation

extension KeyWatcher {
    /// The app's KeyWatcher (P2-20 builds it in AppEnvironment).
    convenience init(processor: KeyStreamProcessor,
                     onSignal: @Sendable @escaping (KeySignal) -> Void,
                     onStatus: @Sendable @escaping (KeyWatcherStatus) -> Void = { _ in }) {
        self.init(processor: processor, clock: SystemClock(), makeBackend: { CGEventTapBackend(runLoop: $0) },
                  onSignal: onSignal, onStatus: onStatus)
    }
}
