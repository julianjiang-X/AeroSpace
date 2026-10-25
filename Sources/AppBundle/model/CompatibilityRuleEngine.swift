import AppKit
import Foundation

struct CompatibilityProcessIdentity: Sendable, Equatable {
    let appId: String?
    let bundlePath: String?
    let executablePath: String?

    init(appId: String?, bundlePath: String?, executablePath: String?) {
        self.appId = appId
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }

    init(_ app: NSRunningApplication) {
        self.init(appId: app.bundleIdentifier, bundlePath: app.bundleURL?.path, executablePath: app.executableURL?.path)
    }
}

struct CompatibilityProcessResolution: Sendable {
    let pid: pid_t
    let recoveryRule: CompatibilityRule?
}

enum CompatibilityRuleEngine {
    /// Native positive PIDs remain authoritative and do not consult CG or proc.
    static func resolveProcess(
        rules: [CompatibilityRule],
        reportedPID: pid_t,
        identity: CompatibilityProcessIdentity,
        ownerPIDs: () -> [pid_t],
        processPath: (pid_t) -> String?,
    ) -> CompatibilityProcessResolution? {
        if reportedPID > 0 { return .init(pid: reportedPID, recoveryRule: nil) }
        guard let rule = rules.first(where: {
            $0.phase == .application && $0.action.recoverPid == .windowOwner &&
                $0.match.appId != nil && $0.match.bundlePath != nil && $0.match.executablePath != nil &&
                matchesProcess($0.match, identity)
        }), let executablePath = rule.match.executablePath else { return nil }
        let candidates = Set(ownerPIDs().filter { $0 > 0 }).filter { pid in
            pathsMatch(processPath(pid), executablePath)
        }
        guard candidates.count == 1, let pid = candidates.first else { return nil }
        return .init(pid: pid, recoveryRule: rule)
    }

    /// Resolve process identity once per registered app. Keep only matching
    /// rules, never raw argv; arguments are read lazily and at most once.
    static func windowRules(
        rules: [CompatibilityRule],
        identity: CompatibilityProcessIdentity,
        arguments: () -> [String]?,
    ) -> CompatibilityWindowRules {
        var argumentWasRead = false
        var firstExecutable: String?
        let matched = rules.filter { rule in
            guard rule.isValidFloatingWindowRule, matchesProcess(rule.match, identity)
            else { return false }
            if let executables = rule.match.firstExeArgument {
                if !argumentWasRead {
                    argumentWasRead = true
                    firstExecutable = arguments()?.first(where: { $0.lowercased().hasSuffix(".exe") })?
                        .replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased()
                }
                guard let firstExecutable, executables.contains(where: { $0.lowercased() == firstExecutable }) else { return false }
            }
            return true
        }
        return .init(rules: matched)
    }

    private static func matchesProcess(_ match: CompatibilityRule.Match, _ identity: CompatibilityProcessIdentity) -> Bool {
        if let appId = match.appId, identity.appId != appId { return false }
        if let absent = match.appIdAbsent, (identity.appId == nil) != absent { return false }
        if let bundlePath = match.bundlePath, !pathsMatch(identity.bundlePath, bundlePath) { return false }
        if let executablePath = match.executablePath, !pathsMatch(identity.executablePath, executablePath) { return false }
        return true
    }

    static func pathsMatch(_ actual: String?, _ expected: String) -> Bool {
        guard let actual, actual.hasPrefix("/"), expected.hasPrefix("/") else { return false }
        // URL equality also compares directory hints/trailing slashes. Identity
        // here is the filesystem path, so equivalent directory URLs must match.
        return URL(filePath: actual).standardizedFileURL.resolvingSymlinksInPath().path ==
            URL(filePath: expected).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct CompatibilityWindowRules: Sendable {
    static let empty = Self(rules: [])
    let rules: [CompatibilityRule]

    func matchedRule(
        role: String?, subrole: String?, title: String?, size: CGSize?,
        activationPolicy: NSApplication.ActivationPolicy,
        windowLevel: MacOsWindowLevel?, nativeFullscreen: Bool?,
    ) -> CompatibilityRule? {
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return rules.first { rule in
            let match = rule.match
            guard rule.isValidFloatingWindowRule,
                  let title, match.windowTitle?.contains(title) == true,
                  let requiredRole = match.axRole, let requiredSubrole = match.axSubrole,
                  requiredRole == role, requiredSubrole == subrole else { return false }
            if match.activationPolicy == .regular, activationPolicy != .regular { return false }
            if let required = match.nativeFullscreen, nativeFullscreen != required { return false }
            if let levels = match.windowLevel {
                let level: Int? = switch windowLevel {
                    case .normalWindow: 0
                    case .alwaysOnTopWindow: 3
                    case .unknown(let value): value
                    case nil: nil
                }
                guard let level, levels.contains(level) else { return false }
            }
            if let minimum = match.minSize {
                guard minimum.count == 2, minimum.allSatisfy({ $0.isFinite && $0 > 0 }),
                      size.width >= minimum[0], size.height >= minimum[1] else { return false }
            }
            return true
        }
    }
}
