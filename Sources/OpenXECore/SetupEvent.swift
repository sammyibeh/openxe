import Foundation

/// The unified outward progress stream (spec §4.1). Replaces EngineProgress
/// and NWSProgress as the contract the UI consumes; components keep their own
/// narrow callbacks and the coordinator maps them into this.
public enum SetupEvent: Sendable {
    case stageBegan(SetupStage.ID, index: Int, of: Int)
    /// `fraction` nil means indeterminate.
    case stageProgress(SetupStage.ID, fraction: Double?, detail: String)
    case stageCompleted(SetupStage.ID, elapsed: TimeInterval)
    case overall(fraction: Double, elapsed: TimeInterval, remaining: TimeInterval?)
    case attempt(SetupStage.ID, number: Int, of: Int, reason: String)
    case stalled(SetupStage.ID, silentFor: TimeInterval)
    case recovered(SetupStage.ID)
    case failed(SetupFailure)
    case cancelled(SetupStage.ID)
    case finished
}

/// A setup failure in terms the UI can render without knowing about Wine
/// (spec §9.1). Existing EngineError/PrefixError/NWSError are wrapped, not
/// replaced.
public struct SetupFailure: Error, Sendable {
    public enum Kind: String, Codable, Sendable {
        case diskSpace, rosettaMissing, network, rateLimited, integrity,
             subprocessFailed, timedOut, stalled, environmentIncomplete, internalError
    }

    public let stage: SetupStage.ID
    public let kind: Kind
    public let userMessage: String
    public let suggestedAction: String
    public let technicalDetail: String
    public let isRetryable: Bool

    public init(stage: SetupStage.ID, kind: Kind, userMessage: String,
                suggestedAction: String, technicalDetail: String, isRetryable: Bool) {
        self.stage = stage
        self.kind = kind
        self.userMessage = userMessage
        self.suggestedAction = suggestedAction
        self.technicalDetail = technicalDetail
        self.isRetryable = isRetryable
    }
}
