/// SWIM Member List Errors
///
/// Typed errors surfaced when a gossiped membership update is rejected by the
/// member list's trust boundary.

/// Reasons a gossiped membership update can be rejected.
///
/// These are *not* silent fallbacks: the member list refuses to apply the update
/// and surfaces the reason so the caller can decide how to react (drop, log,
/// alert).
public enum MemberListRejection: Error, Sendable, Equatable {
    /// The update's incarnation jumped further ahead of the locally known
    /// incarnation than the configured sanity bound allows.
    ///
    /// This guards against a peer forging an implausibly high incarnation to win
    /// every conflict (e.g. to mark a member dead or to make itself
    /// undetectable).
    ///
    /// - Parameters:
    ///   - memberID: The member the update was about.
    ///   - known: The locally known incarnation (or `.initial` for an unknown member).
    ///   - proposed: The incarnation carried by the rejected update.
    ///   - maxDelta: The configured maximum allowed forward delta.
    case incarnationJumpTooLarge(
        memberID: MemberID,
        known: Incarnation,
        proposed: Incarnation,
        maxDelta: UInt64
    )

    /// Admitting this new member would exceed the configured maximum
    /// member-table size.
    ///
    /// This bounds memory growth from a flood of forged `alive` members that GC
    /// (which only collects dead members) would never reclaim.
    ///
    /// - Parameters:
    ///   - memberID: The member the rejected join was about.
    ///   - limit: The configured maximum member count.
    case memberTableFull(memberID: MemberID, limit: Int)
}

extension MemberListRejection: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .incarnationJumpTooLarge(memberID, known, proposed, maxDelta):
            return "IncarnationJumpTooLarge(\(memberID.id): known=\(known.value), proposed=\(proposed.value), maxDelta=\(maxDelta))"
        case let .memberTableFull(memberID, limit):
            return "MemberTableFull(\(memberID.id): limit=\(limit))"
        }
    }
}
