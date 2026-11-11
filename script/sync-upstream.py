#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# ///
"""Keep this AeroSpace fork in sync with upstream without silently breaking fork features.

  run      fetch upstream, merge it into a separate integration worktree, look for overlap with the
           fork's own features, regenerate + run the offline checks, build release binaries.
           Conflicts, overlap or failures -> stop, keep the integration branch, write a report,
           send a macOS notification. Clean -> fast-forward the fork branch, push it, brand and
           package a signed local release (and install it later when the user is idle, if enabled).
  approve  after the discussion: verify the kept integration branch (conflicts resolved and
           committed) with the same checks, then publish it.
  install  install the packaged release (only when idle and no game runs, unless --now).
  tick     what the LaunchAgent runs every hour: install if due, sync if due.
  status   print the saved state.
  abandon  drop a kept integration branch (aborts an unfinished merge).

Settings: script defaults < ~/.config/aerospace-upstream-sync.json < command-line flags.
See docs/upstream-sync.md.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get('AEROSPACE_SYNC_CONFIG', '~/.config/aerospace-upstream-sync.json')).expanduser()
FEATURES_PATH = SCRIPT_DIR / 'sync-upstream-features.json'
DEFAULTS = {
    'repo': str(SCRIPT_DIR.parent),
    'branch': 'codex/workspace-affinity',
    'upstreamRemote': 'upstream',
    'upstreamBranch': 'main',
    'originRemote': 'origin',
    'target': 'release',  # 'release' = newest upstream v* release tag (user decision 2026-11-11), 'main' = upstream/main
    'worktree': None,  # default: <repo>-upstream-sync
    'stateDir': '~/Library/Application Support/aerospace-upstream-sync',
    'reportsDir': None,  # default: <stateDir>/reports
    'deployDir': None,  # directory with package-local-release.py, switch.py, releases/, rules-candidate/
    'developerDir': '/Library/Developer/CommandLineTools',
    'swift': ['swift'],
    'versionSuffix': 'COMPAT-RULES',
    'validateConfigs': ['~/.aerospace.toml'],
    'syncIntervalHours': 20,
    'syncIdleMinutes': 10,
    'autoInstall': False,
    'installIdleMinutes': 45,
    'gameProcessPattern': r'(?i)\bwine|\.exe\b|zenless|genshin|yuanshen|starrail',
    'push': True,
    'notify': True,
    'buildTimeoutSeconds': 3600,
}
VERSION_FILE = 'Sources/Common/versionGenerated.swift'
GIT_HASH_FILE = 'Sources/Common/gitHashGenerated.swift'
BUILD_INFO_SOURCE = 'Sources/Common/buildInfo.swift'
CHECKS_GENERATOR = 'script/generate-compatibility-checks.py'
EXIT_DISCUSS = 10


class Stop(Exception):
    """Expected, reportable reason to stop (not a crash)."""


def now():
    return dt.datetime.now().astimezone()


def iso(t=None):
    return (t or now()).isoformat(timespec='seconds')


# ---------------------------------------------------------------- config / state

def load_config(args):
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.is_file():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    for key in ['repo', 'branch', 'target', 'worktree', 'deployDir', 'developerDir']:
        value = getattr(args, key.replace('Dir', '_dir') if key.endswith('Dir') else key, None)
        if value is not None:
            cfg[key] = value
    if getattr(args, 'no_push', False):
        cfg['push'] = False
    if getattr(args, 'no_notify', False):
        cfg['notify'] = False
    exp = lambda p: Path(p).expanduser().resolve() if p else None
    cfg['repo'] = exp(cfg['repo'])
    cfg['worktree'] = exp(cfg['worktree']) or cfg['repo'].with_name(cfg['repo'].name + '-upstream-sync')
    cfg['stateDir'] = exp(cfg['stateDir'])
    cfg['reportsDir'] = exp(cfg['reportsDir']) or cfg['stateDir'] / 'reports'
    cfg['deployDir'] = exp(cfg['deployDir'])
    cfg['validateConfigs'] = [exp(p) for p in cfg['validateConfigs']]
    if isinstance(cfg['swift'], str):
        cfg['swift'] = [cfg['swift']]
    return cfg


class State:
    def __init__(self, cfg):
        self.path = cfg['stateDir'] / 'state.json'
        self.data = json.loads(self.path.read_text()) if self.path.is_file() else {}

    def get(self, key, default=None):
        return self.data.get(key, default)

    def update(self, **kv):
        self.data.update(kv)
        self.save()

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2) + '\n')
        os.replace(tmp, self.path)


class Lock:
    def __init__(self, cfg):
        cfg['stateDir'].mkdir(parents=True, exist_ok=True)
        self.file = open(cfg['stateDir'] / 'lock', 'w')

    def __enter__(self):
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('another sync-upstream run is in progress')
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.file, fcntl.LOCK_UN)


class Run:
    """One sync attempt: its own directory with run.log, build logs, report.md, report.json."""

    def __init__(self, cfg, kind):
        self.cfg = cfg
        self.id = now().strftime('%Y%m%d-%H%M%S')
        self.dir = cfg['reportsDir'] / f'{self.id}-{kind}'
        self.dir.mkdir(parents=True, exist_ok=True)

    def log(self, msg):
        line = f'[{iso()}] {msg}'
        print(line, flush=True)
        with open(self.dir / 'run.log', 'a') as f:
            f.write(line + '\n')


def log(msg):
    print(f'[{iso()}] {msg}', flush=True)


# ---------------------------------------------------------------- processes

def tool_env(cfg):
    env = dict(os.environ)
    env['DEVELOPER_DIR'] = cfg['developerDir']
    env['PATH'] = ':'.join(dict.fromkeys(env.get('PATH', '').split(':') + ['/usr/bin', '/bin', '/usr/sbin', '/sbin']))
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['NO_COLOR'] = '1'
    env.setdefault('LANG', 'en_US.UTF-8')
    return env


ENV = None
GIT_ENV = None


def sh(args, cwd=None, timeout=600, check=True, logfile=None, env=None):
    args = [str(a) for a in args]
    if logfile:
        with open(logfile, 'w') as f:
            f.write(f'$ {" ".join(args)}\n(cwd {cwd})\n\n')
            f.flush()
            try:
                p = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT,
                                   timeout=timeout, env=env or ENV)
                rc = p.returncode
            except subprocess.TimeoutExpired:
                f.write(f'\n*** timed out after {timeout}s\n')
                rc = 124
        out = Path(logfile).read_text(errors='replace')
        if check and rc:
            raise Stop(f'{" ".join(args[:4])} failed ({rc}); see {logfile}')
        return subprocess.CompletedProcess(args, rc, out, '')
    p = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding='utf-8',
                       errors='replace', timeout=timeout, env=env or ENV)
    if check and p.returncode:
        raise Stop(f'{" ".join(args[:6])} failed ({p.returncode}): {(p.stderr or p.stdout).strip()[:800]}')
    return p


def git(cwd, *args, check=True, timeout=600):
    p = sh(['git', '-c', 'core.quotePath=false', *args], cwd=cwd, timeout=timeout, check=check, env=GIT_ENV)
    return p.stdout.rstrip('\n') if check else p


def is_ancestor(cwd, a, b):
    return git(cwd, 'merge-base', '--is-ancestor', a, b, check=False).returncode == 0


def notify(cfg, title, message):
    if not cfg['notify']:
        return
    q = lambda s: '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    try:
        subprocess.run(['/usr/bin/osascript', '-e', f'display notification {q(message)} with title {q(title)}'],
                       capture_output=True, timeout=20)
    except Exception as e:  # a missing notification must never fail the sync
        log(f'notification failed: {e!r}')


def idle_seconds():
    out = subprocess.run(['/usr/sbin/ioreg', '-c', 'IOHIDSystem'], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0.0


def game_processes(cfg):
    out = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True).stdout
    pattern = re.compile(cfg['gameProcessPattern'])
    return [line.strip() for line in out.splitlines() if pattern.search(line)]


def display_sleep_blockers():
    """Apps holding PreventUserIdleDisplaySleep (video playback, presentations)."""
    out = subprocess.run(['/usr/bin/pmset', '-g', 'assertions'], capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines()
            if re.search(r'PreventUserIdleDisplaySleep named', line) and 'powerd' not in line]


# ---------------------------------------------------------------- versions / toolchain

def upstream_target(cfg):
    repo, remote = cfg['repo'], cfg['upstreamRemote']
    if cfg['target'] == 'release':
        # Only tags that exist on the upstream remote (not fork-local tags), newest version first.
        names = [line.split('refs/tags/', 1)[1] for line in
                 git(repo, 'ls-remote', '--tags', '--refs', remote, 'v[0-9]*', timeout=120).splitlines() if 'refs/tags/' in line]
        releases = [n for n in names if re.fullmatch(r'v\d+(\.\d+)*(-[A-Za-z0-9.]+)?', n)]
        if not releases:
            raise Stop('no upstream release tag found')
        newest = max(releases, key=lambda n: (vtuple(n.split('-', 1)[0]), '-' not in n))
        return newest, git(repo, 'rev-parse', f'{newest}^{{commit}}')
    ref = f'{remote}/{cfg["upstreamBranch"]}'
    return ref, git(repo, 'rev-parse', ref)


def upstream_base_version(cwd, commit):
    tag = git(cwd, 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', commit)
    return re.sub(r'^v', '', re.sub(r'-(Beta|beta|alpha|rc\d*)$', '', tag))


def fork_version(cfg, ref):
    p = git(cfg['repo'], 'show', f'{ref}:{VERSION_FILE}', check=False)
    if p.returncode == 0:
        m = re.search(r'"([^"]+)"', p.stdout)
        if m:
            return m.group(1)
    st = State(cfg)
    if st.get('lastVersion'):
        return st.get('lastVersion')
    releases = cfg['deployDir'] / 'releases' if cfg['deployDir'] else None
    suffix = cfg['versionSuffix']
    found = sorted((p.name for p in releases.iterdir() if re.fullmatch(rf'.+-{suffix}-\d+', p.name)),
                   key=lambda n: int(n.rsplit('-', 1)[1])) if releases and releases.is_dir() else []
    return found[-1] if found else None


def next_version(cfg, current, base):
    suffix = cfg['versionSuffix']
    m = re.fullmatch(rf'(.+)-{re.escape(suffix)}-(\d+)', current or '')
    n = int(m.group(2)) + 1 if m and m.group(1) == base else 1
    releases = cfg['deployDir'] / 'releases' if cfg['deployDir'] else None
    while releases and (releases / f'{base}-{suffix}-{n}').exists():
        n += 1
    return f'{base}-{suffix}-{n}'


def swift_version(cfg, cwd):
    p = sh([*cfg['swift'], '--version'], cwd=cwd, check=False, timeout=120)
    m = re.search(r'Swift version (\d+(?:\.\d+)+)', p.stdout + p.stderr)
    return m.group(1) if m else None


def vtuple(v):
    return tuple(int(x) for x in re.findall(r'\d+', v or '0'))


# ---------------------------------------------------------------- overlap analysis

HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@')
SCOPE = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|final|'
                   r'override|mutating|nonmutating|nonisolated|lazy|convenience|required|dynamic)(?:\([^)]*\))?\s+)*'
                   r'(func|init|deinit|subscript|var)\b\s*([A-Za-z_]\w*)?(.*)$')
DECL = re.compile(r'^\+\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|final|'
                  r'override|mutating|nonisolated|lazy|convenience|required|indirect)(?:\([^)]*\))?\s+)*'
                  r'(?:func|var|let|struct|class|enum|protocol|typealias|actor|case)\s+([A-Za-z_]\w*)')
KEBAB = re.compile(r'"([a-z][a-z0-9]*(?:-[a-z0-9]+)+)"')
TOML_KEY = re.compile(r'^\+\s*\[*\s*([a-z][a-z0-9]*(?:-[a-z0-9]+)+)\s*(?:=|\])')
PROXIMITY = 3


def log_commits(cwd, rng, with_body=True):
    fmt = '%x1e%H%x1f%h%x1f%ad%x1f%s%x1f' + ('%b' if with_body else '') + '%x1d'
    out = git(cwd, 'log', '--date=short', f'--format={fmt}', '--name-only', rng)
    commits = []
    for chunk in out.split('\x1e')[1:]:
        head, _, files = chunk.partition('\x1d')
        full, short, date, subject, body = (head.split('\x1f') + [''] * 5)[:5]
        commits.append({'hash': full, 'short': short, 'date': date, 'subject': subject, 'body': body.strip(),
                        'files': [f for f in files.split('\n') if f.strip()]})
    return commits


def name_status(cwd, a, b):
    rows = {}
    for line in git(cwd, 'diff', '--name-status', '-M', a, b).splitlines():
        parts = line.split('\t')
        if len(parts) >= 2:
            rows[parts[1]] = {'status': parts[0][0], 'new': parts[-1]}
    return rows


def old_hunks(cwd, a, b, path):
    hunks = []
    for line in git(cwd, 'diff', '-U0', '--no-color', a, b, '--', path).splitlines():
        m = HUNK.match(line)
        if m:
            start, count = int(m.group(1)), int(m.group(2)) if m.group(2) is not None else 1
            hunks.append((start, max(start + count - 1, start)))
    return hunks


def scopes_at(cwd, rev, path):
    p = git(cwd, 'show', f'{rev}:{path}', check=False)
    if p.returncode:
        return []
    scopes = []
    for i, line in enumerate(p.stdout.splitlines(), 1):
        m = SCOPE.match(line)
        if m and (m.group(1) != 'var' or line.rstrip().endswith('{')):
            scopes.append((i, f'{m.group(1)} {m.group(2) or ""}'.strip()))
    return scopes


def enclosing(scopes, line):
    best = None
    for i, name in scopes:
        if i > line:
            break
        best = (i, name)
    return best


def added_lines(cwd, a, b, *paths):
    out = git(cwd, 'diff', '-U0', '--no-color', a, b, '--', *paths)
    return [l for l in out.splitlines() if l.startswith('+') and not l.startswith('+++')]


def analyze(cfg, base, target):
    """Compare fork changes (merge-base..base) with new upstream changes (merge-base..target)."""
    repo = cfg['repo']
    features = json.loads(FEATURES_PATH.read_text())['features']
    mb = git(repo, 'merge-base', base, target)
    fork_commits = log_commits(repo, f'{mb}..{base}', with_body=False)
    up_commits = log_commits(repo, f'{base}..{target}')
    compiled = {f['id']: [re.compile(k, re.I | re.M) for k in f['keywords']] for f in features}
    fork_patterns = {f['id']: [re.compile(k, re.I) for k in f['forkCommits']] for f in features}
    titles = {f['id']: f['title'] for f in features}

    file_features = {}
    for c in fork_commits:
        ids = [fid for fid, pats in fork_patterns.items() if any(p.search(c['subject']) for p in pats)]
        for path in c['files']:
            file_features.setdefault(path, set()).update(ids)
    for f in features:
        for doc in f['docs']:
            file_features.setdefault(doc, set()).add(f['id'])

    fork_files = name_status(repo, mb, base)
    up_files = name_status(repo, mb, target)
    up_commits_by_file = {}
    for c in up_commits:
        for path in c['files']:
            up_commits_by_file.setdefault(path, []).append(c['short'])

    blocking, info = [], []

    # 1. upstream deletes/renames files the fork modified
    for path, row in up_files.items():
        if row['status'] in 'DR' and path in fork_files and fork_files[path]['status'] == 'M':
            blocking.append({'kind': 'deleted-or-renamed', 'file': path, 'upstreamStatus': row['status'],
                             'renamedTo': row['new'] if row['status'] == 'R' else None,
                             'features': sorted(file_features.get(path, [])),
                             'upstreamCommits': up_commits_by_file.get(path, [])[:12]})

    # 2. both sides changed the same lines / the same function
    for path in sorted(set(fork_files) & set(up_files)):
        if fork_files[path]['status'] != 'M' or up_files[path]['status'] != 'M':
            continue
        fh, uh = old_hunks(repo, mb, base, path), old_hunks(repo, mb, target, path)
        scopes = scopes_at(repo, mb, path) if path.endswith('.swift') else []
        same_lines, same_scope = set(), set()
        for fs, fe in fh:
            for us, ue in uh:
                if us <= fe + PROXIMITY and fs <= ue + PROXIMITY:
                    same_lines.add(f'{fs}-{fe}~{us}-{ue}')
                    continue
                a, b = enclosing(scopes, fs), enclosing(scopes, us)
                if a and a == b:
                    same_scope.add(f'{a[1]} (L{a[0]})')
        entry = {'file': path, 'features': sorted(file_features.get(path, [])),
                 'upstreamCommits': up_commits_by_file.get(path, [])[:12],
                 'forkHunks': len(fh), 'upstreamHunks': len(uh)}
        if same_lines or same_scope:
            blocking.append({'kind': 'same-region', **entry, 'sameLines': sorted(same_lines)[:20],
                             'sameFunctions': sorted(same_scope)[:20]})
        else:
            info.append({'kind': 'same-file', **entry})

    # 3. both sides introduce the same new symbol / config key / command name
    def decls(lines):
        return {m.group(1) for l in lines if (m := DECL.match(l)) and len(m.group(1)) >= 5}

    fork_decls = decls(added_lines(repo, mb, base, 'Sources'))
    up_decls = decls(added_lines(repo, mb, target, 'Sources'))
    collisions = []
    for name in sorted(fork_decls & up_decls):
        if git(repo, 'grep', '-q', '-w', '-e', name, mb, '--', 'Sources', check=False).returncode != 0:
            collisions.append(name)
    fork_keys = {m for l in added_lines(repo, mb, base, 'Sources') for m in KEBAB.findall(l)}
    up_keys = {m for l in added_lines(repo, mb, target, 'Sources', 'docs') for m in KEBAB.findall(l)}
    up_keys |= {m.group(1) for l in added_lines(repo, mb, target, 'docs') if (m := TOML_KEY.match(l))}
    key_collisions = [k for k in sorted(fork_keys & up_keys)
                      if git(repo, 'grep', '-q', '-w', '-F', '-e', k, mb, '--', 'Sources', 'docs', check=False).returncode != 0]
    if collisions or key_collisions:
        blocking.append({'kind': 'name-collision', 'symbols': collisions, 'configOrCommandKeys': key_collisions})

    # 4. upstream commit messages / new docs that talk about the fork's features
    keyword_hits = []
    for c in up_commits:
        text = c['subject'] + '\n' + c['body']
        for fid, pats in compiled.items():
            for p in pats:
                m = p.search(text)
                if m:
                    keyword_hits.append({'feature': fid, 'commit': c['short'], 'subject': c['subject'],
                                         'match': m.group(0), 'pattern': p.pattern})
                    break
    doc_hits = []
    for line in added_lines(repo, mb, target, 'docs', 'README.md'):
        for fid, pats in compiled.items():
            for p in pats:
                m = p.search(line)
                if m:
                    doc_hits.append({'feature': fid, 'line': line[1:].strip()[:160], 'match': m.group(0)})
                    break
    if keyword_hits or doc_hits:
        blocking.append({'kind': 'feature-keywords', 'commits': keyword_hits, 'docs': doc_hits[:40]})

    renames = [c for c in up_commits if re.match(r'(\d+/\d+ )?(Rename|Refactoring|Prefactoring|Cleanup)\b', c['subject'])]
    return {'mergeBase': mb, 'forkCommits': len(fork_commits), 'upstreamCommits': up_commits,
            'forkFiles': len(fork_files), 'upstreamFiles': len(up_files), 'blocking': blocking, 'info': info,
            'featureTitles': titles, 'fileFeatures': {k: sorted(v) for k, v in file_features.items()},
            'upstreamCommitsByFile': up_commits_by_file, 'refactorCommits': [f"{c['short']} {c['subject']}" for c in renames]}


# ---------------------------------------------------------------- integration worktree

def merge_in_progress(wt):
    gitdir = Path(git(wt, 'rev-parse', '--absolute-git-dir'))
    return (gitdir / 'MERGE_HEAD').exists()


def ensure_worktree(cfg, run, name, start):
    wt, repo = cfg['worktree'], cfg['repo']
    if (wt / '.git').exists():
        if merge_in_progress(wt) or git(wt, 'status', '--porcelain'):
            raise Stop(f'integration worktree {wt} has uncommitted work; finish or `abandon` it first')
        git(wt, 'switch', '--quiet', '-C', name, start)
    else:
        git(repo, 'worktree', 'prune')
        git(repo, 'worktree', 'add', '--quiet', '-B', name, str(wt), start)
    run.log(f'integration worktree {wt} on {name} from {start[:12]}')


def merge(cfg, run, target_ref, target):
    wt = cfg['worktree']
    msg = f'Merge {target_ref} ({target[:8]}) into {cfg["branch"]}'
    p = git(wt, 'merge', '--no-ff', '--no-edit', '-m', msg, target, check=False, timeout=900)
    (run.dir / 'merge.log').write_text(p.stdout + p.stderr)
    if p.returncode == 0:
        return []
    conflicted = git(wt, 'diff', '--name-only', '--diff-filter=U').splitlines()
    if not conflicted:
        raise Stop(f'git merge failed without conflicts: {(p.stderr or p.stdout)[:500]}')
    result = []
    for path in conflicted:
        f = wt / path
        text = '\n' + f.read_text(errors='replace') if f.is_file() else ''
        markers = text.count('\n<<<<<<< ')
        kind = next((l.split('(')[1].split(')')[0] for l in p.stdout.splitlines() if l.startswith('CONFLICT') and path in l), 'content')
        result.append({'file': path, 'kind': kind, 'markers': markers})
    return result


def commit_if_changed(wt, message, *paths):
    git(wt, 'add', '--', *paths)
    if git(wt, 'diff', '--cached', '--name-only'):
        git(wt, 'commit', '--quiet', '-m', message)
        return True
    return False


def brand(cfg, run, cwd, version, upstream_commit):
    """Bake the local version. Old tree: commit versionGenerated.swift; new tree: Mach-O build info file."""
    if (cwd / VERSION_FILE).is_file():
        (cwd / VERSION_FILE).write_text(f'public let aeroSpaceAppVersion = "{version}"\n')
        if (cwd / GIT_HASH_FILE).is_file():
            suffix = cfg['versionSuffix'].lower()
            (cwd / GIT_HASH_FILE).write_text(f'public let gitHash = "{upstream_commit}+{suffix}"\n'
                                             f'public let gitShortHash = "{upstream_commit[:8]}+{suffix}"\n')
        commit_if_changed(cwd, f'build: brand upstream sync release {version}', VERSION_FILE, GIT_HASH_FILE)
        return None
    if (cwd / BUILD_INFO_SOURCE).is_file():
        return 'buildinfo'  # build info file is written per build (needs the final HEAD)
    raise Stop('neither versionGenerated.swift nor buildInfo.swift exists; cannot brand the version')


def release_link_flags(cwd, version, outdir):
    if not (cwd / BUILD_INFO_SOURCE).is_file() or (cwd / VERSION_FILE).is_file():
        return []
    head = git(cwd, 'rev-parse', 'HEAD')
    info = outdir / 'build-info.txt'
    info.write_text(f'{version}\n{head}\n{head[:8]}\n')
    return ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__aero_build', '-Xlinker', str(info)]


def run_checks(cfg, run, cwd, version, release=True):
    """Regenerate + run the offline checks, validate configs, build release binaries. Returns result dict."""
    res = {'steps': [], 'ok': True}

    def step(name, ok, detail=''):
        res['steps'].append({'name': name, 'ok': ok, 'detail': detail})
        run.log(f'{"PASS" if ok else "FAIL"} {name} {detail}')
        if not ok:
            res['ok'] = False
        return ok

    required = (cwd / '.swift-version').read_text().strip() if (cwd / '.swift-version').is_file() else None
    have = swift_version(cfg, cwd)
    res['toolchain'] = {'required': required, 'available': have, 'developerDir': cfg['developerDir'], 'swift': cfg['swift']}
    older = bool(required) and vtuple(have) < vtuple(required)
    step('toolchain', True, f'Swift {have}' + (f' (tree pins {required})' if required else ''))
    hint = f' — tree pins Swift {required}, configured toolchain is {have}' if older else ''

    if (cwd / CHECKS_GENERATOR).is_file():
        p = sh([sys.executable, CHECKS_GENERATOR, cwd], cwd=cwd, check=False, logfile=run.dir / 'checks-generate.log')
        if not step('generate offline checks', p.returncode == 0, p.stdout.strip().splitlines()[-1][:200] if p.stdout.strip() else ''):
            return res
        if commit_if_changed(cwd, 'test: regenerate offline compatibility checks after upstream sync', 'Sources/ZZZCompatChecks/main.swift'):
            run.log('committed regenerated Sources/ZZZCompatChecks/main.swift')
    else:
        step('generate offline checks', False, f'{CHECKS_GENERATOR} missing')
        return res

    timeout = cfg['buildTimeoutSeconds']
    p = sh([*cfg['swift'], 'build', '--product', 'zzz-compat-checks'], cwd=cwd, check=False, timeout=timeout,
           logfile=run.dir / 'build-checks-debug.log')
    if not step('build zzz-compat-checks (debug)', p.returncode == 0, first_errors(p.stdout) + (hint if p.returncode else '')):
        return res
    runner = cwd / '.build/debug/zzz-compat-checks'
    p = sh([runner], cwd=cwd, check=False, timeout=900, logfile=run.dir / 'checks-run.log')
    m = re.search(r'Offline checks: (\d+) groups, (\d+) assertions, (\d+) upstream fixtures, (\d+) failures', p.stdout)
    if m:
        res['offlineSummary'] = f'{m.group(1)} groups; {m.group(2)} assertions; {m.group(3)} upstream AX fixtures; ' \
                                f'{"zero" if m.group(4) == "0" else m.group(4)} failures'
    step('offline checks', p.returncode == 0 and bool(m) and m.group(4) == '0', res.get('offlineSummary', 'no summary line'))
    for conf in cfg['validateConfigs']:
        if not conf.is_file():
            continue
        p = sh([runner, '--validate-config', conf], cwd=cwd, check=False, timeout=120,
               logfile=run.dir / f'validate-{conf.name.lstrip(".")}.log')
        m = re.search(r'Config validation: (\d+) errors, (\d+) warnings', p.stdout)
        step(f'validate {conf}', p.returncode == 0 and bool(m) and m.group(1) == '0' and m.group(2) == '0',
             m.group(0) if m else 'no summary line')
    if not res['ok'] or not release:
        return res
    for product in ['AeroSpaceApp', 'aerospace']:
        flags = release_link_flags(cwd, version, run.dir)
        p = sh([*cfg['swift'], 'build', '-c', 'release', '--product', product, *flags], cwd=cwd, check=False,
               timeout=timeout, logfile=run.dir / f'build-release-{product}.log')
        if not step(f'build {product} (release)', p.returncode == 0, first_errors(p.stdout) + (hint if p.returncode else '')):
            return res
    return res


def first_errors(text, limit=3):
    errs = [l.strip() for l in text.splitlines() if ' error: ' in l or l.startswith('error:')]
    return ' | '.join(dict.fromkeys(errs))[:600] if errs else ''


# ---------------------------------------------------------------- publish / install

def publish(cfg, run, st, integ, checks):
    repo, branch, deploy = cfg['repo'], cfg['branch'], cfg['deployDir']
    if not deploy or not (deploy / 'package-local-release.py').is_file():
        raise Stop('deployDir with package-local-release.py is not configured; cannot package')
    if git(repo, 'branch', '--show-current') != branch:
        raise Stop(f'{repo} is not on {branch}; not fast-forwarding')
    if git(repo, 'status', '--porcelain'):
        raise Stop(f'{repo} has uncommitted changes; not fast-forwarding')
    if not is_ancestor(repo, branch, integ['branch']):
        raise Stop(f'{branch} moved since the integration started; run again')
    git(repo, 'merge', '--quiet', '--ff-only', integ['branch'])
    head = git(repo, 'rev-parse', 'HEAD')
    run.log(f'fast-forwarded {branch} to {head[:12]}')
    pushed = None
    if cfg['push']:
        p = git(repo, 'push', cfg['originRemote'], branch, check=False, timeout=300)
        pushed = p.returncode == 0
        run.log(f'push {cfg["originRemote"]} {branch}: {"ok" if pushed else "FAILED " + p.stderr.strip()[:300]}')
    version = integ['version']
    for product in ['AeroSpaceApp', 'aerospace']:
        flags = release_link_flags(repo, version, run.dir)
        sh([*cfg['swift'], 'build', '-c', 'release', '--product', product, *flags], cwd=repo,
           timeout=cfg['buildTimeoutSeconds'], logfile=run.dir / f'publish-build-{product}.log')
    capability = f'upstream sync: {integ["targetRef"]} {integ["target"][:8]} merged into {branch} at {head[:8]}'
    sh([sys.executable, deploy / 'package-local-release.py', '--repository', repo, '--version', version,
        '--offline-summary', checks.get('offlineSummary', 'unknown'), '--capability', capability],
       cwd=deploy, timeout=1200, logfile=run.dir / 'package.log')
    manifest = json.loads((deploy / 'releases' / version / 'manifest.json').read_text())
    candidate = make_candidate(cfg, version, head, checks)
    git(cfg['worktree'], 'switch', '--quiet', '--detach')
    git(repo, 'branch', '-d', integ['branch'], check=False)
    pending = {'version': version, 'candidateDirectory': str(candidate.relative_to(deploy)), 'head': head,
               'archiveSHA256': manifest.get('archiveSHA256'), 'packagedAt': iso(), 'pushed': pushed}
    st.update(status='published', pendingInstall=pending, lastVersion=version, integration=None,
              lastPublished=pending)
    return pending


def make_candidate(cfg, version, head, checks):
    """switch.py needs a candidate directory; ours keeps the current config byte-for-byte."""
    conf = Path('~/.aerospace.toml').expanduser()
    out = cfg['deployDir'] / 'rules-candidate' / f'upstream-sync-{version}'
    out.mkdir(parents=True, exist_ok=False)
    shutil.copy2(conf, out / 'aerospace.toml')
    shutil.copy2(conf, out / 'baseline.aerospace.toml')
    digest = hashlib.sha256(conf.read_bytes()).hexdigest()
    validation = {'kind': f'{version}: upstream sync, configuration unchanged; parsed by the {version} offline runner (--validate-config)',
                  'baseline_sha256': digest, 'candidate_sha256': digest,
                  'checks': {s['name']: s['detail'] for s in checks['steps']},
                  'source_commits': {'build': head[:8]}}
    (out / 'validation.json').write_text(json.dumps(validation, ensure_ascii=False, indent=2) + '\n')
    return out


def installed_version():
    plist = Path('/Applications/AeroSpace.app/Contents/Info.plist')
    if not plist.is_file():
        return None
    import plistlib
    return plistlib.loads(plist.read_bytes()).get('CFBundleShortVersionString')


def install_command(cfg, pending):
    return f'uv run {Path(__file__).resolve()} install --now'


def do_install(cfg, st, now_requested):
    pending = st.get('pendingInstall')
    if not pending:
        log('install: nothing pending')
        return 0
    if not cfg['deployDir'] or not (cfg['deployDir'] / 'switch.py').is_file():
        log('install: deployDir with switch.py is not configured')
        return 1
    if installed_version() == pending['version']:
        log(f'install: {pending["version"]} already installed')
        st.update(status='installed', pendingInstall=None, lastInstalled={**pending, 'installedAt': iso(), 'by': 'already'})
        return 0
    games = game_processes(cfg)
    if games:
        log(f'install: deferred, game processes running: {games[:3]}')
        return 0
    if not now_requested:
        if not cfg['autoInstall']:
            log('install: autoInstall is off; waiting for a manual `install --now`')
            return 0
        idle = idle_seconds()
        if idle < cfg['installIdleMinutes'] * 60:
            log(f'install: deferred, user idle only {idle / 60:.0f} min')
            return 0
        blockers = display_sleep_blockers()
        if blockers:
            log(f'install: deferred, display sleep blocked by {blockers[:2]}')
            return 0
    deploy = cfg['deployDir']
    rundir = deploy / 'runs' / (now().strftime('%Y%m%d-%H%M%S') + '-upstream-sync')
    args = [sys.executable, deploy / 'switch.py', 'install', '--release', pending['version'],
            '--candidate-directory', pending['candidateDirectory'], '--skip-frame-guard', '--run', rundir]
    if not now_requested and idle_seconds() < cfg['installIdleMinutes'] * 60:
        log('install: user came back; deferred')
        return 0
    log(f'install: {" ".join(map(str, args))}')
    st.update(status='installing', installRun=str(rundir))
    p = sh(args, cwd=deploy, check=False, timeout=300)
    status = None
    try:
        status = json.loads(p.stdout[p.stdout.index('{'):]).get('status')
    except Exception:
        pass
    log(f'install: exit {p.returncode}, status {status}; {p.stderr.strip()[-500:]}')
    if p.returncode == 0 and status in ('active', 'active-without-frame-guard', 'active-with-context-recovery-needed'):
        st.update(status='installed', pendingInstall=None, lastInstalled={**pending, 'installedAt': iso(), 'run': str(rundir)})
        notify(cfg, 'AeroSpace 已更新', f'已安装 {pending["version"]}（空闲时自动安装）')
        return 0
    state = json.loads((rundir / 'state.json').read_text()) if (rundir / 'state.json').is_file() else {}
    swapped = any(e.get('kind') == 'stop-signal' for e in state.get('events', []))
    rolled = None
    if swapped:
        r = sh([sys.executable, deploy / 'switch.py', 'rollback', '--run', rundir], cwd=deploy, check=False, timeout=300)
        rolled = r.returncode == 0
        log(f'install: rollback exit {r.returncode}: {(r.stdout + r.stderr).strip()[-500:]}')
    st.update(status='install-failed', installFailure={'run': str(rundir), 'exit': p.returncode, 'status': status,
                                                       'rolledBack': rolled, 'at': iso()})
    notify(cfg, 'AeroSpace 更新安装失败', f'{pending["version"]} 安装失败' + ('，已回滚' if rolled else '，未改动' if not swapped else '，回滚失败') + f'；记录 {rundir}')
    return 1


# ---------------------------------------------------------------- report

FEATURE_NOTE = {
    'deleted-or-renamed': '上游删除/重命名了 fork 修改过的文件',
    'same-region': '上游与 fork 改了同一段代码或同一个函数',
    'name-collision': '上游新增了与 fork 同名的符号 / 配置键 / 命令名',
    'feature-keywords': '上游提交信息或文档提到了 fork 功能相关的关键词',
}
STATUS_TEXT = {
    'needs-discussion': '需要讨论（已停止，主分支未改动）',
    'published': '已自动合并并打包',
    'up-to-date': '已是最新',
    'failed': '运行出错（主分支未改动）',
    'dry-run': '预演（没有改动任何分支）',
}


def write_report(cfg, run, ctx):
    a = ctx.get('analysis') or {}
    titles = a.get('featureTitles', {})
    feat = lambda ids: ', '.join(ids) or '—'
    L = []
    w = L.append
    w(f'# AeroSpace 上游同步报告 {run.id}\n')
    w(f'**结论：{STATUS_TEXT.get(ctx["status"], ctx["status"])}**\n')
    for r in ctx.get('reasons', []):
        w(f'- {r}')
    w('')
    if titles:
        w('功能代号：' + '；'.join(f'`{k}` = {v}' for k, v in titles.items()) + '\n')
    w('## 基本信息\n')
    w(f'- fork 分支：`{cfg["branch"]}` @ `{ctx.get("base", "")[:12]}`（版本 {ctx.get("currentVersion")}）')
    w(f'- 上游目标：`{ctx.get("targetRef")}` @ `{ctx.get("target", "")[:12]}`；共同祖先 `{a.get("mergeBase", "")[:12]}`')
    w(f'- 新上游提交 {len(a.get("upstreamCommits", []))} 个，改动 {a.get("upstreamFiles", "?")} 个文件；fork 自有提交 {a.get("forkCommits", "?")} 个，改动 {a.get("forkFiles", "?")} 个文件')
    if ctx.get('integration'):
        i = ctx['integration']
        w(f'- 集成分支：`{i["branch"]}`（worktree `{cfg["worktree"]}`）；计划版本号 `{i["version"]}`')
    w(f'- 本次运行目录：`{run.dir}`')
    w('')
    conflicts = ctx.get('conflicts') or []
    if conflicts:
        w(f'## 合并冲突（{len(conflicts)} 个文件）\n')
        w('| 文件 | 类型 | 冲突块 | 涉及 fork 功能 | 碰到它的上游提交 |')
        w('|---|---|---|---|---|')
        for c in conflicts:
            ups = a.get('upstreamCommitsByFile', {}).get(c['file'], [])
            w(f'| `{c["file"]}` | {c["kind"]} | {c["markers"]} | {feat(a.get("fileFeatures", {}).get(c["file"], []))} | {" ".join(ups[:6])}{" …" if len(ups) > 6 else ""} |')
        w('')
    blocking = a.get('blocking', [])
    if blocking:
        w('## 与 fork 功能的重叠\n')
        for b in blocking:
            if b['kind'] in ('same-region', 'deleted-or-renamed'):
                continue
            w(f'### {FEATURE_NOTE.get(b["kind"], b["kind"])}\n')
            if b['kind'] == 'feature-keywords':
                by_feature = {}
                for h in b['commits']:
                    by_feature.setdefault(h['feature'], []).append(h)
                for fid, hits in by_feature.items():
                    w(f'- **{titles.get(fid, fid)}**')
                    for h in hits[:15]:
                        w(f'  - `{h["commit"]}` {h["subject"]}（命中 “{h["match"]}”）')
                    if len(hits) > 15:
                        w(f'  - …另外 {len(hits) - 15} 个')
                if b['docs']:
                    w('- 上游文档新增内容命中：')
                    for d in b['docs'][:12]:
                        w(f'  - [{d["feature"]}] {d["line"]}')
                w('')
            elif b['kind'] == 'name-collision':
                if b['symbols']:
                    w(f'- 同名新符号：{", ".join(f"`{s}`" for s in b["symbols"])}')
                if b['configOrCommandKeys']:
                    w(f'- 同名新配置键/命令/格式变量：{", ".join(f"`{s}`" for s in b["configOrCommandKeys"])}')
                w('')
        regions = [b for b in blocking if b['kind'] in ('same-region', 'deleted-or-renamed')]
        if regions:
            w(f'### {FEATURE_NOTE["same-region"]} / {FEATURE_NOTE["deleted-or-renamed"]}（{len(regions)} 个文件）\n')
            w('| 文件 | 情况 | 涉及 fork 功能 | 同一函数 / 相邻行 | 上游提交 |')
            w('|---|---|---|---|---|')
            for b in regions:
                if b['kind'] == 'deleted-or-renamed':
                    what = f'上游{"重命名为 `" + b["renamedTo"] + "`" if b["renamedTo"] else "删除"}'
                    detail = ''
                else:
                    what = '同区域'
                    detail = '; '.join(b['sameFunctions'][:6] + ([f'相邻行 {len(b["sameLines"])} 处'] if b['sameLines'] else []))
                w(f'| `{b["file"]}` | {what} | {feat(b["features"])} | {detail} | {" ".join(b["upstreamCommits"][:6])} |')
            w('')
    if a.get('info'):
        w('## 同文件但不同位置（仅提示，不阻止）\n')
        for i in a['info']:
            w(f'- `{i["file"]}`（{feat(i["features"])}）：上游 {" ".join(i["upstreamCommits"][:6])}')
        w('')
    if a.get('refactorCommits'):
        w('## 上游重构/改名提交（解决冲突时要跟着改 fork 代码）\n')
        for c in a['refactorCommits'][:40]:
            w(f'- {c}')
        w('')
    checks = ctx.get('checks')
    w('## 检查与构建\n')
    if checks:
        for s in checks['steps']:
            w(f'- {"✅" if s["ok"] else "❌"} {s["name"]}：{s["detail"]}')
    else:
        w('- 未运行（' + ('合并有冲突，先解决冲突' if conflicts else '见上文') + '）')
    for note in ctx.get('notes', []):
        w(f'- {note}')
    w('')
    w('## 下一步\n')
    for step in ctx.get('next', []):
        w(f'- {step}')
    w('')
    ups = a.get('upstreamCommits', [])
    if ups:
        flagged = {h['commit'] for b in blocking if b['kind'] == 'feature-keywords' for h in b['commits']}
        w(f'## 附：全部新上游提交（{len(ups)}，⚠️ = 命中功能关键词）\n')
        for c in ups:
            w(f'- {"⚠️ " if c["short"] in flagged else ""}`{c["short"]}` {c["date"]} {c["subject"]}')
        w('')
    (run.dir / 'report.md').write_text('\n'.join(L))
    slim = {k: v for k, v in ctx.items() if k != 'analysis'}
    slim['analysis'] = {k: v for k, v in a.items() if k not in ('upstreamCommits',)} if a else None
    (run.dir / 'report.json').write_text(json.dumps(slim, ensure_ascii=False, indent=2, default=str) + '\n')
    latest = cfg['reportsDir'] / 'latest-report.md'
    try:
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(run.dir / 'report.md')
    except OSError:
        pass
    return run.dir / 'report.md'


# ---------------------------------------------------------------- commands

def fetch(cfg, log_fn):
    git(cfg['repo'], 'fetch', '--quiet', '--tags', cfg['upstreamRemote'], timeout=600)
    git(cfg['repo'], 'fetch', '--quiet', '--prune', cfg['originRemote'], timeout=600, check=False)
    log_fn('fetched upstream and origin')


def cmd_run(cfg, args):
    st = State(cfg)
    st.update(lastSyncAttempt=iso())
    repo, branch = cfg['repo'], cfg['branch']
    if st.get('status') == 'needs-discussion' and st.get('integration'):
        return remind_pending(cfg, st)
    fetch(cfg, log)
    target_ref, target = upstream_target(cfg)
    base = git(repo, 'rev-parse', branch)
    if is_ancestor(repo, target, base):
        what = 'no new upstream release' if cfg['target'] == 'release' else 'no new upstream commits'
        log(f'{what}: newest {target_ref} ({target[:12]}) is already in {branch}; nothing to do')
        st.update(status='published' if st.get('pendingInstall') else 'up-to-date', lastUpToDate=iso(), lastTarget=target)
        return 0
    run = Run(cfg, 'sync')
    ctx = {'status': None, 'reasons': [], 'notes': [], 'next': [], 'base': base, 'target': target, 'targetRef': target_ref}
    try:
        return sync(cfg, run, st, ctx, base, target_ref, target)
    except Stop as e:
        ctx['status'] = 'failed'
        ctx['reasons'].append(str(e))
        ctx['next'].append('修好原因后再运行 `sync-upstream.py run`；主分支没有被改动。')
        report = write_report(cfg, run, ctx)
        run.log(f'stopped: {e}')
        previous = st.get('lastFailure') or {}
        repeat = previous.get('reason') == str(e) and now() - dt.datetime.fromisoformat(previous['notifiedAt']) < dt.timedelta(hours=72) \
            if previous.get('notifiedAt') else False
        st.update(status='failed', lastFailure={'at': iso(), 'reason': str(e), 'report': str(report),
                                                'notifiedAt': previous.get('notifiedAt') if repeat else iso()})
        if not repeat:
            notify(cfg, 'AeroSpace 上游同步出错', f'{str(e)[:120]}；报告：{report}')
        return 1


def sync(cfg, run, st, ctx, base, target_ref, target):
    repo, branch = cfg['repo'], cfg['branch']
    run.log(f'{branch} {base[:12]} vs {target_ref} {target[:12]}')
    analysis = analyze(cfg, base, target)
    ctx['analysis'] = analysis
    current = fork_version(cfg, branch)
    ctx['currentVersion'] = current
    version = next_version(cfg, current, upstream_base_version(repo, target))
    name = f'upstream-sync/{run.id[:8]}-{target[:8]}'
    integ = {'branch': name, 'base': base, 'target': target, 'targetRef': target_ref, 'version': version,
             'startedAt': iso(), 'run': str(run.dir)}
    ctx['integration'] = integ
    toolchain_preflight(cfg, run, ctx, target)
    ensure_worktree(cfg, run, name, base)
    conflicts = merge(cfg, run, target_ref, target)
    ctx['conflicts'] = conflicts
    if conflicts:
        ctx['reasons'].append(f'合并冲突：{len(conflicts)} 个文件（worktree 保持在未完成的合并状态，供解决）')
    else:
        brand(cfg, run, cfg['worktree'], version, target)
        ctx['checks'] = run_checks(cfg, run, cfg['worktree'], version)
        if not ctx['checks']['ok']:
            ctx['reasons'].append('检查或构建失败：' + '；'.join(s['name'] for s in ctx['checks']['steps'] if not s['ok']))
        integ['head'] = git(cfg['worktree'], 'rev-parse', 'HEAD')
    ctx['reasons'] += block_reasons(analysis)
    if ctx['reasons']:
        return stop_for_discussion(cfg, run, st, ctx, integ)
    pending = publish(cfg, run, st, integ, ctx['checks'])
    ctx['status'] = 'published'
    ctx['reasons'].append(f'无冲突、无功能重叠、检查和构建全部通过；已快进 {branch} 并打包 {version}')
    ctx['next'].append(f'安装：{"空闲时自动安装" if cfg["autoInstall"] else "运行 `" + install_command(cfg, pending) + "`"}')
    report = write_report(cfg, run, ctx)
    notify(cfg, 'AeroSpace 上游同步完成', f'已合并上游 {target[:8]}，打包 {version}' +
           ('，空闲时自动安装' if cfg['autoInstall'] else f'；安装：{install_command(cfg, pending)}'))
    run.log(f'published {version}; report {report}')
    return 0


def toolchain_preflight(cfg, run, ctx, target):
    """Upstream pins its Swift toolchain in .swift-version; compare with the configured one before building."""
    p = git(cfg['repo'], 'show', f'{target}:.swift-version', check=False)
    required = p.stdout.strip() if p.returncode == 0 else None
    have = swift_version(cfg, cfg['repo'])
    ctx['toolchain'] = {'upstreamRequires': required, 'available': have, 'developerDir': cfg['developerDir'], 'swift': cfg['swift']}
    run.log(f'toolchain: upstream wants {required}, configured {" ".join(cfg["swift"])} (DEVELOPER_DIR={cfg["developerDir"]}) is {have}')
    if required and vtuple(have) < vtuple(required):
        # Only a hint: the fork's own tree already pins 6.3.2 and builds fine with 6.2.4. A failing build decides.
        ctx['notes'].append(f'工具链提示：上游 `.swift-version` 写的是 Swift {required}，当前配置的是 Swift {have}'
                            f'（{cfg["developerDir"]}）；只有编译失败时才算问题。')


def block_reasons(analysis):
    reasons = []
    for kind in ['deleted-or-renamed', 'same-region']:
        files = [b['file'] for b in analysis['blocking'] if b['kind'] == kind]
        if files:
            reasons.append(f'{FEATURE_NOTE[kind]}：{len(files)} 个文件（{", ".join(Path(f).name for f in files[:6])}{" …" if len(files) > 6 else ""}）')
    for b in analysis['blocking']:
        if b['kind'] == 'feature-keywords':
            feats = sorted({h['feature'] for h in b['commits']} | {d['feature'] for d in b['docs']})
            reasons.append(f'{FEATURE_NOTE[b["kind"]]}：{len(b["commits"])} 个提交（{", ".join(feats)}）')
        elif b['kind'] == 'name-collision':
            reasons.append(f'{FEATURE_NOTE[b["kind"]]}：{", ".join((b["symbols"] + b["configOrCommandKeys"])[:8])}')
    return reasons


def stop_for_discussion(cfg, run, st, ctx, integ):
    ctx['status'] = 'needs-discussion'
    wt = cfg['worktree']
    ctx['next'] += [
        f'查看：`cd {wt} && git status`（集成分支 `{integ["branch"]}`；`{cfg["branch"]}` 没有被改动）',
        '和用户讨论上面的冲突/重叠，决定保留 fork 行为、改用上游实现，还是两者结合。',
        f'解决后在 worktree 里提交，然后运行 `uv run {Path(__file__).resolve()} approve`（会重新跑检查和构建，通过后才快进、推送、打包）。',
        f'放弃这次合并：`uv run {Path(__file__).resolve()} abandon`。',
    ]
    report = write_report(cfg, run, ctx)
    st.update(status='needs-discussion', integration={**integ, 'report': str(report)}, lastReminderAt=iso(),
              lastReminderTarget=integ['target'])
    first = ctx['reasons'][0] if ctx['reasons'] else ''
    notify(cfg, 'AeroSpace 上游同步需要讨论', f'{first[:90]}。报告：{report}')
    run.log(f'needs discussion; report {report}')
    return EXIT_DISCUSS


def remind_pending(cfg, st):
    integ = st.get('integration')
    try:
        fetch(cfg, log)
        _, target = upstream_target(cfg)
        newer = int(git(cfg['repo'], 'rev-list', '--count', f'{integ["target"]}..{target}'))
    except Stop as e:
        log(f'pending discussion; fetch failed: {e}')
        return EXIT_DISCUSS
    log(f'pending discussion since {integ["startedAt"]} ({integ["branch"]}); upstream has {newer} newer commits')
    last = dt.datetime.fromisoformat(st.get('lastReminderAt', integ['startedAt']))
    if newer and st.get('lastReminderTarget') != target and now() - last > dt.timedelta(hours=72):
        notify(cfg, 'AeroSpace 上游同步仍待讨论', f'上次的合并还没处理；上游又多了 {newer} 个提交。报告：{integ.get("report")}')
        st.update(lastReminderAt=iso(), lastReminderTarget=target)
    return EXIT_DISCUSS


def cmd_approve(cfg, args):
    st = State(cfg)
    integ = st.get('integration')
    if st.get('status') != 'needs-discussion' or not integ:
        raise SystemExit('nothing waits for approval')
    wt = cfg['worktree']
    if merge_in_progress(wt) or git(wt, 'diff', '--name-only', '--diff-filter=U'):
        raise SystemExit(f'merge in {wt} is not finished: resolve conflicts and `git commit` first')
    if git(wt, 'status', '--porcelain'):
        raise SystemExit(f'{wt} has uncommitted changes; commit them first')
    if git(wt, 'branch', '--show-current') != integ['branch']:
        raise SystemExit(f'{wt} is not on {integ["branch"]}')
    if not is_ancestor(wt, integ['target'], 'HEAD') or not is_ancestor(wt, cfg['branch'], 'HEAD'):
        raise SystemExit(f'{integ["branch"]} must contain both {cfg["branch"]} and upstream {integ["target"][:8]}')
    run = Run(cfg, 'approve')
    ctx = {'status': None, 'reasons': [], 'notes': ['这是讨论后的确认运行：重叠项已由用户确认，只看检查和构建。'], 'next': [],
           'base': integ['base'], 'target': integ['target'], 'targetRef': integ['targetRef'], 'integration': integ}
    try:
        ctx['analysis'] = analyze(cfg, git(cfg['repo'], 'rev-parse', cfg['branch']), integ['target'])
        ctx['currentVersion'] = fork_version(cfg, cfg['branch'])
        if (cfg['deployDir'] / 'releases' / integ['version']).exists():
            integ['version'] = next_version(cfg, integ['version'], integ['version'].rsplit(f'-{cfg["versionSuffix"]}-', 1)[0])
        brand(cfg, run, wt, integ['version'], integ['target'])
        ctx['checks'] = run_checks(cfg, run, wt, integ['version'])
        if not ctx['checks']['ok']:
            ctx['reasons'].append('检查或构建失败：' + '；'.join(s['name'] for s in ctx['checks']['steps'] if not s['ok']))
            ctx['status'] = 'needs-discussion'
            ctx['next'].append(f'在 `{wt}` 修好后提交，再运行 approve。')
            report = write_report(cfg, run, ctx)
            st.update(integration={**integ, 'report': str(report)})
            print(report)
            return EXIT_DISCUSS
        pending = publish(cfg, run, st, integ, ctx['checks'])
    except Stop as e:
        ctx['status'] = 'failed'
        ctx['reasons'].append(str(e))
        print(write_report(cfg, run, ctx))
        return 1
    ctx['status'] = 'published'
    ctx['reasons'].append(f'确认后已快进 {cfg["branch"]} 并打包 {pending["version"]}')
    ctx['next'].append(f'安装：`{install_command(cfg, pending)}`' + ('（或等空闲时自动安装）' if cfg['autoInstall'] else ''))
    print(write_report(cfg, run, ctx))
    return 0


def cmd_abandon(cfg, args):
    st = State(cfg)
    integ = st.get('integration')
    if not integ:
        raise SystemExit('no kept integration')
    wt = cfg['worktree']
    if merge_in_progress(wt):
        git(wt, 'merge', '--abort')
    if git(wt, 'status', '--porcelain'):
        raise SystemExit(f'{wt} still has uncommitted changes; clean them up by hand first')
    git(wt, 'switch', '--quiet', '--detach')
    git(cfg['repo'], 'branch', '-D', integ['branch'], check=False)
    st.update(status='abandoned', integration=None, lastAbandoned={**integ, 'at': iso()})
    log(f'abandoned {integ["branch"]}')
    return 0


def cmd_tick(cfg, args):
    st = State(cfg)
    if st.get('pendingInstall'):
        do_install(cfg, st, now_requested=False)
    last = st.get('lastSyncAttempt')
    elapsed = (now() - dt.datetime.fromisoformat(last)).total_seconds() / 3600 if last else 1e9
    interval = cfg['syncIntervalHours']
    if elapsed < interval:
        return 0
    if elapsed < 2 * interval and idle_seconds() < cfg['syncIdleMinutes'] * 60:
        log(f'sync due ({elapsed:.1f} h) but user active; waiting for idle')
        return 0
    return cmd_run(cfg, args)


def cmd_analyze(cfg, args):
    """Dry run: overlap analysis + `git merge-tree` conflict preview. Touches no branch, worktree or state."""
    fetch(cfg, log)
    target_ref, target = upstream_target(cfg)
    base = git(cfg['repo'], 'rev-parse', cfg['branch'])
    run = Run(cfg, 'analyze')
    ctx = {'status': 'dry-run', 'reasons': [], 'notes': ['预演（analyze）：没有创建集成分支，也没有构建。冲突来自 `git merge-tree`。'],
           'next': [], 'base': base, 'target': target, 'targetRef': target_ref, 'currentVersion': fork_version(cfg, cfg['branch'])}
    if is_ancestor(cfg['repo'], target, base):
        ctx['reasons'].append('已包含上游目标，无需同步')
    else:
        ctx['analysis'] = analysis = analyze(cfg, base, target)
        p = git(cfg['repo'], 'merge-tree', '--write-tree', '--name-only', '--messages', base, target, check=False)
        conflicted = p.stdout.split('\n\n', 1)[0].splitlines()[1:] if p.returncode == 1 else []
        msgs = p.stdout.split('\n\n', 1)[1] if '\n\n' in p.stdout else ''
        ctx['conflicts'] = [{'file': f, 'markers': '?', 'kind': next((l.split('(')[1].split(')')[0] for l in msgs.splitlines()
                                                                   if l.startswith('CONFLICT') and f in l), 'content')} for f in conflicted]
        if conflicted:
            ctx['reasons'].append(f'合并冲突：{len(conflicted)} 个文件')
        ctx['reasons'] += block_reasons(analysis)
    print(write_report(cfg, run, ctx))
    return 0


def cmd_status(cfg, args):
    print(json.dumps(State(cfg).data, ensure_ascii=False, indent=2))
    return 0


def main():
    global ENV, GIT_ENV
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['run', 'analyze', 'approve', 'install', 'tick', 'status', 'abandon'])
    parser.add_argument('--repo')
    parser.add_argument('--branch')
    parser.add_argument('--target', choices=['main', 'release'])
    parser.add_argument('--worktree')
    parser.add_argument('--deploy-dir')
    parser.add_argument('--developer-dir')
    parser.add_argument('--no-push', action='store_true')
    parser.add_argument('--no-notify', action='store_true')
    parser.add_argument('--now', action='store_true', help='install: skip the idle checks (still refuses while a game runs)')
    args = parser.parse_args()
    cfg = load_config(args)
    ENV = tool_env(cfg)
    GIT_ENV = {**ENV, 'LC_ALL': 'C'}  # stable English git messages for parsing
    if args.command == 'status':
        return cmd_status(cfg, args)
    with Lock(cfg):
        if args.command == 'install':
            return do_install(cfg, State(cfg), now_requested=args.now)
        return {'run': cmd_run, 'analyze': cmd_analyze, 'approve': cmd_approve, 'tick': cmd_tick,
                'abandon': cmd_abandon}[args.command](cfg, args)


if __name__ == '__main__':
    sys.exit(main())
