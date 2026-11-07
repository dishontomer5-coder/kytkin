// P2-21: The main-actor side of convert (001 §12 W9: signals go tap → main → `@TextActor`). AppController calls
// `convert(_:)` on main; this hops each request to the `@TextActor` ConvertController with `Task { @TextActor … }`,
// in order (each task waits for the one before, so generations reach the controller oldest first).
//
// It owns the `LayoutSnapshot` (001 §2.2): built from the LayoutMapProvider on main when the pair or a map changes,
// then handed over as an immutable Sendable value. Toggle-only requests need no maps.

import Foundation

@MainActor final class ConvertDispatcher: ConvertControlling {
    let controller: ConvertController
    private let maps: any LayoutMapProviding
    private var cached: (pair: LanguagePair, a: LayoutMap, b: LayoutMap, snapshot: LayoutSnapshot)?
    /// The last hop queued, so the next one runs after it (and tests can await it).
    private(set) var lastTask: Task<Void, Never>?

    init(controller: ConvertController, maps: any LayoutMapProviding) {
        self.controller = controller
        self.maps = maps
    }

    func convert(_ request: ConvertRequest) {
        let layouts = request.mode == .convert ? snapshot(for: request.pair) : nil
        enqueue { controller in await controller.handle(request, layouts: layouts) }
    }

    func methodHintsChanged(_ overrides: [String: MethodHint]) {
        enqueue { controller in controller.setMethodHintOverrides(overrides) }
    }

    /// The pair's converters, rebuilt only when the pair or one of its maps changed (the provider caches maps and
    /// rebuilds them itself on a sources or keyboard-type change). nil = a layout of the pair has no map.
    func snapshot(for pair: LanguagePair) -> LayoutSnapshot? {
        guard let a = maps.map(for: pair.a), let b = maps.map(for: pair.b) else {
            cached = nil
            return nil
        }
        if let c = cached, c.pair == pair, c.a == a, c.b == b { return c.snapshot }
        guard let snapshot = LayoutSnapshot(pair: pair, a: a, b: b) else {
            cached = nil
            return nil
        }
        cached = (pair, a, b, snapshot)
        return snapshot
    }

    private func enqueue(_ work: @escaping @TextActor @Sendable (ConvertController) async -> Void) {
        let previous = lastTask
        let controller = self.controller
        lastTask = Task { @TextActor in
            await previous?.value
            await work(controller)
        }
    }
}
