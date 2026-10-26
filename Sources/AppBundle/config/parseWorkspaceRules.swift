import Common
import Foundation

func parseWorkspaceRules(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [WorkspaceRule] {
    guard let values = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    var rules: [WorkspaceRule] = []
    var ids: Set<String> = []
    for (index, value) in values.enumerated() {
        let path = backtrace + .index(index)
        guard let rule = parseWorkspaceRule(value, path, &c.errors) else { continue }
        if ids.insert(rule.id).inserted {
            rules.append(rule)
        } else {
            c.errors.append(.init(path + .key("id"), "Workspace rule ids must be unique: '\(rule.id)'"))
        }
    }
    return rules
}

private func parseWorkspaceRule(_ raw: OrderedJson, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> WorkspaceRule? {
    var local: [ConfigParseDiagnostic] = []
    defer { errors += local }
    guard let table = workspaceRuleTable(raw, keys: ["id", "match", "workspace", "policy"], path, &local) else { return nil }
    let id = workspaceRuleField(table, "id", path, &local, required: true, parse: workspaceRuleString)
    let workspace = workspaceRuleField(table, "workspace", path, &local, required: true) { raw, path in
        workspaceRuleString(raw, path).flatMap { WorkspaceName.parse($0).map(\.raw).toParsedConfig(path) }
    }
    let policy: WorkspaceRule.Policy? = workspaceRuleField(table, "policy", path, &local, required: true) { raw, path in
        workspaceRuleString(raw, path).flatMap { value in
            WorkspaceRule.Policy(rawValue: value).toResult(.init(path, "Expected one of: observe, enforce"))
        }
    }
    let match: WorkspaceRule.Match?
    if let value = table["match"] {
        match = parseWorkspaceRuleMatch(value, path + .key("match"), &local)
    } else {
        local.append(.init(path + .key("match"), "'match' is mandatory"))
        match = nil
    }
    guard local.isEmpty, let id, let workspace, let policy, let match else { return nil }
    return WorkspaceRule(id: id, match: match, workspace: workspace, policy: policy)
}

private func parseWorkspaceRuleMatch(_ raw: OrderedJson, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> WorkspaceRule.Match? {
    let keys: Set<String> = ["app-id", "bundle-path", "executable-path", "app-id-absent", "first-exe-argument", "window-title", "ax-role", "ax-subrole"]
    guard let table = workspaceRuleTable(raw, keys: keys, path, &errors) else { return nil }
    var match = WorkspaceRule.Match()
    match.appId = workspaceRuleField(table, "app-id", path, &errors, parse: workspaceRuleString)
    match.bundlePath = workspaceRuleField(table, "bundle-path", path, &errors, parse: workspaceRulePath)
    match.executablePath = workspaceRuleField(table, "executable-path", path, &errors, parse: workspaceRulePath)
    match.appIdAbsent = workspaceRuleField(table, "app-id-absent", path, &errors, parse: parseBool)
    match.firstExeArgument = workspaceRuleStrings(table, "first-exe-argument", path, &errors)
    match.windowTitle = workspaceRuleStrings(table, "window-title", path, &errors)
    match.axRole = workspaceRuleField(table, "ax-role", path, &errors, parse: workspaceRuleString)
    match.axSubrole = workspaceRuleField(table, "ax-subrole", path, &errors, parse: workspaceRuleString)

    if match.appId != nil && match.appIdAbsent == true {
        errors.append(.init(path, "'app-id' and 'app-id-absent = true' are contradictory"))
    }
    for (index, value) in (match.firstExeArgument ?? []).enumerated() where !WorkspaceRule.Match.isGuestExecutable(value) {
        errors.append(.init(path + .key("first-exe-argument") + .index(index), "Expected an exact Windows .exe basename without directory separators"))
    }
    if !match.hasExactIdentity {
        errors.append(.init(path, "Workspace rules require exact 'app-id', or an absolute 'executable-path' together with nonempty 'first-exe-argument' guest basenames"))
    }
    return match
}

private func workspaceRuleTable(_ raw: OrderedJson, keys: Set<String>, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> OrderedJson.JsonDict? {
    guard let table = raw.asDictOrNil else {
        errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, path))
        return nil
    }
    for key in table.keys where !keys.contains(key) { errors.append(unknownKeyDiagnostic(path + .key(key))) }
    return table
}

private func workspaceRuleField<T>(
    _ table: OrderedJson.JsonDict,
    _ key: String,
    _ path: ConfigBacktrace,
    _ errors: inout [ConfigParseDiagnostic],
    required: Bool = false,
    parse: (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>,
) -> T? {
    let path = path + .key(key)
    guard let raw = table[key] else {
        if required { errors.append(.init(path, "'\(key)' is mandatory")) }
        return nil
    }
    return parse(raw, path).getOrNil(appendErrorTo: &errors)
}

private func workspaceRuleString(_ raw: OrderedJson, _ path: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    parseString(raw, path).flatMap { value in
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .failure(.init(path, "Expected a nonempty exact string without control characters"))
        }
        return .success(value)
    }
}

private func workspaceRulePath(_ raw: OrderedJson, _ path: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    workspaceRuleString(raw, path).flatMap { value in
        if value.hasPrefix("/") { return .success(value) }
        if value.hasPrefix("~/") { return .success((value as NSString).expandingTildeInPath) }
        return .failure(.init(path, "Expected an absolute exact path or a path starting with '~/'"))
    }
}

private func workspaceRuleStrings(_ table: OrderedJson.JsonDict, _ key: String, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [String]? {
    guard let raw = table[key] else { return nil }
    let path = path + .key(key)
    guard let values = raw.asArrayOrNil else {
        errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, path))
        return nil
    }
    if values.isEmpty { errors.append(.init(path, "Expected a nonempty array")) }
    return values.enumerated().compactMap { index, value in
        workspaceRuleString(value, path + .index(index)).getOrNil(appendErrorTo: &errors)
    }
}
