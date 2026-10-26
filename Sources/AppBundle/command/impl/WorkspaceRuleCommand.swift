import Common
import Foundation

struct WorkspaceRuleCommand: Command {
    let args: WorkspaceRuleCmdArgs
    let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        switch args.action.val {
            case .status:
                if let id = args.windowId, MacWindow.allWindowsMap[id] == nil {
                    return .fail(io.err("No registered window with that window-id"))
                }
            case .pause, .resume:
                guard !serverArgs.isReadOnly else { return .fail(io.err("AeroSpace is read-only")) }
                guard WorkspaceAffinity.setPaused(args.action.val == .pause, windowID: args.windowId) else {
                    return .fail(io.err("No registered window with that window-id"))
                }
        }
        guard let text = JSONEncoder.aeroSpaceDefault.encodeToString(WorkspaceAffinity.diagnostics(windowID: args.windowId)) else {
            return .fail(io.err("Unable to encode workspace-rule status"))
        }
        return .succ(io.out(text))
    }
}
