import Common
import Foundation

func parseCompatibilityRules(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [CompatibilityRule] {
    guard let array = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    var result: [CompatibilityRule] = []
    var ids: Set<String> = []
    for (index, raw) in array.enumerated() {
        let path = backtrace + .index(index)
        if let rule = parseCompatibilityRule(raw, path, &c.errors) {
            if ids.insert(rule.id).inserted {
                result.append(rule)
            } else {
                c.errors.append(.init(path + .key("id"), "Compatibility rule ids must be unique: '\(rule.id)'"))
            }
        }
    }
    return result
}

private func parseCompatibilityRule(_ raw: OrderedJson, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> CompatibilityRule? {
    var localErrors: [ConfigParseDiagnostic] = []
    defer { errors += localErrors }
    guard let table = compatibilityTable(raw, keys: ["id", "phase", "match", "action"], path, &localErrors) else { return nil }
    let id = compatibilityField(table, "id", path, &localErrors, required: true, parse: compatibilityString)
    let phase: CompatibilityRule.Phase? = compatibilityEnum(table, "phase", path, &localErrors, required: true, values: ["application", "window"])
    let match = parseCompatibilityMatch(table["match"], phase, path + .key("match"), &localErrors)
    let action = parseCompatibilityAction(table["action"], phase, path + .key("action"), &localErrors)
    guard localErrors.isEmpty, let id, let phase, let match, let action else { return nil }
    return CompatibilityRule(id: id, phase: phase, match: match, action: action)
}

private func parseCompatibilityMatch(_ raw: OrderedJson?, _ phase: CompatibilityRule.Phase?, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> CompatibilityRule.Match? {
    guard let raw else {
        errors.append(.init(path, "'match' is mandatory"))
        return nil
    }
    let applicationKeys: Set<String> = ["app-id", "bundle-path", "executable-path"]
    let windowKeys = applicationKeys.union([
        "app-id-absent", "first-exe-argument", "window-title", "ax-role", "ax-subrole",
        "activation-policy", "native-fullscreen", "window-level", "min-size",
    ])
    guard let table = compatibilityTable(raw, keys: phase == .application ? applicationKeys : windowKeys, path, &errors) else { return nil }
    var match = CompatibilityRule.Match()
    match.appId = compatibilityField(table, "app-id", path, &errors, required: phase == .application, parse: compatibilityString)
    match.bundlePath = compatibilityField(table, "bundle-path", path, &errors, required: phase == .application, parse: compatibilityAbsolutePath)
    match.executablePath = compatibilityField(table, "executable-path", path, &errors, required: phase == .application, parse: compatibilityAbsolutePath)
    if phase == .application { return match }

    match.appIdAbsent = compatibilityField(table, "app-id-absent", path, &errors, parse: parseBool)
    match.firstExeArgument = compatibilityStringArray(table, "first-exe-argument", path, &errors)
    match.windowTitle = compatibilityStringArray(table, "window-title", path, &errors)
    if table["window-title"] == nil { errors.append(.init(path + .key("window-title"), "'window-title' is mandatory")) }
    match.axRole = compatibilityField(table, "ax-role", path, &errors, required: true, parse: compatibilityString)
    match.axSubrole = compatibilityField(table, "ax-subrole", path, &errors, required: true, parse: compatibilityString)
    match.activationPolicy = compatibilityEnum(table, "activation-policy", path, &errors, values: ["regular"])
    match.nativeFullscreen = compatibilityField(table, "native-fullscreen", path, &errors, parse: parseBool)
    match.windowLevel = compatibilityIntArray(table, "window-level", path, &errors)
    if let minSize = compatibilityIntArray(table, "min-size", path, &errors) {
        if minSize.count != 2 || minSize.contains(where: { $0 <= 0 }) {
            errors.append(.init(path + .key("min-size"), "Expected exactly two positive integer pixel thresholds: [width, height]"))
        } else {
            match.minSize = minSize.map(Double.init)
        }
    }
    if match.appId == nil && match.executablePath == nil {
        errors.append(.init(path, "Window rules require 'app-id' or 'executable-path' as an exact identity anchor"))
    }
    if match.appId != nil && match.appIdAbsent == true {
        errors.append(.init(path, "'app-id' and 'app-id-absent = true' are contradictory"))
    }
    for (index, exe) in (match.firstExeArgument ?? []).enumerated() {
        if exe.contains("/") || exe.contains("\\") || !exe.lowercased().hasSuffix(".exe") || exe.count <= 4 {
            errors.append(.init(path + .key("first-exe-argument") + .index(index), "Expected an exact Windows .exe basename without directory separators"))
        }
    }
    return match
}

private func parseCompatibilityAction(_ raw: OrderedJson?, _ phase: CompatibilityRule.Phase?, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> CompatibilityRule.Action? {
    guard let raw else {
        errors.append(.init(path, "'action' is mandatory"))
        return nil
    }
    let keys: Set<String> = switch phase {
        case .application: ["recover-pid"]
        case .window: ["classify", "restore-minimized"]
        case nil: ["recover-pid", "classify", "restore-minimized"]
    }
    guard let table = compatibilityTable(raw, keys: keys, path, &errors) else { return nil }
    var action = CompatibilityRule.Action()
    if phase != .window {
        action.recoverPid = compatibilityEnum(table, "recover-pid", path, &errors, required: phase == .application, values: ["window-owner"])
    }
    if phase != .application {
        action.classify = compatibilityEnum(table, "classify", path, &errors, required: phase == .window, values: ["floating"])
        action.restoreMinimized = compatibilityEnum(table, "restore-minimized", path, &errors, values: ["on-workspace-focus"])
    }
    return action
}

private func compatibilityTable(_ raw: OrderedJson, keys: Set<String>, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> OrderedJson.JsonDict? {
    guard let table = raw.asDictOrNil else {
        errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, path))
        return nil
    }
    for key in table.keys where !keys.contains(key) {
        errors.append(unknownKeyDiagnostic(path + .key(key)))
    }
    return table
}

private func compatibilityField<T>(
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

private func compatibilityString(_ raw: OrderedJson, _ path: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    parseString(raw, path).flatMap { value in
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            .failure(.init(path, "Expected a nonempty exact string"))
        } else {
            .success(value)
        }
    }
}

private func compatibilityAbsolutePath(_ raw: OrderedJson, _ path: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    compatibilityString(raw, path).flatMap { value in
        if value.hasPrefix("/") {
            .success(value)
        } else if value.hasPrefix("~/") {
            .success((value as NSString).expandingTildeInPath)
        } else {
            .failure(.init(path, "Expected an absolute exact path or a path starting with '~/'; other relative paths are not supported"))
        }
    }
}

private func compatibilityEnum<T: RawRepresentable>(
    _ table: OrderedJson.JsonDict,
    _ key: String,
    _ path: ConfigBacktrace,
    _ errors: inout [ConfigParseDiagnostic],
    required: Bool = false,
    values: [String],
) -> T? where T.RawValue == String {
    compatibilityField(table, key, path, &errors, required: required) { raw, path in
        compatibilityString(raw, path).flatMap { value in
            T(rawValue: value).toResult(.init(path, "Expected one of: \(values.joined(separator: ", "))"))
        }
    }
}

private func compatibilityStringArray(_ table: OrderedJson.JsonDict, _ key: String, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [String]? {
    compatibilityArray(table, key, path, &errors, parse: compatibilityString)
}

private func compatibilityIntArray(_ table: OrderedJson.JsonDict, _ key: String, _ path: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [Int]? {
    compatibilityArray(table, key, path, &errors, parse: parseInt)
}

private func compatibilityArray<T>(
    _ table: OrderedJson.JsonDict,
    _ key: String,
    _ path: ConfigBacktrace,
    _ errors: inout [ConfigParseDiagnostic],
    parse: (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>,
) -> [T]? {
    guard let raw = table[key] else { return nil }
    let path = path + .key(key)
    guard let array = raw.asArrayOrNil else {
        errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, path))
        return nil
    }
    if array.isEmpty { errors.append(.init(path, "Expected a nonempty array")) }
    return array.enumerated().compactMap { index, raw in
        parse(raw, path + .index(index)).getOrNil(appendErrorTo: &errors)
    }
}
