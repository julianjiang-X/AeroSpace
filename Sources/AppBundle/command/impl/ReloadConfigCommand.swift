import AppKit
import Common

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let result = await reloadConfig_nonCancellable(args: args)
        if !result.stdout.isEmpty {
            io.out(result.stdout)
        }
        if !result.stderr.isEmpty {
            io.err(result.stderr)
        }
        return .from(bool: result.isOk)
    }
}

struct ReloadConfigResult {
    let isOk: Bool
    let stdout: String
    let stderr: String
}

// Startup loads the bundled defaults and then the user's config before any app/window caches exist.
// Once those caches are live, changing compatibility identity or classification needs a restart.
@MainActor private var compatibilityRulesLocked = false

@MainActor func lockCompatibilityRulesForRuntime() {
    compatibilityRulesLocked = true
}

func configReloadErrors(
    _ parsed: ParseConfigResult,
    currentRules: [CompatibilityRule],
    rulesLocked: Bool,
    warningsAsErrors: Bool,
) -> [ConfigParseDiagnostic] {
    var errors = parsed.errors
    if warningsAsErrors { errors += parsed.warnings }
    if errors.isEmpty && rulesLocked && parsed.config.compatibilityRules != currentRules {
        errors.append(.init(
            .rootKey("compatibility-rules"),
            "Changing compatibility-rules requires an AeroSpace restart. The entire last valid config remains active.",
            preventConfigReload: true,
        ))
    }
    return errors
}

@MainActor func reloadConfig_nonCancellable(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
) async -> ReloadConfigResult {
    let result = readConfig(forceConfigUrl: forceConfigUrl)
    let parseResult = result.parseConfigResult
    let warningsAsErrors = args.warningsAsErrors

    let reloadErrors = configReloadErrors(
        parseResult,
        currentRules: config.compatibilityRules,
        rulesLocked: compatibilityRulesLocked,
        warningsAsErrors: warningsAsErrors,
    )
    let errors = reloadErrors.map { $0.description(.error) }
    let warnings = warningsAsErrors ? [] : parseResult.warnings.map { $0.description(.warning) }
    let containsWarnings = !parseResult.warnings.isEmpty

    if !args.noGui && !args.dryRun {
        let lines = errors + warnings
        switch true {
            case !errors.isEmpty:
                let msg = failedToReloadMsg(configUrl: result.configUrl, errorsCount: reloadErrors.count, warningsCount: parseResult.warnings.count, lines: lines)
                MessageModel.shared.message = Message(body: msg, containsWarnings: containsWarnings)
            default:
                MessageModel.shared.message = nil
        }
    }
    if errors.isEmpty && !args.dryRun {
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = containsWarnings
        resetHotKeys()
        config = parseResult.config
        configUrl = result.configUrl
        WorkspaceAffinity.configurationDidChange()
        await activateMode_nonCancellable(activeMode)
        syncStartAtLogin()
        syncFocusFollowsMouse(config)
        syncConfigFileWatcher()
    }

    return ReloadConfigResult(
        isOk: errors.isEmpty,
        stdout: errors.joined(separator: "\n\n"),
        stderr: warnings.joined(separator: "\n\n"),
    )
}

private func failedToReloadMsg(configUrl: URL, errorsCount: Int, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Failed to reload \(path). \(errorsCount) error(s). \(warningsCount) warning(s)"
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}
