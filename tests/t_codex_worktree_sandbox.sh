#!/bin/bash
# Real Git layouts and detached CLI boundary; no model or OS sandbox required in CI.
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a HUB_TAG=hub-test CODEX_BIN="$T/fake_codex.py"
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import json, os, subprocess, sys, tempfile, time, tomllib
from pathlib import Path
bins, home = map(Path, sys.argv[1:])
failures=[]
def verify(name, assertion):
    try:
        assertion()
        print('PASS '+name)
    except AssertionError as e:
        failures.append(name)
        print('FAIL '+name+': '+str(e))

def require(condition, evidence):
    assert condition,evidence


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
    required = {str(home), str(common/'objects')}
    branch_roots = {str(common/p) for p in ('refs/heads/nested/task', 'refs/heads/nested/task.lock',
                                          'logs/refs/heads/nested/task', 'logs/refs/heads/nested/task.lock')}
    forbidden = {str(gitdir), str(common), str(repo), str(common/'refs/heads'),
                 str(common/'logs/refs/heads'), str(common/'packed-refs'), str(common/'packed-refs.lock')}
    state_files = {'HEAD', 'HEAD.lock', 'ORIG_HEAD', 'ORIG_HEAD.lock', 'index', 'index.lock', 'COMMIT_EDITMSG',
                   'MERGE_HEAD', 'MERGE_HEAD.lock', 'MERGE_MSG', 'MERGE_MSG.lock', 'MERGE_MODE', 'MERGE_RR', 'MERGE_AUTOSTASH',
                   'AUTO_MERGE', 'AUTO_MERGE.lock',
                   'CHERRY_PICK_HEAD', 'CHERRY_PICK_HEAD.lock', 'REVERT_HEAD', 'REVERT_HEAD.lock', 'SQUASH_MSG',
                   'FETCH_HEAD', 'FETCH_HEAD.lock'}
    state_dirs = {'logs'}
    def safe_gitdir(rs):
        assert {str(gitdir/p) for p in ('HEAD','index.lock','MERGE_MSG.lock')}<=rs,rs
        for root in rs:
            path=Path(root)
            if path.is_relative_to(gitdir):
                assert str(path.relative_to(gitdir)) in state_files|state_dirs,root
    sys.path.insert(0, str(bins))
    import engines
    from unittest.mock import patch
    expected = set(engines.worktree_git_roots(wt))
    # A namespace grant would include a neighbour even when no explicit neighbour root appears.
    def granted(path, rs):
        return any(path == Path(root) or Path(root) in path.parents for root in rs)
    verify('N1 nested refs grant leaf files without sibling branches or reflogs', lambda: require(
        branch_roots <= expected and
        not any(granted(common/p, expected) for p in
                ('refs/heads/nested/neighbour', 'logs/refs/heads/nested/neighbour')), expected))
    with patch.dict(os.environ, {'GIT_DIR': str(common), 'GIT_COMMON_DIR': str(common),
                                 'GIT_WORK_TREE': str(repo), 'GIT_NAMESPACE': 'foreign'}):
        verify('L3 Git discovery ignores inherited repository selectors', lambda: require(
            set(engines.worktree_git_roots(wt)) == expected, 'inherited Git environment changed roots'))
    # Git prunes empty nested ref directories; the recalculated policy must never widen.
    git('pack-refs', '--all', '--prune', cwd=repo)
    assert not (common/'refs/heads/nested').exists()
    verify('N1 packed nested refs stay leaf-only with missing parent', lambda: require(
        set(engines.worktree_git_roots(wt)) == expected and branch_roots <= expected and
        not granted(common/'refs/heads/nested/neighbour', expected), 'packed refs widened roots'))
    # Restore the loose leaf for the spawn/resume controls below.
    git('update-ref', 'refs/heads/nested/task', git('rev-parse', 'HEAD', cwd=wt), cwd=repo)
    brief = home/'brief.md'
    brief.write_text('Read the repository and report findings.\n')
    policy = json.dumps({'type': 'workspace-write', 'network_access': False,
                         'writable_roots': [str(base/'extra')]})
    executor = spawn('executor', wt, '--sandbox-policy', policy)
    verify('variant A warns about unsupported rebase',lambda: require(
        executor.stderr.count('rebase is unsupported') == 1 and 'may move HEAD' in executor.stderr,executor.stderr))
    assert 'rebase is unsupported' in (wt/'codex-prompts.log').read_text()
    git('symbolic-ref', 'HEAD', 'refs/heads/other-branch', cwd=wt)
    run(bins/'agent', 'send', 'executor', 'continue with the same sandbox')
    wait('executor')
    rows = [json.loads(l) for l in (wt/'codex-argv.jsonl').read_text().splitlines()]
    assert len(rows) == 2 and rows[1][:2] == ['exec', 'resume'], rows
    for index,row in enumerate(rows):
        rs=set(roots(row))
        verify(f'H1 launch {index} has only safe worktree metadata roots',lambda: safe_gitdir(rs))
        verify(f'M2 launch {index} has only its original branch refs',
               lambda: require(branch_roots<=rs and not forbidden&rs and
                               str(common/'refs/heads/other-branch') not in rs,rs))
        assert required|{str(base/'extra')}<=rs,rs
        assert 'sandbox_workspace_write.network_access=false' in row,row
    assert roots(rows[0])==roots(rows[1]),rows
    print('PASS explicit policy and original Git roots persist despite a changed HEAD on resume')
    for role, cwd in [('plain', repo), ('outside', home)]:
        spawn(role, cwd, '--sandbox', 'workspace-write')
        row = json.loads((cwd/'codex-argv.jsonl').read_text().splitlines()[-1])
        assert roots(row) == [str(home)], roots(row)
    print('PASS ordinary checkout and non-repository cwd do not gain Git roots')
    # Exercise the alternative backend where Git supports it (older CI Git may not).
    rt, rwt = base/'reftable-main', base/'reftable-worktree'
    init = subprocess.run(['git', 'init', '--ref-format=reftable', str(rt)], capture_output=True, text=True)
    if init.returncode == 0:
        git('config', 'user.name', 'Sandbox Test', cwd=rt)
        git('config', 'user.email', 'sandbox@example.invalid', cwd=rt)
        git('commit', '--allow-empty', '-m', 'initial', cwd=rt)
        git('worktree', 'add', '-b', 'rt-task', rwt, cwd=rt)
        nested = rwt/'nested'
        nested.mkdir()
        spawn('reftable', nested, '--sandbox', 'workspace-write')
        row = json.loads((nested/'codex-argv.jsonl').read_text().splitlines()[-1])
        rs=set(roots(row))
        rg=Path(git('rev-parse', '--absolute-git-dir', cwd=rwt))
        verify('H1 reftable worktree metadata is also restricted',lambda: require(
            str(rg) not in rs and str(rg/'commondir') not in rs and str(rg/'HEAD') in rs,rs))
        assert {str(home),str(rt/'.git/objects'),str(rt/'.git/reftable')}<=rs,rs
        print('PASS reftable worktree from nested cwd uses only its own metadata, objects and ref store')
    else:
        print('SKIP reftable backend is unavailable in this Git')
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
        reviewer_work=home/'stage-a/coordinator/work'
        reviewer_work.mkdir(parents=True,exist_ok=True)
        r = spawn(role, reviewer_work if role=='review-writable' else home, *args)
        assert ('cannot write its report or journal' in r.stderr) == (role == 'tagged'), r.stderr
    print('PASS review tags and effective permission mode warn; unrelated roles/writable review stay quiet')
    verify('variant A documents unsupported rebase',lambda: require(
        all(t in (bins.parent/'docs/codex.md').read_text() for t in ('rebase is unsupported','--apply','move HEAD')), 'missing rebase policy/backend boundary'))
    verify('L1 alternates trust boundary is documented',lambda: require(
        'objects/info/alternates' in (bins.parent/'docs/codex.md').read_text(), 'missing alternates boundary'))
    assert not failures,failures
PY
check $? 0 'workspace-write worktree and read-only reviewer controls'
exit $fail
