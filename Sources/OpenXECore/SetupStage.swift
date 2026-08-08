import Foundation

/// Retry behaviour for one stage (spec §9.2). Network stages retry
/// automatically and visibly; subprocess stages do not, because
/// re-running a failed multi-second Wine operation rarely helps.
public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let jitter: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval = 0,
                multiplier: Double = 1, jitter: Double = 0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    public static let none = RetryPolicy(maxAttempts: 1)
    public static let network = RetryPolicy(maxAttempts: 3, baseDelay: 2,
                                            multiplier: 4, jitter: 0.25)

    /// Delay before `attempt` (1-based). Attempt 1 is immediate.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let base = baseDelay * pow(multiplier, Double(attempt - 2))
        guard jitter > 0 else { return base }
        return base * (1 + Double.random(in: -jitter...jitter))
    }
}

/// One user-visible stage of first-run setup (spec §4.2).
public struct SetupStage: Sendable, Equatable {
    public enum ID: String, Codable, Sendable, CaseIterable {
        case preflight, downloadEngine, unpackEngine, preparePrefix, downloadNWS, installNWS
    }

    public let id: ID
    public let displayName: String
    public let weight: Int
    public let resumable: Bool
    public let retry: RetryPolicy
    public let hardCeiling: TimeInterval
}

/// Stage weights as DATA, not logic (spec §4.2). Cold-machine calibration is
/// deferred, so these will need correcting later on evidence we do not yet
/// have — via `defaults write dev.openxe.OpenXE OpenXEStageWeights`, with no
/// rebuild. An ad-hoc-signed bundle cannot have a bundled resource edited
/// without invalidating its signature, which is why the override lives in
/// UserDefaults rather than a plist in Resources.
public enum StageWeightTable {

    /// Share of a 241 s reference run (spec §3.1, §3.2). Assumes batched font
    /// provisioning (spec §5.3). MUST sum to 100.
    public static let builtIn: [SetupStage.ID: Int] = [
        .preflight: 1, .downloadEngine: 37, .unpackEngine: 25,
        .preparePrefix: 12, .downloadNWS: 10, .installNWS: 15,
    ]

    public static let defaultsKey = "OpenXEStageWeights"

    /// Resolution order: validated UserDefaults override, then built-in.
    /// An override is accepted only if it names every stage exactly once, all
    /// values are positive, and they sum to 100. Anything else is ignored and
    /// logged, so a bad edit degrades to the shipped defaults.
    public static func resolve(override: [String: Int]?) -> [SetupStage.ID: Int] {
        guard let override else { return builtIn }
        var parsed: [SetupStage.ID: Int] = [:]
        for (key, value) in override {
            guard let id = SetupStage.ID(rawValue: key), value > 0 else { return builtIn }
            guard parsed[id] == nil else { return builtIn }
            parsed[id] = value
        }
        guard parsed.count == SetupStage.ID.allCases.count,
              parsed.values.reduce(0, +) == 100 else { return builtIn }
        return parsed
    }

    public static func resolveFromDefaults() -> [SetupStage.ID: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int]
        let resolved = resolve(override: raw)
        if raw != nil, resolved == builtIn {
            NSLog("OpenXE: ignoring invalid %@ override; using built-in weights", defaultsKey)
        }
        return resolved
    }
}

/// The six stages, their weights, and their policies.
public enum SetupCatalog {

    private static let weights = StageWeightTable.resolveFromDefaults()

    public static let all: [SetupStage] = [
        SetupStage(id: .preflight, displayName: "Checking your Mac",
                   weight: weights[.preflight]!, resumable: false,
                   retry: .none, hardCeiling: 15),
        SetupStage(id: .downloadEngine, displayName: "Downloading the Windows environment",
                   weight: weights[.downloadEngine]!, resumable: true,
                   retry: .network, hardCeiling: 60),
        SetupStage(id: .unpackEngine, displayName: "Unpacking the Windows environment",
                   weight: weights[.unpackEngine]!, resumable: false,
                   retry: .none, hardCeiling: 900),
        SetupStage(id: .preparePrefix, displayName: "Preparing the Windows environment",
                   weight: weights[.preparePrefix]!, resumable: false,
                   retry: .none, hardCeiling: 900),
        SetupStage(id: .downloadNWS, displayName: "Downloading New World Scheduler",
                   weight: weights[.downloadNWS]!, resumable: true,
                   retry: .network, hardCeiling: 600),
        SetupStage(id: .installNWS, displayName: "Installing New World Scheduler",
                   weight: weights[.installNWS]!, resumable: false,
                   retry: .none, hardCeiling: 1200),
    ]

    /// The `.exe` launch path needs setup only through the prefix (spec §7.4).
    public static let launchPathSubset: [SetupStage] =
        all.filter { $0.id != .downloadNWS && $0.id != .installNWS }

    /// Weights rescaled to sum to 100 over a subset. The last entry absorbs
    /// the rounding remainder so the total is exact.
    public static func renormalisedWeights(for stages: [SetupStage]) -> [Int] {
        let total = stages.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return stages.map { _ in 0 } }
        var out = stages.map { Int((Double($0.weight) / Double(total) * 100).rounded()) }
        if let last = out.indices.last {
            out[last] += 100 - out.reduce(0, +)
        }
        return out
    }
}
