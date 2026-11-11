// P2-21: The main-actor side of convert (001 §12 W9: signals go tap → main → `@TextActor`). AppController calls
// `convert(_:)` on main; this hops each request to the `@TextActor` ConvertController with `Task { @TextActor … }`,
// in order (each task waits for the one before, so generations reach the controller oldest first).
//
// It owns the `LayoutSnapshot` (001 §2.2): built from the LayoutMapProvider on main when the pair or a map changes,
// then handed over as an immutable Sendable value. Toggle-only requests need no maps.
//
// P2-24: the stored pair may name an imported map (P2-32). Before the hop, the request's pair is resolved to the input
// sources Kytkin selects (`LayoutMapProviding.inputSources(for:)`: the map's installed `base`), and the snapshot is
// built from the stored ids' maps under those input-source ids, so ConvertController only ever sees input sources.

import Foundation

@MainActor final class ConvertDispatcher: ConvertControlling {
    let controller: ConvertController
    private let maps: any LayoutMapProviding
    private var cached: (pair: LanguagePair, a: LayoutMap, b: LayoutMap, snapshot: LayoutSnapshot)?
    /// The last hop queued, so the next one runs after it (and tests can await it).
    private(set) var lastTask: Task<Void, Never>?
    /// P3-35 QA (owner): a convert was queued since the last `forgetUndo`, so the controller may hold an undo record.
    private(set) var undoMayBeHeld = false

    init(controller: ConvertController, maps: any LayoutMapProviding) {
        self.controller = controller
        self.maps = maps
    }

    func convert(_ request: ConvertRequest) {
        let layouts = request.mode == .convert ? snapshot(for: request.pair) : nil
        let switchPair = maps.inputSources(for: request.pair)
        let resolved = switchPair == request.pair ? request
            : ConvertRequest(snapshot: request.snapshot, gen: request.gen, bundleID: request.bundleID,
                             mode: request.mode, pair: switchPair, currentSource: request.currentSource,
                             switchAfterConvert: request.switchAfterConvert)
        if request.mode == .convert { undoMayBeHeld = true }   // P3-35 QA (owner)
        enqueue { controller in await controller.handle(resolved, layouts: layouts) }
    }

    /// P3-35 QA (owner): hops after any convert still queued, so a record that convert makes is dropped too. Only when
    /// a convert ran since the last drop (word boundaries call this on every Space; most find nothing to drop).
    func forgetUndo() {
        guard undoMayBeHeld else { return }
        undoMayBeHeld = false
        enqueue { controller in controller.forgetUndoRecord() }
    }

    func methodHintsChanged(_ overrides: [String: MethodHint]) {
        enqueue { controller in controller.setMethodHintOverrides(overrides) }
    }

    /// The pair's converters, rebuilt only when the pair or one of its maps changed (the provider caches maps and
    /// rebuilds them itself on a sources or keyboard-type change). nil = a layout of the pair has no map.
    /// P2-24: `pair` is the stored pair (it may name imported maps); the snapshot's pair is its input sources. nil
    /// also when a member has no input source to switch to, or both type with the same one.
    func snapshot(for pair: LanguagePair) -> LayoutSnapshot? {
        guard let a = maps.map(for: pair.a), let b = maps.map(for: pair.b),
              let sourceA = maps.inputSource(for: pair.a), let sourceB = maps.inputSource(for: pair.b) else {
            cached = nil
            return nil
        }
        if let c = cached, c.pair == pair, c.a == a, c.b == b, c.snapshot.pair == LanguagePair(a: sourceA, b: sourceB) {
            return c.snapshot
        }
        guard let snapshot = LayoutSnapshot(pair: LanguagePair(a: sourceA, b: sourceB), a: a, b: b) else {
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
