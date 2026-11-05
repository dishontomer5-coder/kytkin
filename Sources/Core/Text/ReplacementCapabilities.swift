// P2-13: The per-app capability cache (001 §2.2, R5 "Detecting which method works").
// Three layers, strongest first: the user's override → this session's verdicts → the shipped seed list.
// In memory only, keyed by bundle ID: capability verdicts are never persisted (design.md invariants,
// 001 §9). Only the user's override lives in preferences (P2-8 `apps.*.replacementMethod`), and the
// composition root passes it in as a plain MethodHint.

import Foundation

struct ReplacementCapabilities: Sendable {
    /// One shipped default. `prefix` matches a bundle-ID family (JetBrains IDEs share `com.jetbrains.`).
    struct Seed: Sendable, Equatable {
        enum Match: Sendable, Equatable { case exact(String), prefix(String) }
        let match: Match
        let hint: MethodHint
    }

    /// Upper bound on remembered session verdicts, so the cache can't grow without limit.
    static let maxSessionEntries = 256

    private var exactSeeds: [String: MethodHint] = [:]
    private var prefixSeeds: [(prefix: String, hint: MethodHint)] = []
    private var overrides: [String: MethodHint] = [:]
    /// Bundles where an AX write reported success but failed read-back this session (R5).
    private var axWriteBroken: Set<String> = []

    init(seeds: [Seed] = ReplacementCapabilities.defaultSeeds, overrides: [String: MethodHint] = [:]) {
        for seed in seeds {
            switch seed.match {
            case .exact(let id): exactSeeds[Self.key(id)] = seed.hint
            case .prefix(let p): prefixSeeds.append((Self.key(p), seed.hint))
            }
        }
        for (id, hint) in overrides { setOverride(hint, for: id) }
    }

    /// The method for an app: user override, else seed, else `.auto`. An empty bundle ID is `.auto`.
    func method(for bundleID: String) -> MethodHint {
        let k = Self.key(bundleID)
        guard !k.isEmpty else { return .auto }
        if let o = overrides[k] { return o }
        if let s = exactSeeds[k] { return s }
        // Longest prefix wins, so a more specific family seed can refine a broader one.
        return prefixSeeds.filter { k.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.hint ?? .auto
    }

    /// True after an AX write in this app returned success but didn't verify. The planner then skips AX.
    func isAXWriteBroken(for bundleID: String) -> Bool {
        axWriteBroken.contains(Self.key(bundleID))
    }

    /// Learn from one executed step. Only an unverified AX write teaches anything: `.unavailable` is about
    /// one field (not settable, timeout), and key steps can't be verified without AX.
    mutating func record(_ verdict: StepVerdict, of step: ReplacementStep, for bundleID: String) {
        let k = Self.key(bundleID)
        guard !k.isEmpty, case .axWriteSelection = step, verdict == .failedVerify else { return }
        if axWriteBroken.count >= Self.maxSessionEntries, !axWriteBroken.contains(k) {
            axWriteBroken.removeAll()   // crude bound; verdicts are cheap to relearn
        }
        axWriteBroken.insert(k)
    }

    /// Settings → Apps changed. nil removes the override.
    mutating func setOverride(_ hint: MethodHint?, for bundleID: String) {
        let k = Self.key(bundleID)
        guard !k.isEmpty else { return }
        overrides[k] = hint
    }

    /// Forget this session's verdicts (e.g. "Reset to defaults" in Settings → Apps).
    mutating func forgetSessionVerdicts() {
        axWriteBroken.removeAll()
    }

    /// Bundle IDs compare case-insensitively (Launch Services does), ignoring surrounding whitespace.
    private static func key(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
