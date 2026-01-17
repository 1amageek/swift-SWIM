/// SWIM Events
///
/// Events emitted by the SWIM instance for observers.

/// Events emitted by a SWIM instance.
///
/// Subscribe to these events to react to membership changes in the cluster.
public enum SWIMEvent: Sendable {
    /// A new member joined the cluster.
    case memberJoined(Member)

    /// A member is now suspected of being failed.
    ///
    /// The member may still be alive and could recover.
    case memberSuspected(Member)

    /// A member has been confirmed as failed.
    ///
    /// The member did not respond within the suspicion timeout.
    case memberFailed(Member)

    /// A member recovered from suspect state.
    ///
    /// The member responded or sent a higher incarnation message.
    case memberRecovered(Member)

    /// A member left the cluster gracefully.
    case memberLeft(MemberID)

    /// The local member's incarnation was incremented.
    ///
    /// This happens when refuting a suspicion about ourselves.
    case incarnationIncremented(Incarnation)

    /// An error occurred in the SWIM protocol.
    case error(SWIMError)
}

extension SWIMEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .memberJoined(let member):
            return "MemberJoined(\(member.id))"
        case .memberSuspected(let member):
            return "MemberSuspected(\(member.id))"
        case .memberFailed(let member):
            return "MemberFailed(\(member.id))"
        case .memberRecovered(let member):
            return "MemberRecovered(\(member.id))"
        case .memberLeft(let id):
            return "MemberLeft(\(id))"
        case .incarnationIncremented(let inc):
            return "IncarnationIncremented(\(inc))"
        case .error(let error):
            return "Error(\(error))"
        }
    }
}

// MARK: - SWIM Errors

/// Errors that can occur in the SWIM protocol.
public enum SWIMError: Error, Sendable {
    /// Failed to send a message.
    case sendFailed(to: MemberID, underlying: Error)

    /// Join operation failed.
    case joinFailed(reason: String)

    /// Transport error.
    case transportError(String)

    /// Protocol error (invalid message, etc).
    case protocolError(String)
}

extension SWIMError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sendFailed(let to, let error):
            return "SendFailed(to: \(to), error: \(error))"
        case .joinFailed(let reason):
            return "JoinFailed(\(reason))"
        case .transportError(let msg):
            return "TransportError(\(msg))"
        case .protocolError(let msg):
            return "ProtocolError(\(msg))"
        }
    }
}
