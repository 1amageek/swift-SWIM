/// SWIM Message Authenticator
///
/// Optional message-authentication hook for the SWIM wire protocol.
///
/// This protocol lives in the `SWIM` adapter (not `SWIMWire`): its `sign`
/// requirement uses untyped `throws` so that conformers may surface any backend
/// error, which is incompatible with Embedded Swift's typed-throws-only
/// requirement. Only `verify` is consumed by the orchestration layer; the
/// concrete HMAC authenticator (using the `MessageAuthenticationCode` seam) is
/// also an adapter concern.
//
// HOST-ONLY: this protocol is consumed only through the `any SWIMMessageAuthenticator`
// existential on `SWIMConfiguration`, which is rejected under Embedded Swift, so
// the whole file is gated `#if !hasFeature(Embedded)`. (Its `sign` requirement
// also uses untyped `throws`, itself unavailable under Embedded.) The Embedded
// build runs SWIM in unauthenticated mode (sanity bounds only).

#if !hasFeature(Embedded)
import SWIMWire

/// Authenticates SWIM datagrams.
///
/// SWIM is, by default, an *unauthenticated* gossip protocol: any peer that can
/// reach the cluster can forge membership updates (e.g. claim a higher
/// incarnation to mark a member dead, or to make itself undetectable). This is
/// inherent to plain SWIM.
///
/// Conform to this protocol and inject an instance via
/// ``SWIMConfiguration/authenticator`` to make the trust boundary explicit:
/// - Outgoing canonical authentication bytes are signed via ``sign(messageBytes:)``.
/// - Incoming canonical authentication bytes and their transmitted token are verified
///   via ``verify(messageBytes:token:)`` *before* their
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
///   respect to ``verify(messageBytes:token:)`` so the same datagram always
///   yields the same decision.
public protocol SWIMMessageAuthenticator: Sendable {
    /// Signs an outgoing canonical authentication encoding.
    ///
    /// The returned token is attached to the encoded datagram's authenticated
    /// envelope. The bytes include the claimed sender identity and the canonical
    /// inner message, so a signed datagram cannot be replayed from another sender.
    ///
    /// - Parameter messageBytes: The canonical encoding of the message about to
    ///   be sent.
    /// - Returns: An authentication token to transmit alongside the message.
    /// - Throws: If signing fails (e.g. key material unavailable).
    func sign(messageBytes: [UInt8]) throws -> [UInt8]

    /// Verifies an incoming canonical authentication encoding and transmitted token.
    ///
    /// - Parameters:
    ///   - messageBytes: The canonical authentication bytes containing the sender
    ///     identity and decoded inner message.
    ///   - token: The token transmitted in the authenticated envelope.
    /// - Returns: `true` if the message is authentic and may be trusted.
    func verify(messageBytes: [UInt8], token: [UInt8]) -> Bool
}
#endif
