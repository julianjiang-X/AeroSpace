import AppKit
import CoreFoundation
import Darwin
import Foundation

/// Opt-in compatibility for narrowly identified Yaagl game Wine main windows only.
/// Process arguments are read once when MacApp is registered, never logged.
struct YaaglGameCompatibilityProfile: Sendable {
    enum Game: String, CaseIterable, Sendable {
        case zzz
        case hsr
        case gi

        var environmentKey: String {
            switch self {
                case .zzz: "AEROSPACE_YAAGL_ZZZ_COMPAT"
                case .hsr: "AEROSPACE_YAAGL_HSR_COMPAT"
                case .gi: "AEROSPACE_YAAGL_GI_COMPAT"
            }
        }
        var bundleInfoKey: String {
            switch self {
                case .zzz: "AeroSpaceYaaglZZZCompatibility"
                case .hsr: "AeroSpaceYaaglHSRCompatibility"
                case .gi: "AeroSpaceYaaglGICompatibility"
            }
        }
        var wineDirectory: String {
            switch self {
                case .zzz: "Yaagl ZZZ OS"
                case .hsr: "Yaagl HSR"
                case .gi: "Yaagl"
            }
        }
        var windowsExecutables: [String] {
            switch self {
                case .zzz: ["zenlesszonezero.exe"]
                case .hsr: ["starrail.exe"]
                case .gi: ["yuanshen.exe", "genshinimpact.exe"]
            }
        }
        var mainWindowTitles: [String] {
            switch self {
                case .zzz: ["ZenlessZoneZero"]
                case .hsr: ["Honkai: Star Rail", "崩坏：星穹铁道"]
                // Exact Chinese/global client names; this local GI installation
                // has no observed running main window yet.
                case .gi: ["原神", "Genshin Impact"]
            }
        }
    }

    static let enabledGames = resolveEnabledGames(
        environment: ProcessInfo.processInfo.environment,
        bundleInfo: Bundle.main.infoDictionary ?? [:],
    )

    /// Explicit environment values override packaged Boolean defaults. Invalid
    /// overrides fail closed; an ordinary build with no metadata remains off.
    static func resolveEnabledGames(environment: [String: String], bundleInfo: [String: Any]) -> [Game] {
        Game.allCases.filter { game in
            if let override = environment[game.environmentKey] { return override == "1" }
            guard let value = bundleInfo[game.bundleInfoKey] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID()
            else { return false }
            return value.boolValue
        }
    }

    let game: Game
    var identifier: String { "yaagl-\(game.rawValue)-main-v1" }

    private init(game: Game) { self.game = game }

    static func detect(pid: pid_t, executableURL: URL?) -> Self? {
        guard let executableURL else { return nil }
        let actualURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        for game in enabledGames {
            let expectedURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/\(game.wineDirectory)/wine/lib/wine/x86_64-unix/wine")
            guard actualURL == expectedURL.standardizedFileURL.resolvingSymlinksInPath() else { continue }
            return detect(
                game: game,
                enabled: true,
                executableURL: executableURL,
                expectedWineExecutableURL: expectedURL,
                arguments: { readProcessArguments(pid: pid) },
            )
        }
        return nil
    }

    /// Injectable process predicate keeps fixture tests independent of running games.
    static func detect(
        game: Game = .zzz,
        enabled: Bool,
        executableURL: URL?,
        expectedWineExecutableURL: URL,
        arguments: () -> [String]?,
    ) -> Self? {
        guard enabled,
              let executableURL,
              executableURL.standardizedFileURL.resolvingSymlinksInPath() ==
              expectedWineExecutableURL.standardizedFileURL.resolvingSymlinksInPath(),
              let arguments = arguments(),
              let firstExecutable = arguments.first(where: { $0.lowercased().hasSuffix(".exe") }),
              let executableName = firstExecutable.replacingOccurrences(of: "\\", with: "/")
                  .split(separator: "/").last?.lowercased(),
              game.windowsExecutables.contains(executableName)
        else { return nil }
        return Self(game: game)
    }

    func matchesMainWindow(
        role: String?,
        subrole: String?,
        title: String?,
        size: CGSize?,
        activationPolicy: NSApplication.ActivationPolicy,
        windowLevel: MacOsWindowLevel?,
        isNativeFullscreen: Bool?,
    ) -> Bool {
        guard role == kAXWindowRole,
              subrole == kAXUnknownSubrole,
              let title, game.mainWindowTitles.contains(title),
              activationPolicy == .regular,
              isNativeFullscreen == false,
              windowLevel == .normalWindow || windowLevel == .unknown(windowLevel: 26),
              let size,
              size.width.isFinite, size.height.isFinite,
              size.width >= 640, size.height >= 360
        else { return false }
        // Deliberately independent of AXFocused/AXMain: Wine changes level 26 to 0
        // when inactive, and workspace hiding must keep managing that same window.
        return true
    }

    private static func readProcessArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        let sizeStatus = unsafe mib.withUnsafeMutableBufferPointer { pointer in
            unsafe sysctl(pointer.baseAddress, u_int(pointer.count), nil, &length, nil, 0)
        }
        guard sizeStatus == 0, length >= MemoryLayout<Int32>.size, length <= 1_048_576 else { return nil }
        var data = Data(count: length)
        let readStatus = unsafe mib.withUnsafeMutableBufferPointer { pointer in
            unsafe data.withUnsafeMutableBytes { bytes in
                unsafe sysctl(pointer.baseAddress, u_int(pointer.count), bytes.baseAddress, &length, nil, 0)
            }
        }
        guard readStatus == 0, length <= data.count else { return nil }
        data.count = length
        return parseProcessArguments(data)
    }

    /// KERN_PROCARGS2 is argc, executable path, padding, argc NUL-terminated args,
    /// followed by environment. Stop at argc; environment is neither parsed nor kept.
    static func parseProcessArguments(_ data: Data) -> [String]? {
        let bytes = Array(data)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = unsafe data.withUnsafeBytes { unsafe $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var cursor = MemoryLayout<Int32>.size

        func readString() -> String? {
            guard cursor < bytes.count,
                  let end = bytes[cursor...].firstIndex(of: 0),
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8)
            else { return nil }
            cursor = end + 1
            return value
        }

        guard readString() != nil else { return nil } // executable path
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = readString() else { return nil }
            arguments.append(argument)
        }
        return arguments
    }
}
