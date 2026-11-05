// P2-8: The pure migration chain for preferences.json (001 §4.1). Each step turns the raw JSON object
// of schema N into schema N+1. Steps work on the raw object, not on `Preferences`, so a step can read
// fields the current model no longer has. Schema v1 is the first version, so `.standard` has no steps
// yet; the first real one (v1 → v2) gets added here with its own fixture.

import Foundation

struct PreferencesMigrator: Sendable {
    /// The JSON object as JSONSerialization produced it. Steps run synchronously inside decode,
    /// so the values never cross an isolation boundary.
    typealias JSONObject = [String: Any]

    struct Step: Sendable {
        /// The schema this step reads. It produces `from + 1`.
        let from: Int
        let migrate: @Sendable (JSONObject) throws -> JSONObject

        init(from: Int, migrate: @escaping @Sendable (JSONObject) throws -> JSONObject) {
            self.from = from
            self.migrate = migrate
        }
    }

    enum Failure: Error, Equatable {
        /// No step reads this version (e.g. a pre-v1 `schemaVersion: 0`).
        case noPath(from: Int)
    }

    /// The version the chain ends at, which is the version this build writes.
    let currentVersion: Int
    private let steps: [Int: Step]

    init(currentVersion: Int, steps: [Step]) {
        self.currentVersion = currentVersion
        var byVersion: [Int: Step] = [:]
        for step in steps { byVersion[step.from] = step }
        self.steps = byVersion
    }

    static let standard = PreferencesMigrator(currentVersion: Preferences.currentSchemaVersion, steps: [])

    /// Runs every step from `version` up to `currentVersion`, stamping `schemaVersion` after each.
    /// A version at or above `currentVersion` is returned unchanged.
    func migrate(_ object: JSONObject, from version: Int) throws -> JSONObject {
        var obj = object
        var v = version
        while v < currentVersion {
            guard let step = steps[v] else { throw Failure.noPath(from: v) }
            obj = try step.migrate(obj)
            v += 1
            obj["schemaVersion"] = v
        }
        return obj
    }
}
