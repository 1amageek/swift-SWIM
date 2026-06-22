/// SWIM Message Authenticator
///
/// Optional message-authentication hook for the SWIM wire protocol.

import Foundation

/// Authenticates SWIM datagrams.
///
/// SWIM is, by default, an *unauthenticated* gossip protocol: any peer that can
/// reach the cluster can forge membership updates (e.g. claim a higher
/// incarnation to mark a member dead, or to make itself undetectable). This is
/// inherent to plain SWIM.
///
/// Conform to this protocol and inject an instance via
/// ``SWIMConfiguration/authenticator`` to make the trust boundary explicit:
/// - Outgoing messages are signed via ``sign(message:)``.
/// - Incoming messages are verified via ``verify(message:)`` *before* their
///   gossip is trusted. Datagrams that fail verification are rejected and never
///   applied to the member list.
///
/// When no authenticator is configured, the instance operates in the
/// traditional unauthenticated mode and the residual limitation applies: gossip
/// is trusted up to the configured sanity bounds
/// (``SWIMConfiguration/maxIncarnationDelta`` and
/// ``SWIMConfiguration/maxMemberCount``) only.
///
/// - Note: Implementations must be deterministic and side-effect free with
///   respect to ``verify(message:)`` so the same datagram always yields the same
///   decision.
public protocol SWIMMessageAuthenticator: Sendable {
    /// Signs an outgoing message.
    ///
    /// The returned token is attached to the encoded datagram by the transport
    /// integration layer. Implementations typically compute a MAC/signature over
    /// the canonical encoding of `message`.
    ///
    /// - Parameter message: The message about to be sent.
    /// - Returns: An authentication token to transmit alongside the message.
    /// - Throws: If signing fails (e.g. key material unavailable).
    func sign(message: SWIMMessage) throws -> [UInt8]

    /// Verifies an incoming message.
    ///
    /// - Parameter message: The decoded message whose authenticity is in question.
    /// - Returns: `true` if the message is authentic and may be trusted.
    func verify(message: SWIMMessage) -> Bool
}
