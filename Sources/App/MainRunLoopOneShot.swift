// P2-52 item 1: The real `OneShotScheduling`: a non-repeating main-run-loop Timer (.common, so it also fires while a
// menu is open). Used for the second look at the frontmost app after Kytkin resigns.

import Foundation

@MainActor final class MainRunLoopOneShot: OneShotScheduling {
    private var timer: Timer?

    func schedule(afterNanos: UInt64, _ handler: @escaping @MainActor () -> Void) {
        cancel()
        let timer = Timer(timeInterval: TimeInterval(afterNanos) / 1_000_000_000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
