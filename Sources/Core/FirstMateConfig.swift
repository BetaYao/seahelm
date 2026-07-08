import Foundation

struct FirstMateConfig: Codable, Equatable {
    var enabled: Bool
    var waitingTimeoutSec: Double
    var autoInspect: Bool
    var inspectionCommands: [String]
    var autoReview: Bool
    var autoCommit: Bool
    var channels: [String]

    static let `default` = FirstMateConfig(
        enabled: true,
        waitingTimeoutSec: 30,
        autoInspect: true,
        inspectionCommands: [],
        autoReview: true,
        autoCommit: false,
        channels: ["local"]
    )

    init(enabled: Bool, waitingTimeoutSec: Double, autoInspect: Bool,
         inspectionCommands: [String], autoReview: Bool, autoCommit: Bool,
         channels: [String]) {
        self.enabled = enabled
        self.waitingTimeoutSec = waitingTimeoutSec
        self.autoInspect = autoInspect
        self.inspectionCommands = inspectionCommands
        self.autoReview = autoReview
        self.autoCommit = autoCommit
        self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FirstMateConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        waitingTimeoutSec = try c.decodeIfPresent(Double.self, forKey: .waitingTimeoutSec) ?? d.waitingTimeoutSec
        autoInspect = try c.decodeIfPresent(Bool.self, forKey: .autoInspect) ?? d.autoInspect
        inspectionCommands = try c.decodeIfPresent([String].self, forKey: .inspectionCommands) ?? d.inspectionCommands
        autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? d.autoReview
        autoCommit = try c.decodeIfPresent(Bool.self, forKey: .autoCommit) ?? d.autoCommit
        channels = try c.decodeIfPresent([String].self, forKey: .channels) ?? d.channels
    }
}
