public struct WorkspaceRuleCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceRule,
        help: """
            USAGE: workspace-rule (status|pause|resume) [--window-id <window-id>] [--json]
            status is read-only and prints JSON metadata.
            pause/resume without --window-id controls all workspace-rule enforcement.
            A window pause remains until resume or the window closes.
            """,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [newMandatoryPosArgParser(\.action, parseWorkspaceRuleAction, placeholder: Action.unionLiteral)]
    )
    public enum Action: String, CaseIterable, Sendable { case status, pause, resume }
    public var action: Lateinit<Action> = .uninitialized
    public var json = false
}

private func parseWorkspaceRuleAction(_ input: PosArgParserInput) -> ParsedCliArgs<WorkspaceRuleCmdArgs.Action> {
    .init(parseEnum(input.arg, WorkspaceRuleCmdArgs.Action.self), advanceBy: 1)
}
