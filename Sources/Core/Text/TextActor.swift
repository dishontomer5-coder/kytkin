// P2-18: The text-replacement isolation domain (001 §2.1). A custom global actor on its own serial dispatch
// queue (`io.github.kytkin.text`, macOS 14 `DispatchSerialQueue` executor), so AX calls with their 0.25 s
// timeout and synthetic key posting never run on the main actor or the tap thread.

import Foundation

@globalActor actor TextActor {
    static let shared = TextActor()

    private let queue = DispatchSerialQueue(label: "io.github.kytkin.text", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}
