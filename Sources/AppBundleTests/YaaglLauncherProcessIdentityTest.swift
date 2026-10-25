@testable import AppBundle
import Foundation
import XCTest

final class YaaglLauncherProcessIdentityTest: XCTestCase {
    func testPositiveNativePIDBypassesLauncherFallback() {
        var reads = 0
        let result = YaaglLauncherProcessIdentity.resolve(
            reportedPID: 42, bundleID: nil, bundleURL: nil, executableURL: nil,
            ownerPIDs: { reads += 1; return [] },
            processPath: { _ in reads += 1; return nil },
        )
        XCTAssertEqual(result?.pid, 42)
        XCTAssertNil(result?.profile)
        XCTAssertEqual(reads, 0)
    }

    func testEachKnownLauncherRecoversOneVerifiedWindowOwner() {
        for profile in YaaglLauncherProcessIdentity.profiles {
            let reportedPIDs: [Int32] = [-1, 0]
            for reportedPID in reportedPIDs {
                let result = YaaglLauncherProcessIdentity.resolve(
                    reportedPID: reportedPID,
                    bundleID: profile.bundleID,
                    bundleURL: URL(filePath: profile.bundlePath),
                    executableURL: URL(filePath: profile.executablePath),
                    ownerPIDs: { [-1, 0, 101, 101, 202] },
                    processPath: { $0 == 101 ? profile.executablePath : "/Applications/Other.app/Contents/MacOS/Yaagl" },
                )
                XCTAssertEqual(result?.pid, 101)
                XCTAssertEqual(result?.profile, profile)
            }
        }
    }

    func testUnrecognizedOrMismatchedBundleMetadataNeverReadsProcesses() {
        let profile = YaaglLauncherProcessIdentity.profiles[0]
        var reads = 0
        let metadata: [(String?, URL?, URL?)] = [
            (nil, URL(filePath: profile.bundlePath), URL(filePath: profile.executablePath)),
            ("com.tencent.xinWeChat", URL(filePath: profile.bundlePath), URL(filePath: profile.executablePath)),
            (profile.bundleID, nil, URL(filePath: profile.executablePath)),
            (profile.bundleID, URL(filePath: profile.bundlePath), nil),
            (profile.bundleID, URL(filePath: "/tmp/Yaagl.app"), URL(filePath: profile.executablePath)),
            (profile.bundleID, URL(filePath: profile.bundlePath), URL(filePath: profile.bundlePath + "/Contents/MacOS/parameterized")),
            (profile.bundleID, URL(filePath: profile.bundlePath), URL(filePath: profile.executablePath + "Helper")),
        ]
        for (bundleID, bundleURL, executableURL) in metadata {
            XCTAssertNil(YaaglLauncherProcessIdentity.resolve(
                reportedPID: -1, bundleID: bundleID, bundleURL: bundleURL, executableURL: executableURL,
                ownerPIDs: { reads += 1; return [101] },
                processPath: { _ in reads += 1; return profile.executablePath },
            ))
        }
        XCTAssertEqual(reads, 0)
    }

    func testMissingWrongAndAmbiguousOwnerIdentitiesFailClosed() {
        let profile = YaaglLauncherProcessIdentity.profiles[0]
        let cases: [([Int32], [Int32: String])] = [
            ([], [:]),
            ([-1, 0], [:]),
            ([101], [:]),
            ([101], [101: "/Applications/WeChat.app/Contents/MacOS/WeChat"]),
            ([101], [101: profile.executablePath + "Helper"]),
            ([101], [101: YaaglLauncherProcessIdentity.profiles[1].executablePath]),
            ([101, 202], [101: profile.executablePath, 202: profile.executablePath]),
        ]
        for (owners, paths) in cases {
            XCTAssertNil(YaaglLauncherProcessIdentity.resolve(
                reportedPID: -1, bundleID: profile.bundleID,
                bundleURL: URL(filePath: profile.bundlePath), executableURL: URL(filePath: profile.executablePath),
                ownerPIDs: { owners }, processPath: { paths[$0] },
            ))
        }
    }
}
