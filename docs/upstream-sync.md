# Upstream sync (local fork maintenance)

`script/sync-upstream.py` keeps this fork (`codex/workspace-affinity`) following
`nikitabobko/AeroSpace` releases without silently breaking the fork's own features. It never
opens pull requests upstream; it only pushes the fork branch to `origin`.

Rule: follow upstream releases automatically. On a merge conflict, a failing check, or
upstream work that overlaps a fork feature, stop and ask the user. Auto-install stays off.

## What a run does

1. `git fetch upstream --tags` and `git fetch origin`.
2. Target: the newest upstream release tag (default, `"target": "release"`): the highest
   `v*` version that exists on the `upstream` remote (`git ls-remote --tags`), so fork-local
   tags never count. Upstream `main` is ignored. Decided 2026-11-11 after the first trial
   merge of `main`: main was mid-refactor (about 30 WIP / n-part / prototype /
   intentional-regression commits, 18 conflicting files) while the latest release,
   v0.21.3-Beta, is already in the fork. If the fork already contains the newest release,
   the run logs "no new upstream release … nothing to do" and stops there. `"target": "main"`
   still works for a one-off look (`analyze --target main`).
3. Overlap analysis between the fork's changes (merge-base..fork) and the new upstream
   changes (merge-base..upstream). Anything listed here stops the sync:
   - upstream deletes or renames a file the fork modified;
   - both sides change the same lines (±3) or the same function of a file;
   - both sides introduce the same new symbol, config key, command or format variable;
   - an upstream commit message or doc addition matches a keyword of a fork feature
     (`script/sync-upstream-features.json`: focus stealing/activation, workspace creation,
     window/workspace rules, minimize/restore, compatibility rules and game windows,
     geometry/format variables, sticky windows, versioning/toolchain).
   Changes in the same file but another function are listed in the report without stopping.
4. Toolchain preflight: upstream pins Swift in `.swift-version`. An older configured
   toolchain is only noted (the fork's tree already pinned 6.3.2 while building fine with
   6.2.4); a failing build is what stops the sync, and its report then names the mismatch.
5. Merge into the integration branch `upstream-sync/<date>-<upstream>` in a separate
   worktree (`~/Code/AeroSpace-upstream-sync`). `codex/workspace-affinity` is not touched.
6. If the merge is clean: brand the next local version (`<upstream tag>-COMPAT-RULES-<n>`),
   regenerate the offline runner (`script/generate-compatibility-checks.py`), build and run
   `zzz-compat-checks`, validate `~/.aerospace.toml` with `--validate-config` (0 errors,
   0 warnings), build `AeroSpaceApp` and `aerospace` in release.
7. Outcome
   - anything above failed or overlapped: the integration branch (and an unfinished merge,
     if any) is kept, `report.md` is written, a macOS notification says it needs discussion;
   - clean: fast-forward `codex/workspace-affinity`, push it to `origin`, build release in
     `~/Code/AeroSpace`, package and sign it with
     `daily-deployment/package-local-release.py` ("AeroSpace Local Signing"), and create a
     candidate directory `rules-candidate/upstream-sync-<version>` that keeps the current
     `~/.aerospace.toml` byte-for-byte.

Reports: `<reportsDir>/<run id>/report.md` (+ `report.json`, build logs, `run.log`);
`<reportsDir>/latest-report.md` points at the newest one.

## Commands

```
uv run script/sync-upstream.py analyze   # dry run: overlap + merge-tree conflict preview, changes nothing
uv run script/sync-upstream.py run       # one sync now
uv run script/sync-upstream.py status    # saved state
uv run script/sync-upstream.py approve   # after the discussion (see below)
uv run script/sync-upstream.py abandon   # drop the kept integration branch
uv run script/sync-upstream.py install --now   # install the packaged release now
```

### After a stop

```
cd ~/Code/AeroSpace-upstream-sync
git status                   # the unfinished merge, or the merged branch with failing checks
# resolve together with the user, then
git commit
uv run ~/Code/AeroSpace/script/sync-upstream.py approve
```

`approve` re-runs every check and build on the integration branch; only if they pass does it
fast-forward, push and package. While a sync waits for discussion, the hourly job only
fetches and, at most every three days and only if upstream moved, reminds you.

## Installing

`daily-deployment/switch.py install --skip-frame-guard` restarts AeroSpace and drives the
`aerospace` CLI. Tested from an Aqua LaunchAgent (2026-11-11): the CLI answers normally
(`--version`, `list-windows`, `list-workspaces`, `reload-config --dry-run` all < 50 ms with
stdin = /dev/null), and replacing a signed app bundle in `/Applications` works. No hang was
reproduced, so a hang is more likely the server being busy or blocked (for example waiting
for an Accessibility grant after a re-signed build) than launchd itself. Every CLI call in
`switch.py` has a timeout, and `install` puts a 300 s limit around the whole switch and rolls
back automatically if the old server was already stopped.

`install` only proceeds when:

- a release is packaged and not installed yet;
- no game process runs (`gameProcessPattern`: wine, `.exe`, Zenless/Genshin/StarRail);
- unless `--now`: `autoInstall` is true, the user has been idle for `installIdleMinutes`
  (HID idle time, checked again right before the switch) and no app holds a
  display-sleep assertion (video).

`autoInstall` is off until one supervised launchd install has been verified; meanwhile a
clean sync notifies with the one-line install command.

## Schedule

`~/Library/LaunchAgents/local.aerospace-upstream-sync.plist` runs
`uv run --script script/sync-upstream.py tick` every hour (background priority). `tick`
installs a due release (subject to the rules above) and starts a sync when the last attempt
is at least `syncIntervalHours` (20) old and the user has been idle 10 minutes — or after
twice the interval regardless. Log: `~/Library/Logs/aerospace-upstream-sync.log`.

```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.aerospace-upstream-sync.plist
launchctl kickstart gui/$(id -u)/local.aerospace-upstream-sync   # run a tick now
launchctl bootout gui/$(id -u)/local.aerospace-upstream-sync     # stop the schedule
```

## Settings

`~/.config/aerospace-upstream-sync.json` overrides the defaults at the top of the script:
`repo`, `branch`, `worktree`, `target`, `deployDir`, `reportsDir`, `developerDir`,
`swift` (e.g. `["xcrun", "swift"]` or a swiftly toolchain), `validateConfigs`,
`syncIntervalHours`, `autoInstall`, `installIdleMinutes`, `gameProcessPattern`, `push`,
`notify`.
