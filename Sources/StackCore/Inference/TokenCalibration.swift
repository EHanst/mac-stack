import Foundation

/// Learns how many characters make up a token for the text in this conversation, from the token
/// counts the model reports, so compaction and trimming don't fire at half the real limit.
///
/// `InferenceService.estimateTokens` assumes 2.5 characters per token on purpose (pessimistic for
/// code), which over-counted by about 1.6× on real chats. That estimate stays the starting point and
/// the floor; the provider's own pre-flight check is still the hard guard against oversize prompts.
/// Calibration only decides *when to compact*.
public struct TokenCalibration: Sendable, Equatable {

    public static let floorCharsPerToken = 2.5
    public static let ceilingCharsPerToken = 4.0
    /// Below this many prompt tokens the chat template's fixed tokens dominate the ratio.
    public static let minimumSample = 200

    public private(set) var charsPerToken = TokenCalibration.floorCharsPerToken
    private var previous: Double?

    public init() {}

    /// Record one request: `chars` of message content became `promptTokens` tokens. The lower of the
    /// last two ratios is used, so one prose-heavy turn can't make a code-heavy stretch look cheap.
    public mutating func observe(chars: Int, promptTokens: Int) {
        guard promptTokens >= Self.minimumSample, chars > 0 else { return }
        let measured = min(max(Double(chars) / Double(promptTokens), Self.floorCharsPerToken), Self.ceilingCharsPerToken)
        charsPerToken = min(measured, previous ?? measured)
        previous = measured
    }

    public func tokens(chars: Int) -> Int { Int((Double(chars) / charsPerToken).rounded(.up)) }
    public func tokens(of messages: [Message]) -> Int { tokens(chars: messages.reduce(0) { $0 + $1.content.count }) }
}
