# Restore a minimized compatibility window on workspace focus

The optional window action `restore-minimized = 'on-workspace-focus'` requests
restoration when the matching window's workspace is focused. This opt-in action
is intended for applications whose native minimization prevents normal workspace
recall. Omitting it preserves existing minimization behavior.

```toml
[[compatibility-rules]]
id = 'example-fullscreen-window'
phase = 'window'
match = { executable-path = '/opt/example/wine', app-id-absent = true, first-exe-argument = ['Example.exe'], window-title = ['Example'], ax-role = 'AXWindow', ax-subrole = 'AXUnknown', native-fullscreen = false, window-level = [0, 26, 27], min-size = [640, 360] }
action = { classify = 'floating', restore-minimized = 'on-workspace-focus' }
```

The action is valid only in the `window` phase. `classify = 'floating'` remains
mandatory, together with all existing exact identity and window trait requirements.
The parser rejects unknown values, non-string values, application-phase use, and
attempts to omit the classification or required identity fields.

The model exposes `CompatibilityRule.Action.restoreMinimized`, an optional
`CompatibilityRule.MinimizedRestore` with the single case `.onWorkspaceFocus`.
Its default is `nil`; old compatibility rules retain their behavior. The action
participates in rule equality, so adding or removing it after startup requires
an AeroSpace restart. Rejected reloads retain the complete last valid config;
ordinary layout changes remain eligible for hot reload when rules are identical.

Configuration and reload regression tests live in
`Sources/AppBundleTests/config/CompatibilityRulesConfigTest.swift` and
`Sources/AppBundleTests/config/CompatibilityRulesReloadTest.swift`. The existing
standalone check generator discovers their test methods automatically.
