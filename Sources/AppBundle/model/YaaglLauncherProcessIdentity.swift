import AppKit
import Darwin
import Foundation

/// Work around only the three installed Yaagl shell-wrapper bundles whose
/// LaunchServices application object reports -1 while their Mach-O owns windows.
enum YaaglLauncherProcessIdentity {
    struct Profile: Sendable, Equatable {
        let bundleID: String
        let bundlePath: String
        var executablePath: String { bundlePath + "/Contents/MacOS/Yaagl" }
    }

    struct Resolution: Sendable {
        let pid: pid_t
        let profile: Profile?
    }

    static let profiles = [
        Profile(bundleID: "com.3shain.yaagl", bundlePath: "/Applications/Yaagl.app"),
        Profile(bundleID: "com.3shain.yaagl.hkrpg.cn", bundlePath: "/Applications/Yaagl HSR.app"),
        Profile(bundleID: "com.3shain.yaagl.nap.os", bundlePath: "/Applications/Yaagl ZZZ OS.app"),
    ]

    static func resolve(_ app: NSRunningApplication) -> Resolution? {
        resolve(
            reportedPID: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            executableURL: app.executableURL,
            ownerPIDs: windowOwnerPIDs,
            processPath: processExecutablePath,
        )
    }

    /// Positive native PIDs use the original path without reading CG or proc.
    /// The fallback requires exact bundle metadata and one verified process.
    static func resolve(
        reportedPID: pid_t,
        bundleID: String?,
        bundleURL: URL?,
        executableURL: URL?,
        ownerPIDs: () -> [pid_t],
        processPath: (pid_t) -> String?,
    ) -> Resolution? {
        if reportedPID > 0 { return Resolution(pid: reportedPID, profile: nil) }
        guard let profile = profiles.first(where: { $0.bundleID == bundleID }),
              let bundleURL, let executableURL,
              canonical(bundleURL) == canonical(URL(filePath: profile.bundlePath)),
              canonical(executableURL) == canonical(URL(filePath: profile.executablePath))
        else { return nil }
        let candidates = Set(ownerPIDs().filter { $0 > 0 }).filter { pid in
            guard let path = processPath(pid) else { return false }
            return canonical(URL(filePath: path)) == canonical(URL(filePath: profile.executablePath))
        }
        guard candidates.count == 1, let pid = candidates.first else { return nil }
        return Resolution(pid: pid, profile: profile)
    }

    static func stillMatches(pid: pid_t, profile: Profile) -> Bool {
        guard pid > 0, let path = processExecutablePath(pid) else { return false }
        return canonical(URL(filePath: path)) == canonical(URL(filePath: profile.executablePath))
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private static func windowOwnerPIDs() -> [pid_t] {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            (row[kCGWindowOwnerPID as String] as? NSNumber).flatMap { pid_t(exactly: $0.int64Value) }
        }
    }

    private static func processExecutablePath(_ pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let count = unsafe bytes.withUnsafeMutableBytes {
            unsafe proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
