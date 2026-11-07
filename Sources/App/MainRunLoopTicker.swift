// P2-20: The real `RepeatingTicking`: a 0.5 s main-run-loop Timer (.common, so it keeps running while a menu is
// open). Runs only while the learner waits for a 4 s dwell.

import Foundation

@MainActor final class MainRunLoopTicker: RepeatingTicking {
    static let interval: TimeInterval = 0.5
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start(_ handler: @escaping @MainActor () -> Void) {
        stop()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
