#!/usr/bin/env python3
"""Generate an XCTest-free runner from the compatibility tests and AX adapter.

Usage: python3 script/generate-compatibility-checks.py /absolute/path/to/repo
The generated executable calls pure classifiers/parsers only; it never starts AeroSpace.
"""

from pathlib import Path
import re
import sys

repo = Path(sys.argv[1]).resolve()
adapter_source = repo / "Sources/AppBundleTests/AxUiElementWindowTypeTest.swift"
case_specs = [
    ("CompatibilityRuleEngineTest.swift", "CompatibilityRuleEngineTest", "CompatibilityOfflineCases", "engineCases"),
    ("config/CompatibilityRulesConfigTest.swift", "CompatibilityRulesConfigTest", "CompatibilityConfigOfflineCases", "configCases"),
    ("config/CompatibilityRulesReloadTest.swift", "CompatibilityRulesReloadTest", "CompatibilityReloadOfflineCases", "reloadCases"),
    ("WorkspaceMinimizedRestorePolicyTest.swift", "WorkspaceMinimizedRestorePolicyTest", "WorkspaceRestoreOfflineCases", "restoreCases"),
    ("config/WorkspaceRulesConfigTest.swift", "WorkspaceRulesConfigTest", "WorkspaceRulesConfigOfflineCases", "workspaceConfigCases"),
    ("config/FocusRulesConfigTest.swift", "FocusRulesConfigTest", "FocusRulesConfigOfflineCases", "focusConfigCases"),
    ("WorkspaceRuleEngineTest.swift", "WorkspaceRuleEngineTest", "WorkspaceRuleEngineOfflineCases", "workspaceEngineCases"),
    ("WorkspaceAffinityPolicyTest.swift", "WorkspaceAffinityPolicyTest", "WorkspaceAffinityPolicyOfflineCases", "workspacePolicyCases"),
    ("WorkspaceAffinityRuntimeTest.swift", "WorkspaceAffinityRuntimeTest", "WorkspaceAffinityRuntimeOfflineCases", "workspaceRuntimeCases"),
    ("WorkspaceJournalStoreTest.swift", "WorkspaceJournalStoreTest", "WorkspaceJournalStoreOfflineCases", "workspaceJournalCases"),
    ("WorkspaceJournalSnapshotTest.swift", "WorkspaceJournalSnapshotTest", "WorkspaceJournalSnapshotOfflineCases", "workspaceSnapshotCases"),
]
cases = ""
case_invocations = []
for filename, source_class, offline_class, variable in case_specs:
    source = (repo / "Sources/AppBundleTests" / filename).read_text()
    names = re.findall(r"    func (test\w+)\(", source)
    throwing = set(re.findall(r"    func (test\w+)\(\) throws", source))
    case_invocations += [(variable, name, name in throwing) for name in names]
    source = re.sub(r"^import .*\n|^@testable import .*\n", "", source, flags=re.M)
    source, replacements = re.subn(
        r"(?:@MainActor\n)?final class " + source_class + r": XCTestCase \{",
        "@MainActor\nfinal class " + offline_class + " {\n    let checks: CheckRunner\n    init(_ checks: CheckRunner) { self.checks = checks }",
        source, count=1,
    )
    assert replacements == 1, f"Could not adapt {source_class}"
    cases += source + "\n"
for original, replacement in {
    "XCTAssertNil": "checks.expectNil",
    "XCTAssertNotNil": "checks.expectNotNil",
    "XCTAssertEqual": "checks.expectEqual",
    "XCTAssertTrue": "checks.expectTrue",
    "XCTAssertFalse": "checks.expectFalse",
    "XCTUnwrap": "checks.require",
}.items():
    cases = cases.replace(original, replacement)
adapter = adapter_source.read_text().split("extension [String: Json]: AxUiElementMock", 1)[1]
adapter = "extension [String: Json]: AxUiElementMock" + adapter
# The upstream adapter delegates AX object conversion to a production getter whose
# fixture branch is guarded by Common.isUnitTest (which detects XCTest at runtime).
# Do the same conversion locally rather than loading XCTest or spoofing that flag.
adapter = adapter.replace(
    "        if let value = value.rawValue {",
    '''        if attr.key == kAXFocusedWindowAttribute {
            guard let object = fixtureAxObject(value), let id = object["Aero.axWindowId"]?.asInt64OrNil,
                  let windowId = UInt32(exactly: id) else { return nil }
            let focused: WindowIdAndAxUiElementMock = (windowId, object)
            return focused as? Attr.T
        }
        if [kAXCloseButtonAttribute, kAXFullScreenButtonAttribute, kAXZoomButtonAttribute, kAXMinimizeButtonAttribute].contains(attr.key) {
            return fixtureAxObject(value) as? Attr.T
        }
        if let value = value.rawValue {''',
)
adapter += '''
// Equivalent to the upstream castToAxUiElementMock fixture branch, without
// invoking native AX calls or depending on XCTest's runtime class registration.
private func fixtureAxObject(_ value: Json) -> [String: Json]? {
    if case .null = value { return nil }
    if let object = value.asDictOrNil { return object }
    if let text = value.rawValue as? String, let comma = text.firstIndex(of: ","),
       let id = UInt32(String(text[..<comma]).removePrefix("AXUIElement(AxWindowId=")) {
        return ["Aero.axWindowId": .int(id), kAXAeroSynthetic: .bool(true)]
    }
    fatalError("Unsupported fixture AX object: \\(value)")
}
'''

prelude = '''// Generated from compatibility tests and the upstream AX fixture adapter.
// Regenerate with python3 script/generate-compatibility-checks.py <repo-root>.
// This is a focused offline runner, not the complete XCTest suite.
#if DEBUG
import AppKit
@testable import AppBundle
import Common
import Foundation

struct FailedCheck: Error { let message: String }

@MainActor
final class CheckRunner {
    var assertions = 0
    var failures = 0
    var groups = 0
    var fixtures = 0

    func expectNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value == nil, "\\(message) expected nil", file, line)
    }
    func expectNotNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value != nil, "\\(message) expected non-nil", file, line)
    }
    func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value, "\\(message) expected true", file, line)
    }
    func expectFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(!value, "\\(message) expected false", file, line)
    }
    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        record(actual == expected, "\\(message) expected \\(expected), got \\(actual)", file, line)
    }
    func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        assertions += 1
        guard let value else { throw FailedCheck(message: "\\(file):\\(line): expected non-nil") }
        return value
    }
    private func record(_ passed: Bool, _ message: String, _ file: StaticString, _ line: UInt) {
        assertions += 1
        if !passed {
            failures += 1
            print("FAIL \\(file):\\(line): \\(message)")
        }
    }
    func run(_ name: String, _ body: @MainActor () throws -> Void) {
        groups += 1
        let before = failures
        do { try body() }
        catch { failures += 1; print("FAIL \\(name): \\(error)") }
        print("\\(failures == before ? "PASS" : "FAIL") \\(name)")
    }
}

@MainActor
func checkUpstreamAxDumps(_ dir: URL, _ checks: CheckRunner) throws {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .sorted { $0.path < $1.path }
    for file in files {
        if file.isDirectory { try checkUpstreamAxDumps(file, checks); continue }
        if file.pathExtension == "md" { continue }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.json5Allowed])
        guard let rawJson = raw as? [String: Any] else { throw FailedCheck(message: "Invalid fixture \\(file.path)") }
        let json = Json.newOrDieRecursive(rawJson).asDictOrDie
        let app = json["Aero.AXApp"]!.asDictOrDie
        let appId = (rawJson["Aero.App.appBundleId"] as? String).flatMap { KnownBundleId(rawValue: $0) }
        let level = json["Aero.windowLevel"].map { MacOsWindowLevel.fromJson($0) ?? dieT() }
        let policy = NSApplication.ActivationPolicy.from(string: rawJson["Aero.App.nsApp.activationPolicy"] as! String)
        checks.expectEqual(
            json.getWindowType(axApp: app, appId, policy, level),
            AxUiElementWindowType(rawValue: rawJson["Aero.AxUiElementWindowType"] as? String ?? dieT()),
            file.lastPathComponent + " window type",
        )
        checks.expectEqual(
            json.isDialogHeuristic(appId, level),
            rawJson["Aero.AxUiElementWindowType_isDialogHeuristic"] as? Bool ?? dieT(),
            file.lastPathComponent + " dialog heuristic",
        )
        checks.fixtures += 1
    }
}

'''

trailer = '''
MainActor.assumeIsolated {
if let index = CommandLine.arguments.firstIndex(of: "--validate-config") {
    guard index + 1 < CommandLine.arguments.count else { exit(2) }
    do {
        let source = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
        let parsed = parseConfig(source)
        let diagnostics = parsed.errors.map { $0.description(.error) } + parsed.warnings.map { $0.description(.warning) }
        for diagnostic in diagnostics { print(diagnostic) }
        print("Config validation: \\(parsed.errors.count) errors, \\(parsed.warnings.count) warnings; workspace rules: \\(parsed.config.workspaceRules.count)")
        exit(diagnostics.isEmpty ? 0 : 1)
    } catch { print("Config validation failed: \\(error)"); exit(1) }
}
let checks = CheckRunner()
'''
for _, _, offline_class, variable in case_specs:
    trailer += f'let {variable} = {offline_class}(checks)\n'
for variable, name, is_throwing in case_invocations:
    throwing = "try " if is_throwing else ""
    trailer += f'checks.run("{name}") {{ {throwing}{variable}.{name}() }}\n'
trailer += '''let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
checks.run("upstream axDumps corpus") { try checkUpstreamAxDumps(repoRoot.appending(path: "axDumps"), checks) }
print("Offline checks: \\(checks.groups) groups, \\(checks.assertions) assertions, \\(checks.fixtures) upstream fixtures, \\(checks.failures) failures")
exit(checks.failures == 0 ? 0 : 1)
}
#else
import Foundation
print("zzz-compat-checks requires a debug build (swift run -c debug zzz-compat-checks)")
exit(2)
#endif
'''
output = repo / "Sources/ZZZCompatChecks/main.swift"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(prelude + cases + "\n" + adapter + "\n" + trailer)
print(f"Generated {output}: {len(case_invocations)} compatibility cases plus upstream corpus")
