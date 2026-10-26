import Foundation

/// Window ownership is independent from compatibility classification and from
/// one-shot on-window-detected actions. The first matching rule is authoritative.
struct WorkspaceRule: Sendable, Equatable {
    enum Policy: String, Sendable { case observe, enforce }

    struct Match: Sendable, Equatable {
        var appId: String? = nil
        var bundlePath: String? = nil
        var executablePath: String? = nil
        var appIdAbsent: Bool? = nil
        var firstExeArgument: [String]? = nil
        var windowTitle: [String]? = nil
        var axRole: String? = nil
        var axSubrole: String? = nil

        /// Path-only Wine matches could move every guest process. A guest
        /// identity therefore always accompanies an executable-path anchor.
        var hasExactIdentity: Bool {
            func nonblank(_ value: String?) -> Bool {
                value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            }
            if nonblank(appId) { return appIdAbsent != true }
            return nonblank(executablePath) && executablePath?.hasPrefix("/") == true &&
                firstExeArgument.map { !$0.isEmpty && $0.allSatisfy(Self.isGuestExecutable) } == true
        }

        static func isGuestExecutable(_ name: String) -> Bool {
            name.count > 4 && name.lowercased().hasSuffix(".exe") &&
                !name.contains("/") && !name.contains("\\") &&
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let id: String
    let match: Match
    let workspace: String
    let policy: Policy
}

/// Transient window attributes are supplied by the runtime but are never journaled
/// by the matcher. firstExeArgument is only the guest basename, never raw argv.
struct WorkspaceRuleWindowIdentity: Sendable {
    let process: CompatibilityProcessIdentity
    let firstExeArgument: String?
    let role: String?
    let subrole: String?
    let title: String?
}

enum WorkspaceRuleEngine {
    static func firstMatch(rules: [WorkspaceRule], identity: WorkspaceRuleWindowIdentity) -> WorkspaceRule? {
        rules.first { matches($0.match, identity: identity) }
    }

    static func matches(_ match: WorkspaceRule.Match, identity: WorkspaceRuleWindowIdentity) -> Bool {
        guard match.hasExactIdentity else { return false }
        let process = identity.process
        if let appId = match.appId, process.appId != appId { return false }
        if let absent = match.appIdAbsent, (process.appId == nil) != absent { return false }
        if let path = match.bundlePath, !CompatibilityRuleEngine.pathsMatch(process.bundlePath, path) { return false }
        if let path = match.executablePath, !CompatibilityRuleEngine.pathsMatch(process.executablePath, path) { return false }
        if let required = match.firstExeArgument {
            guard let guest = identity.firstExeArgument, MatchGuest.basename(guest).map({ value in
                required.contains { $0.lowercased() == value }
            }) == true else { return false }
        }
        if let role = match.axRole, identity.role != role { return false }
        if let subrole = match.axSubrole, identity.subrole != subrole { return false }
        if let titles = match.windowTitle, identity.title.map(titles.contains) != true { return false }
        return true
    }

    private enum MatchGuest {
        static func basename(_ value: String) -> String? {
            let basename = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
            guard let basename, WorkspaceRule.Match.isGuestExecutable(basename) else { return nil }
            return basename.lowercased()
        }
    }
}
