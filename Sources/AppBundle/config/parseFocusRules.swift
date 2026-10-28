import Common

func parseFocusRules(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [FocusRule] {
    guard let values = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    var rules: [FocusRule] = []
    var ids: Set<String> = []
    for (index, value) in values.enumerated() {
        let path = backtrace + .index(index)
        guard let rule = parseFocusRule(value, path, &c) else { continue }
        if ids.insert(rule.id).inserted {
            rules.append(rule)
        } else {
            c.errors.append(.init(path + .key("id"), "Focus rule ids must be unique: '\(rule.id)'"))
        }
    }
    return rules
}

private func parseFocusRule(_ raw: OrderedJson, _ path: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusRule? {
    guard let table = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, path))
        return nil
    }
    var local = ConfigParserContext(configVersion: c.configVersion, errors: [], warnings: [])
    defer {
        c.errors += local.errors
        c.warnings += local.warnings
    }
    for key in table.keys where !["id", "if", "policy"].contains(key) {
        local.errors.append(unknownKeyDiagnostic(path + .key(key)))
    }

    var id: String? = nil
    if let raw = table["id"] {
        id = parseString(raw, path + .key("id")).filter(.init(path + .key("id"), "Expected a nonempty string")) {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.getOrNil(appendErrorTo: &local.errors)
    } else {
        local.errors.append(.init(path + .key("id"), "'id' is mandatory"))
    }

    var policy: FocusRule.Policy? = nil
    if let raw = table["policy"] {
        policy = parseString(raw, path + .key("policy")).flatMap {
            FocusRule.Policy(rawValue: $0).toResult(.init(path + .key("policy"), "Expected one of: ignore-activation"))
        }.getOrNil(appendErrorTo: &local.errors)
    } else {
        local.errors.append(.init(path + .key("policy"), "'policy' is mandatory"))
    }

    var matcher: LegacyWindowDetectedCallbackMatcher? = nil
    if let raw = table["if"] {
        let ifPath = path + .key("if")
        let parsed = parseWindowMatcherTable(raw, ifPath, &local)
        if parsed.duringAeroSpaceStartup != nil {
            local.errors.append(.init(ifPath + .key("during-aerospace-startup"), "Not supported in focus rules"))
        }
        if parsed == LegacyWindowDetectedCallbackMatcher() {
            // An empty matcher would apply to every window
            local.errors.append(.init(ifPath, "Expected at least one of: app-id, app-name-regex-substring, window-title-regex-substring, workspace"))
        }
        matcher = parsed
    } else {
        local.errors.append(.init(path + .key("if"), "'if' is mandatory"))
    }

    guard local.errors.isEmpty, let id, let policy, let matcher else { return nil }
    return FocusRule(id: id, matcher: matcher, policy: policy)
}
