/// A correction may have changed an earlier window before a later native read
/// suspends. Its caller must not treat "changed" as permission to lay out after a
/// newer session has started. Independent passes also require exclusive depth.
struct WorkspaceAffinitySessionGate {
    struct Token: Sendable, Equatable {
        let generation: UInt64
    }

    private(set) var generation: UInt64 = 0

    mutating func begin() -> Token {
        invalidate()
        return Token(generation: generation)
    }

    mutating func invalidate() { generation &+= 1 }

    func allowsLayout(_ token: Token, activeDepth: Int, independent: Bool, cancelled: Bool) -> Bool {
        !cancelled && token.generation == generation && (!independent || activeDepth == 1)
    }
}
