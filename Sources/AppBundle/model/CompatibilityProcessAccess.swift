import CoreGraphics
import Darwin
import Foundation

/// Native observations used by the rule engine. No application identities or
/// rule policy live here, and argv/environment are never emitted to diagnostics.
enum CompatibilityProcessAccess {
    static func windowOwnerPIDs() -> [pid_t] {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            (row[kCGWindowOwnerPID as String] as? NSNumber).flatMap { pid_t(exactly: $0.int64Value) }
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = unsafe bytes.withUnsafeMutableBytes {
            unsafe proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    static func stillMatches(pid: pid_t, recoveryRule: CompatibilityRule) -> Bool {
        guard let expected = recoveryRule.match.executablePath else { return false }
        return CompatibilityRuleEngine.pathsMatch(executablePath(pid), expected)
    }

    static func arguments(_ pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
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
        return parseArguments(data)
    }

    /// KERN_PROCARGS2 contains argc followed by executable path, padding and
    /// argc arguments. Stop before the trailing environment block.
    static func parseArguments(_ data: Data) -> [String]? {
        let bytes = Array(data)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = unsafe data.withUnsafeBytes { unsafe $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            cursor = end + 1
            return value
        }
        guard readString() != nil else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = readString() else { return nil }
            arguments.append(argument)
        }
        return arguments
    }
}
