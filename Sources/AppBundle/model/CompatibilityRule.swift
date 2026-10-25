import Foundation

/// Declarative compatibility capabilities. Application-specific identities and
/// window traits belong in configuration, never in the matching engine.
struct CompatibilityRule: Sendable, Equatable {
    enum Phase: String, Sendable { case application, window }
    enum ActivationPolicy: String, Sendable { case regular }
    enum PIDRecovery: String, Sendable { case windowOwner = "window-owner" }
    enum Classification: String, Sendable { case floating }

    struct Match: Sendable, Equatable {
        var appId: String? = nil
        var bundlePath: String? = nil
        var executablePath: String? = nil
        var appIdAbsent: Bool? = nil
        var firstExeArgument: [String]? = nil
        var windowTitle: [String]? = nil
        var axRole: String? = nil
        var axSubrole: String? = nil
        var activationPolicy: ActivationPolicy? = nil
        var nativeFullscreen: Bool? = nil
        var windowLevel: [Int]? = nil
        var minSize: [Double]? = nil
    }

    struct Action: Sendable, Equatable {
        var recoverPid: PIDRecovery? = nil
        var classify: Classification? = nil
    }

    let id: String
    let phase: Phase
    let match: Match
    let action: Action

    /// Also checked at runtime so a programmatically constructed malformed rule
    /// cannot silently become a broad window-classification override.
    var isValidFloatingWindowRule: Bool {
        func nonblank(_ value: String?) -> Bool {
            value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
        return phase == .window && action.classify == .floating &&
            (nonblank(match.appId) || nonblank(match.executablePath)) &&
            nonblank(match.axRole) && nonblank(match.axSubrole) &&
            match.windowTitle.map { !$0.isEmpty && $0.allSatisfy { nonblank($0) } } == true
    }
}
