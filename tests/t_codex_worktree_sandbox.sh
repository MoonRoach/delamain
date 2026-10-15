#!/bin/bash
# Real Git layouts and detached CLI boundary; no model or OS sandbox required in CI.
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a HUB_TAG=hub-test CODEX_BIN="$T/fake_codex.py"
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import json, os, subprocess, sys, tempfile, time, tomllib
from pathlib import Path
bins, home = map(Path, sys.argv[1:])

def run(*args, cwd=None):
    return subprocess.run(list(map(str, args)), cwd=cwd, text=True, capture_output=True, check=True)

def git(*args, cwd):
    return run('git', *args, cwd=cwd).stdout.strip()

def wait(role):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        r = run(bins/'agent', 'status', role)
        if 'ALIVE' not in r.stdout:
            return
        time.sleep(.1)
    raise AssertionError(f'{role} did not finish')

def spawn(role, cwd, *args):
    r = run(bins/'agent', 'spawn', '--engine', 'codex', '--role', role,
            '--cwd', cwd, '--model', 'gpt-fixture', '--brief', brief, *args)
    wait(role)
    return r

def roots(row):
    config = tomllib.loads('\n'.join(row[i+1] for i, a in enumerate(row) if a == '-c'))
    return config.get('sandbox_workspace_write', {}).get('writable_roots', [])

with tempfile.TemporaryDirectory(prefix='delamain git roots ') as tmp:
    base = Path(tmp).resolve()
    repo, wt = base/'main', base/'linked worktree'
    repo.mkdir()
    git('init', cwd=repo)
    git('config', 'user.name', 'Sandbox Test', cwd=repo)
    git('config', 'user.email', 'sandbox@example.invalid', cwd=repo)
    (repo/'tracked').write_text('initial\n')
    git('add', 'tracked', cwd=repo)
    git('commit', '-m', 'initial', cwd=repo)
    git('worktree', 'add', '-b', 'nested/task', wt, cwd=repo)
    common = repo/'.git'
    gitdir = Path(git('rev-parse', '--absolute-git-dir', cwd=wt))
    expected = {str(home), str(gitdir), str(common/'objects'),
                str(common/'refs/heads'), str(common/'logs/refs/heads')}
    brief = home/'brief.md'
    brief.write_text('Read the repository and report findings.\n')
    policy = json.dumps({'type': 'workspace-write', 'network_access': False,
                         'writable_roots': [str(base/'extra')]})
    spawn('executor', wt, '--sandbox-policy', policy)
    run(bins/'agent', 'send', 'executor', 'continue with the same sandbox')
    wait('executor')
    rows = [json.loads(l) for l in (wt/'codex-argv.jsonl').read_text().splitlines()]
    assert len(rows) == 2 and rows[1][:2] == ['exec', 'resume'], rows
    for row in rows:
        assert set(roots(row)) == expected | {str(base/'extra')}, roots(row)
        assert str(common) not in roots(row) and str(repo) not in roots(row), roots(row)
        assert 'sandbox_workspace_write.network_access=false' in row, row
    print('PASS worktree commit metadata roots and explicit policy persist on real spawn/resume')
    for role, cwd in [('plain', repo), ('outside', home)]:
        spawn(role, cwd, '--sandbox', 'workspace-write')
        row = json.loads((cwd/'codex-argv.jsonl').read_text().splitlines()[-1])
        assert roots(row) == [str(home)], roots(row)
    print('PASS ordinary checkout and non-repository cwd do not gain Git roots')
    r = spawn('review-readonly', wt, '--sandbox', 'read-only')
    assert r.stderr.count('cannot write its report or journal') == 1, r.stderr
    assert 'use workspace-write with --cwd in the hub home' in r.stderr, r.stderr
    row = json.loads((wt/'codex-argv.jsonl').read_text().splitlines()[-1])
    assert not roots(row), roots(row)
    print('PASS read-only review warns exactly once and gains no writable roots')
    for role, args in [('preview', ['--sandbox', 'read-only']),
                       ('worker', ['--sandbox', 'read-only']),
                       ('review-writable', ['--sandbox', 'workspace-write']),
                       ('tagged', ['--permission-mode', 'plan', '--tag', 'external-review'])]:
        r = spawn(role, home, *args)
        assert ('cannot write its report or journal' in r.stderr) == (role == 'tagged'), r.stderr
    print('PASS review tags and effective permission mode warn; unrelated roles/writable review stay quiet')
PY
check $? 0 'workspace-write worktree and read-only reviewer controls'
exit $fail
