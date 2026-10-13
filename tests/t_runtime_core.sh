#!/usr/bin/env bash
# Caller refs and bounded metadata reads: temp repositories/logs, no model calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time
import tracemalloc

root, tmp = map(Path, sys.argv[1:])
for key in list(os.environ):
    if key.startswith(('AGENT_', 'HUB_', 'CODEX_', 'CLAUDE_')):
        os.environ.pop(key)
os.environ.update(AGENT_HUB_HOME=str(tmp/'hub'), CODEX_HOME=str(tmp/'codex'), AGENT_HUB_TZ='UTC')
sys.path.insert(0, str(root/'bin'))
import autopilot as ap
import codex_rollouts as cr
import subagents
agent = runpy.run_path(os.environ.get('CORE_AGENT_SOURCE', str(root/'bin/agent')))
hub = runpy.run_path(str(root/'bin/hub'))

def spawn_refusal(cwd, branch):
    brief = tmp/'refusal-brief.md'; brief.write_text('Refusal fixture; no model call.\n')
    env = dict(os.environ, CODEX_BIN=sys.executable, AGENT_HUB_NO_PROJECT='1', AGENT_HUB_NO_NAMING='1')
    return subprocess.run([sys.executable, os.environ.get('CORE_AGENT_SOURCE', str(root/'bin/agent')),
        'spawn', '--stage', 'stage-a', '--role', branch, '--cwd', str(cwd), '--model', 'gpt-6.1-sol',
        '--engine', 'codex', '--effort', 'low', '--sandbox', 'read-only', '--brief', str(brief),
        '--worktree', branch, '--base', 'HEAD'], env=env, capture_output=True, text=True)

repo = tmp/'repo'; repo.mkdir()
def git(cwd, *args):
    return subprocess.run(['git', '-C', str(cwd), '-c', 'user.email=test@test', '-c', 'user.name=Test',
                           '-c', 'commit.gpgsign=false', *args], check=True, capture_output=True, text=True).stdout.strip()
# Truly empty repository: preserve the original diagnostic and refuse before
# creating worktree, managed-agent directory, exclude/config or branch changes.
empty = tmp/'empty'; empty.mkdir(); git(empty, 'init', '-q', '-b', 'main')
empty_config = (empty/'.git/config').read_bytes()
empty_exclude = (empty/'.git/info/exclude').read_bytes()
try:
    agent['make_worktree'](empty, 'empty-refused', 'empty-refused', 'HEAD')
except ap.hc.Failure as e:
    assert f'the repository {empty} has no commits yet — make a first commit' in str(e), str(e)
    assert 'commits exist on other refs' not in str(e), str(e)
else:
    raise AssertionError('empty repository accepted a new worktree')
r = spawn_refusal(empty, 'empty-spawn-refused')
assert r.returncode == 1 and 'the repository' in r.stderr and 'has no commits yet — make a first commit' in r.stderr, r.stderr
assert not (empty/'.worktrees').exists()
assert not (tmp/'hub/stage-a/agents/empty-spawn-refused').exists()
assert (empty/'.git/config').read_bytes() == empty_config and (empty/'.git/info/exclude').read_bytes() == empty_exclude
assert not git(empty, 'for-each-ref', '--format=%(refname)')
print('PASS truly empty repository diagnostic and early make_worktree/spawn refusal without worktree/agent/exclude/config side effects')
git(repo, 'init', '-q', '-b', 'main')
git(repo, 'commit', '--allow-empty', '-qm', 'main')
main_sha = git(repo, 'rev-parse', 'HEAD')
caller = tmp/'caller'; git(repo, 'worktree', 'add', '-q', '-b', 'hub-branch', str(caller))
git(caller, 'commit', '--allow-empty', '-qm', 'caller')
caller_sha = git(caller, 'rev-parse', 'HEAD')
assert caller_sha != main_sha
failures = []
real_agent_git = agent['make_worktree'].__globals__['git']
worktree_calls = []
def tracked_git(*args, **kwargs):
    if args[:2] == ('worktree', 'add'):
        worktree_calls.append(args)
    return real_agent_git(*args, **kwargs)
agent['make_worktree'].__globals__['git'] = tracked_git
for name, cwd, ref, expected in [('caller-head', caller, 'HEAD', caller_sha),
                                  ('main-head', repo, 'HEAD', main_sha),
                                  ('explicit-branch', caller, 'main', main_sha),
                                  ('explicit-sha', repo, caller_sha, caller_sha)]:
    path, branch, note = agent['make_worktree'](cwd, name, name, ref)
    assert git(path, 'rev-parse', 'HEAD') == expected, (name, note)
    assert path.parent == repo.resolve()/'.worktrees', path
    expected_note = f'created from {ref} {expected[:7]}'
    if note != expected_note:
        failures.append(f'{name}: note {note!r} != {expected_note!r}')
    if worktree_calls[-1][-1] != expected:
        failures.append(f'{name}: worktree add ref {worktree_calls[-1][-1]!r} != resolved SHA {expected!r}')
    assert git(repo, 'rev-parse', 'HEAD') == main_sha
    assert git(caller, 'rev-parse', 'HEAD') == caller_sha
print('PASS actual --base HEAD checkout already works; checking resolved note/SHA controls separately')
# HEAD is unborn only in the caller: the main checkout still has a commit.
git(caller, 'symbolic-ref', 'HEAD', 'refs/heads/unborn-caller')
before_worktrees = git(repo, 'worktree', 'list', '--porcelain')
before_calls = len(worktree_calls)
before_config = (repo/'.git/config').read_bytes()
before_exclude = (repo/'.git/info/exclude').read_bytes()
before_refs = git(repo, 'for-each-ref', '--format=%(refname) %(objectname)')
try:
    agent['make_worktree'](caller, 'unborn-rejected', 'unborn-rejected', 'HEAD')
except ap.hc.Failure as e:
    if str(caller) not in str(e) or 'HEAD' not in str(e) or 'has no commits yet' not in str(e) or 'unborn; commits exist on other refs' not in str(e):
        failures.append(f'unborn caller: wrong error {str(e)!r}')
else:
    failures.append('unborn caller: worktree unexpectedly created')
if len(worktree_calls) != before_calls:
    failures.append('unborn caller: reached git worktree add instead of early validation')
r = spawn_refusal(caller, 'unborn-spawn-refused')
if r.returncode != 1 or f'HEAD in {caller.resolve()} has no commits yet' not in r.stderr or 'commits exist on other refs' not in r.stderr:
    failures.append(f'unborn spawn: wrong exit/reason {r.returncode}, {r.stderr!r}')
assert not (tmp/'hub/stage-a/agents/unborn-spawn-refused').exists()
assert not (repo/'.worktrees/unborn-rejected').exists() and not (repo/'.worktrees/unborn-spawn-refused').exists()
assert (repo/'.git/config').read_bytes() == before_config and (repo/'.git/info/exclude').read_bytes() == before_exclude
assert git(repo, 'for-each-ref', '--format=%(refname) %(objectname)') == before_refs
assert git(repo, 'worktree', 'list', '--porcelain') == before_worktrees
assert git(caller, 'symbolic-ref', 'HEAD') == 'refs/heads/unborn-caller'
assert git(repo, 'rev-parse', 'HEAD') == main_sha
# Existing branches and explicit commit refs still work from an unborn caller.
path, _, note = agent['make_worktree'](caller, 'existing', 'hub-branch', 'HEAD')
assert git(path, 'rev-parse', 'HEAD') == caller_sha and note == 'created'
path, _, note = agent['make_worktree'](caller, 'unborn-sha', 'unborn-sha', main_sha)
assert git(path, 'rev-parse', 'HEAD') == main_sha
for failure in failures:
    print('FAIL before/after worktree control:', failure)
assert not failures, failures
print('PASS resolved metadata/ref, caller unborn-HEAD early failure, checkout/common-root preservation and existing-branch/SHA controls')

sid = '11111111-1111-4111-8111-111111111111'
os.environ['CODEX_THREAD_ID'] = sid
sessions = tmp/'codex/sessions'; sessions.mkdir(parents=True)
path = sessions/f'rollout-{sid}.jsonl'
settings = {'model': 'gpt-6.1-sol', 'effort': 'high', 'approval_policy': 'on-request',
            'sandbox_policy': {'type': 'workspace-write', 'writable_roots': [str(repo)], 'network_access': False}}
def event(kind, payload):
    return {'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(), 'type': kind, 'payload': payload}
def emit(f, kind, payload):
    f.write(json.dumps(event(kind, payload)).encode()+b'\n')
with path.open('wb') as f:
    emit(f, 'session_meta', {'id': sid, 'source': 'cli'})
    emit(f, 'turn_context', settings)
    # One giant tool result, then many ordinary records, both exceeding the old tail cap.
    emit(f, 'response_item', {'type': 'function_call_output', 'output': 'x'*(5<<20)})
    for _ in range(800):
        emit(f, 'response_item', {'type': 'function_call_output', 'output': 'y'*6000})
assert path.stat().st_size > 9<<20
tracemalloc.start()
assert cr.latest_turn_context(path) == settings
peak = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
assert peak < 2<<20, peak
context = ap.codex_context()
assert context == dict(settings, _rollout_found=True), context
new = dict(settings, model='gpt-6-sol', effort='medium', approval_policy='never')
with path.open('ab') as f:
    emit(f, 'turn_context', new)
    f.write(b'{"type":"turn_context","payload":')
assert cr.latest_turn_context(path) == new, 'latest complete context wins; torn context ignored'
assert ap.codex_context()['model'] == new['model']
os.environ['AGENT_HUB_CODEX_DEFAULT_MODEL'] = 'gpt-6.1-sol'
assert ap.codex_model(None, {}, repo) is None, 'spawn default is not evidence of the current session model'
assert ap.codex_model(None, new, repo) == new['model']
assert ap.codex_model('gpt-6.1-sol', new, repo) == 'gpt-6.1-sol', 'explicit successor model wins'
os.environ.pop('AGENT_HUB_CODEX_DEFAULT_MODEL')
oversized = tmp/'oversized-context.jsonl'
with oversized.open('wb') as f:
    emit(f, 'turn_context', settings)
    emit(f, 'turn_context', dict(new, developer_instructions='x'*(1<<20)))
assert cr.latest_turn_context(oversized) == {}, 'oversized latest context must not inherit stale metadata'
with oversized.open('ab') as f:
    f.write(b'{"type":"turn_context","payload":broken}\n')
assert cr.latest_turn_context(oversized) == {}, 'malformed current metadata must not inherit stale settings'
try:
    ap.codex_policy(None, {}, repo)
except ap.hc.UsageError as e:
    assert 'unknown' in str(e)
else:
    raise AssertionError('unknown sandbox guessed a default')
print('PASS >9 MiB metadata inheritance, latest/torn contexts, bounded allocation and unknown policy refusal')

# Fresh unknown native sessions remain visible and block handoff until evidence or TTL expiry.
child = '22222222-2222-4222-8222-222222222222'
childpath = sessions/f'rollout-{child}.jsonl'
with childpath.open('wb') as f:
    emit(f, 'session_meta', {'id': child, 'source': {'subagent': {'thread_spawn': {'parent_thread_id': sid}}}})
    emit(f, 'event_msg', {'type': 'task_started', 'turn_id': 'one', 'started_at': int(time.time())})
os.utime(childpath, (time.time()-7200, time.time()-7200))
cr.INDEX.checked = None
finder = subagents.Finder()
assert finder.codex_session(child, None, time.time()).state == 'unknown'
assert finder.codex_session(child, True, time.time()).state == 'live'
assert finder.codex_session(child, False, time.time(), True).state == 'dead'
os.environ.pop('CODEX_THREAD_ID')
unresolved = hub['live_subagents'](sid, {'engine': 'codex'})
assert any(s.aid == child and s.state == 'unknown' for s in unresolved), unresolved
os.environ['CODEX_THREAD_ID'] = sid
assert subagents.parent_alive({'engine': 'codex'}, sid, {}, {}) is True
with childpath.open('ab') as f:
    emit(f, 'event_msg', {'type': 'turn_aborted', 'turn_id': 'one', 'reason': 'user interrupted'})
assert finder.codex_session(child, None, time.time(), True).state == 'stopped'
with childpath.open('ab') as f:
    emit(f, 'event_msg', {'type': 'task_started', 'turn_id': 'two', 'started_at': int(time.time())})
    emit(f, 'event_msg', {'type': 'task_complete', 'turn_id': 'one'})
assert finder.codex_session(child, None, time.time(), True).state == 'unknown'
with childpath.open('ab') as f:
    emit(f, 'event_msg', {'type': 'task_failed', 'turn_id': 'two', 'message': 'failed fixture'})
assert finder.codex_session(child, None, time.time(), True).state == 'error'
print('PASS quiet current/unknown lifecycle, unknown handoff gate, interrupted vs failed, resume and stale completion')
PY
