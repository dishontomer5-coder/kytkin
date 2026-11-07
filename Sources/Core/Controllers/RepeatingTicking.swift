// P2-20: A repeating main-actor tick for the learner's 4 s dwell (001 §6.2: no word buffer → confirm by dwell).
// AppController runs it only while a candidate waits for a dwell, so an idle Kytkin has no timer. The real one
// (`MainRunLoopTicker`, App) is a main-run-loop Timer; tests use a fake.

import Foundation

@MainActor protocol RepeatingTicking: AnyObject {
    var isRunning: Bool { get }
    func start(_ handler: @escaping @MainActor () -> Void)
    func stop()
}
