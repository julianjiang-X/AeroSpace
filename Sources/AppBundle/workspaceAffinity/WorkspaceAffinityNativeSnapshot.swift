import AppKit
import ApplicationServices
import Darwin

/// Dedicated short-lived handles keep affinity reads off the UI actor and away
/// from the app's cached AX handles. This code never performs an AX write.
struct WorkspaceAffinityNativeSnapshot: Sendable {
    struct ProcessStamp: Sendable, Equatable {
        let seconds: UInt64
        let microseconds: UInt64
        let executablePath: String
    }
    let stamp: ProcessStamp
    let role: String?
    let subrole: String?
    let title: String?
    let minimized: Bool?
    let fullscreen: Bool?

    static func processStamp(_ pid: pid_t) -> ProcessStamp? {
        guard pid > 0, let path = CompatibilityProcessAccess.executablePath(pid) else { return nil }
        var bsd = proc_bsdinfo()
        let count = unsafe withUnsafeMutablePointer(to: &bsd) {
            unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard count == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return .init(seconds: bsd.pbi_start_tvsec, microseconds: bsd.pbi_start_tvusec, executablePath: path)
    }

    static func read(pid: pid_t, windowID: UInt32, readTitle: Bool) -> Self? {
        guard let stamp = processStamp(pid) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var raw: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        guard let window = windows.first(where: {
            AXUIElementSetMessagingTimeout($0, 0.3)
            return $0.containingWindowId() == windowID
        }) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.3)
        func value(_ key: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return unsafe AXUIElementCopyAttributeValue(window, key as CFString, &v) == .success ? v : nil
        }
        let role = value(kAXRoleAttribute) as? String
        let subrole = value(kAXSubroleAttribute) as? String
        let title = readTitle ? value(kAXTitleAttribute) as? String : nil
        let minimized = value(kAXMinimizedAttribute) as? Bool
        let fullscreen = value("AXFullScreen") as? Bool
        guard processStamp(pid) == stamp else { return nil }
        return .init(stamp: stamp, role: role, subrole: subrole, title: title,
                     minimized: minimized, fullscreen: fullscreen)
    }
}

struct WorkspaceAffinityNativeFocus: Sendable {
    let pid: pid_t
    let windowID: UInt32?

    static func read() -> Self? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var raw: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let app = unsafe unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var pid: pid_t = 0
        guard unsafe AXUIElementGetPid(app, &pid) == .success, pid > 0 else { return nil }
        var focusedWindowRaw: CFTypeRef?
        let result = unsafe AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowRaw)
        let windowID: UInt32?
        if result == .success, let raw = focusedWindowRaw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            windowID = (unsafe unsafeBitCast(raw, to: AXUIElement.self)).containingWindowId()
        } else { windowID = nil }
        return .init(pid: pid, windowID: windowID)
    }
}
