#!/usr/bin/env bash
# Sanitized native record shapes and the serialization skew reproduced in the
# Windows audit: envelope 19:43:11.108, birth 19:43:10.836, start 19:43:10.
# Identifiers, messages and times below are synthetic; no user rollout is copied.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_HOME="$AGENT_HUB_HOME/codex" PYTHONDONTWRITEBYTECODE=1
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time

binpath, root = map(Path, sys.argv[1:])
sys.path.insert(0, str(binpath))
import codex_rollouts as cr
import subagents
if os.environ.get('CORE_SUBAGENTS_SOURCE'):
    spec = importlib.util.spec_from_file_location('subagents', os.environ['CORE_SUBAGENTS_SOURCE'])
    subagents = importlib.util.module_from_spec(spec)
    sys.modules['subagents'] = subagents
    spec.loader.exec_module(subagents)
import topcache
loader = importlib.machinery.SourceFileLoader('agent_top', str(binpath/'agent-top'))
spec = importlib.util.spec_from_loader(loader.name, loader)
top = importlib.util.module_from_spec(spec)
loader.exec_module(top)
now = time.time()
base = int(now)-30
parent = '11111111-1111-4111-8111-111111111111'
child = '22222222-2222-4222-8222-222222222222'
def stamp(at):
    return dt.datetime.fromtimestamp(at, dt.timezone.utc).isoformat(timespec='milliseconds')
def event(kind, payload, at):
    return dict(type=kind, payload=payload, timestamp=stamp(at) if isinstance(at, (int, float)) else at)
def meta(birth=base+.836):
    return event('session_meta', dict(id=child, timestamp=stamp(birth), source={
        'subagent': {'thread_spawn': {'parent_thread_id': parent, 'agent_path': '/root/check'}}}), base+1.108)
def start(turn='own', at=base):
    return event('event_msg', dict(type='task_started', turn_id=turn, started_at=at), base+2)
def terminal(turn='own', kind='task_complete', at=base+15):
    return event('event_msg', dict(type=kind, turn_id=turn, last_agent_message='fixture complete'), at)
context = event('turn_context', dict(model='fixture-model', effort='high'), base+3)
own = [meta(), start(), context, terminal()]
norm = cr.Normalizer()
normalized = [n for e in own for n in norm.events(e)]
assert norm.birth == base+.836 and normalized[-1]['type'] == 'result'
assert any(n.get('model') == 'fixture-model' for n in normalized)
assert norm.last_event_ts == base+15
# Ordinary native and legacy headers still work. Missing/invalid birth fails
# closed for fork ownership, including invalid payload with a valid envelope.
for header in (meta(base-1),):
    n = cr.Normalizer()
    assert [v for e in [header, start(), terminal()] for v in n.events(e)][-1]['type'] == 'result'
legacy = meta(); legacy['payload'].pop('timestamp'); legacy['timestamp'] = stamp(base+.836)
n = cr.Normalizer()
assert [v for e in [legacy, start(), terminal()] for v in n.events(e)][-1]['type'] == 'result'
for invalid in (None, 'invalid', 42):
    header = meta(); header['payload']['timestamp'] = invalid
    n = cr.Normalizer(); n.events(header)
    assert n.birth is None and not n.events(start()) and not n.events(terminal())
header = meta(); header['payload'].pop('timestamp'); header.pop('timestamp')
n = cr.Normalizer(); n.events(header)
assert not n.events(start()) and not n.events(terminal()) and n.last_event_ts is None
n = cr.Normalizer(); n.events(meta())
for invalid in (True, 'bad', None, float('nan'), float('inf')):
    assert not n.events(start(at=invalid))
inherited = [event('session_meta', dict(id=parent, source='cli'), now+1000),
             start('parent', base-200), context, terminal('parent', at=now+1000)]
n = cr.Normalizer(); n.events(meta())
assert all(not n.events(e) for e in inherited)
assert n.last_event_ts == base+.836, 'parent history cannot advance child recency'

sessions = root/'codex'/'sessions'; sessions.mkdir(parents=True)
path = sessions/f'rollout-{child}.jsonl'
def write(events):
    path.write_text(''.join(json.dumps(e)+'\n' for e in events))
def append(events):
    with path.open('a') as f:
        f.write(''.join(json.dumps(e)+'\n' for e in events))
    os.utime(path, (fixed_mtime, fixed_mtime))
write([meta()]+inherited+[start(), context])
os.utime(path, (now-7200, now-7200))
# Use the filesystem's representable value: mounted filesystems may round the
# requested timestamp. Subsequent growth must preserve that exact stored clock.
fixed_mtime = path.stat().st_mtime
coll = top.Collector(['stage-a'], show_all=True)
finder = coll.subs
quiet = finder.codex_session(child, None, now)
assert quiet.state == 'unknown' and quiet.unresolved and not quiet.alive
hub = runpy.run_path(str(binpath/'hub'))
assert any(s.aid == child and s.unresolved for s in hub['live_subagents'](parent, {'engine': 'codex'}))
assert finder.codex_session(child, True, now).state == 'live'
assert finder.codex_session(child, False, now, True).state == 'dead'
# An incomplete child's actual birth/activity, not a touched file mtime, bounds
# unknown discovery and handoff. Show-all exposes expiry without fabricating death.
later = now + 3601
assert finder.codex_session(child, None, later) is None, "unknown child must expire from default discovery after one hour"
expired = finder.codex_session(child, None, later, True)
assert expired.state == 'unknown' and expired.expired and not expired.unresolved and not expired.alive
assert expired.last_event_ts == base+3 and expired.status is None
assert finder.codex_session(child, None, later) is None
assert finder.codex_session(child, True, later).alive, 'known-live never expires'
os.utime(path, (later, later)); cr.INDEX.checked = None
assert subagents.Finder().codex_session(child, None, later) is None, 'touching the file cannot refresh owned activity'
os.utime(path, (fixed_mtime, fixed_mtime)); cr.INDEX.checked = None
row = coll._subagent('stage-a', 'hub', {}, expired, later)
assert row['expired'] and not row['handoff_blocking'] and row['state'] == 'unknown' and row['result'] is None
# Render the actual expired observation through both public snapshot views.
# The expiry message must survive an empty or a previously emitted last text;
# neither case may invent a terminal result or turn the unknown badge into died.
expiry_text = 'unknown observation expired; no death/completion evidence; not blocking handoff'
for last_text in ('', 'earlier unfinished work'):
    displayed = dict(row, last_text=last_text)
    rendered = dict(now=later, stages=['stage-a'], agents=[displayed],
                    counts=dict(live=0, done=0, error=0, dead=0, unknown=1), locks=[], questions={})
    lines, _ = top.list_rows(rendered, 240, None)
    listed = '\n'.join(line.text() for line in lines)
    widget = top.render_widget(rendered)
    assert expiry_text in listed and expiry_text in widget
    assert 'unknown' in listed and '>unknown<' in widget and '>died<' not in widget
    assert displayed['state'] == 'unknown' and displayed['result'] is None
# A confirmed live child at the same age keeps its activity and blocking status,
# including its render: the expired-unknown explanation must not leak into it.
live = coll._subagent('stage-a', 'hub', {}, finder.codex_session(child, True, later), later)
assert live['alive'] and live['handoff_blocking'] and not live['expired']
assert top.what_now(live)[0] != expiry_text
# Exercise actual handoff Finder and actual process-table registry evidence.
real_clock = hub['live_subagents'].__globals__['time'].time
hub['live_subagents'].__globals__['time'].time = lambda: later
try:
    assert not hub['live_subagents'](parent, {'engine': 'codex'})
    blocked = hub['live_subagents'](parent, {'engine': 'codex'}, 'block')
    assert len(blocked) == 1 and blocked[0].aid == child and blocked[0].expired
    assert blocked[0].state == 'unknown' and not blocked[0].unresolved
    assert finder.codex_session(child, None, later) is None, 'policy must not change discovery TTL'
    registry = dict(engine='codex', kind='headless', pid=os.getpid(), process_token='revision-core-live')
    actual_table = subagents.process_table()
    assert actual_table and os.getpid() in actual_table
    registry['process_token'] = actual_table[os.getpid()]
    assert subagents.parent_alive(registry, parent, actual_table, {}) is True
    for policy in ('expire', 'block'):
        live_children = hub['live_subagents'](parent, registry, policy)
        assert len(live_children) == 1 and live_children[0].aid == child and live_children[0].alive
    dead_registry = dict(registry, pid=99999999)
    assert not hub['live_subagents'](parent, dead_registry, 'block'), 'proven dead cannot block'
finally:
    hub['live_subagents'].__globals__['time'].time = real_clock
# Brand-new owned activity reopens the same unknown observation after expiration.
append([event('event_msg', dict(type='agent_message', message='resumed fixture'), later)])
assert finder.codex_session(child, None, later).unresolved
write([meta()]+inherited+[start(), context])
# Finder resets on a rewritten file; use a fresh reader after fixture replacement.
coll = top.Collector(['stage-a'], show_all=True)
finder = coll.subs
print('PASS one-hour incomplete-child expiry, unknown show-all evidence, actual registry known-live/handoff controls and renewed activity')
# Same Finder/Collector as a polling monitor; keep discovery's TTL and mtime
# fixed while bytes and complete records advance.
ls = coll.log_state(path)
assert ls.last_result is None and ls.last_event_ts == base+3
with path.open('a') as f:
    f.write('{"type":"event_msg","payload":broken}\n')
    f.write('[]\n')
    f.write(json.dumps(terminal()))
os.utime(path, (fixed_mtime, fixed_mtime))
assert finder.codex_session(child, None, now).state == 'unknown'
assert coll.log_state(path).last_event_ts == base+3
with path.open('a') as f:
    f.write('\n')
os.utime(path, (fixed_mtime, fixed_mtime))
done = finder.codex_session(child, None, now)
assert done and done.state == 'done' and done.mtime == fixed_mtime
for policy in ('expire', 'block'):
    assert not hub['live_subagents'](parent, {'engine': 'codex'}, policy), 'terminal child cannot block'
assert done.last_event_ts == base+15 and done.age(now) == now-(base+15)
row = coll._subagent('stage-a', 'hub', {}, done, now)
assert row['last_event_at'] == stamp(base+15).split('.')[0]+'+00:00'
assert row['age_s'] == int(now-(base+15)) and not row['alive']
assert row['model_id'] == 'fixture-model' and row['result']['text'] == 'fixture complete'
# Complete owned records that have no display representation still count as
# activity; malformed and torn JSON above do not.
append([event('event_msg', dict(type='agent_message', message='fixture'), base+17)])
assert finder.codex_session(child, None, now).last_event_ts == base+17
assert coll.log_state(path).last_event_ts == base+17
# Fresh processes restore both nested normalizers and activity times, then
# continue through a resume and reject a late terminal event from the old turn.
coll.store.flush()
store = top.open_store()
cached = subagents.Finder(store=store).codex_session(child, None, now)
assert cached.state == 'done' and cached.last_event_ts == base+17
assert store.get('rollout-state', str(path))['offset'] == path.stat().st_size
restored = top.LogState(path)
assert topcache.load_into(restored, store.get('log', str(path)), {'rollout': cr.Normalizer})
assert restored.last_event_ts == base+17
append([start('resume', base+20), terminal(at=now+1000)])
resumed = finder.codex_session(child, None, now)
assert resumed.state == 'unknown' and resumed.unresolved
assert resumed.last_event_ts == base+17, 'late terminal timestamp ignored'
append([terminal('resume', 'turn_aborted', base+25)])
assert finder.codex_session(child, None, now).state == 'stopped'
future_event = start('future', int(now)+1000)
future_event['timestamp'] = stamp(int(now)+1000)
append([future_event])
future = finder.codex_session(child, None, now)
assert future.state == 'unknown' and not future.alive
assert future.last_event_ts > now and future.age(now) == 0
assert finder.codex_session(child, False, now, True).state == 'dead'

# An incomplete child with no valid native birth/event time also has a bounded
# observation lifetime. Filesystem freshness supplies TTL only, never display age.
header = meta(); header['payload']['timestamp'] = 'invalid'
write([header]); os.utime(path, (fixed_mtime, fixed_mtime)); cr.INDEX.checked = None
missing_clock = subagents.Finder()
assert missing_clock.codex_session(child, None, now) is None
expired = missing_clock.codex_session(child, None, now, True)
assert expired.state == 'unknown' and expired.expired and expired.status is None
assert expired.last_event_ts is None and expired.age(now) is None
assert missing_clock.codex_session(child, True, now).alive
print('PASS missing native timestamp expiry uses filesystem TTL without inventing an activity clock or death')

# Native timestamps absent or invalid stay unknown; mtime never substitutes.
unknown = [{'type': e['type'], 'payload': e['payload']} for e in own]
unknown[0]['payload']['source'] = 'cli'
unknown[0]['payload'].pop('timestamp')
for e in unknown[1:]:
    e['timestamp'] = 'invalid'
write(unknown)
cr.INDEX.checked = None
u = subagents.Finder().codex_session(child, None, now, True)
assert u.state == 'done' and u.last_event_ts is None and u.age(now) is None
assert coll._subagent('stage-a', 'hub', {}, u, now)['last_event_at'] is None

# Raw exec lacks native event timestamps; preserve its aligned mtime and
# process/result semantics, plus Claude's existing activity clock.
worker = root/'stage-a'/'agents'/'exec'; worker.mkdir(parents=True)
worker.joinpath('meta.json').write_text(json.dumps(dict(engine='codex', pid=99999999, role='exec')))
worker.joinpath('log.jsonl').write_text(json.dumps(dict(type='thread.started', thread_id=parent))+'\n'+
                                     json.dumps(dict(type='turn.completed', usage={}))+'\n')
os.utime(worker/'log.jsonl', (base+15, base+15))
row = coll._agent('stage-a', worker/'meta.json', {}, {}, now)
assert row['age_s'] == int(now-(base+15)) and row['state'] == 'done'
assert row['last_event_at'] is not None
claude = subagents.Sub('fixture', path, {}, base+15, None, 'live', True)
assert claude.age(now) == now-(base+15)
print('PASS payload birth, fail-safe ownership, inherited/late terminal filtering, fixed-mtime growth, cache/polling, unknown/stopped and exec/Claude clocks')
PY

# Public handoff commands use isolated registered repositories and synthetic
# native children; no worker, model, or session is launched.
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys

binpath, root = map(Path, sys.argv[1:])
key = 'AGENT_HUB_HANDOFF_UNKNOWN_POLICY'
parent = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
stage = root/'policy-stage'; stage.mkdir()
repo = root/'project'; repo.mkdir()
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '--allow-empty', '-qm', 'fixture'], check=True)
project_config = repo/'.agent-hub'; project_config.mkdir()
worktree = root/'registered-worktree'
subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-qb', 'fixture', str(worktree)], check=True,
               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
wt_config = worktree/'.agent-hub'; wt_config.mkdir()
drift = root/'drift'; drift.mkdir()
subprocess.run(['git', 'init', '-q', str(drift)], check=True)
(drift/'.agent-hub').mkdir()
(drift/'.agent-hub'/'config.json').write_text(json.dumps({key: 'expire'}))
def config(path, value):
    path.write_text(json.dumps({} if value is None else {key: value}))
def register(repo_path=repo, tree_path=worktree, no_project=False, path_key="cwd"):
    (stage/'stage.json').write_text(json.dumps({'no_project': True} if no_project else {'repo': str(repo_path)}))
    (stage/'roles.json').write_text(json.dumps({'roles': {'hub': {
        'cli_session_id': parent, 'session': parent, 'tag': 'hub-1', 'title': 'Hub policy-stage #1',
        'kind': 'cli', 'host': 'codex-app', 'engine': 'codex', path_key: str(tree_path)}}}))
register()
sessions = root/'codex'/'sessions'
old = (dt.datetime.now(dt.timezone.utc)-dt.timedelta(hours=2)).isoformat()
children = []
for n in range(15):
    sid = f'bbbbbbbb-bbbb-4bbb-8bbb-{n:012d}'; children.append(sid)
    events = [dict(type='session_meta', timestamp=old, payload=dict(id=sid, timestamp=old, source={
        'subagent': {'thread_spawn': {'parent_thread_id': parent, 'agent_path': '/root/fixture'}}})),
        dict(type='event_msg', timestamp=old, payload=dict(type='task_started', turn_id='fixture', started_at=dt.datetime.fromisoformat(old).timestamp()))]
    (sessions/f'rollout-{sid}.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
claude_root = root/'claude'
claude_dir = claude_root/'projects'/'fixture'/parent/'subagents'; claude_dir.mkdir(parents=True)
(claude_dir/'agent-old.meta.json').write_text('{}')
(claude_dir/'agent-old.jsonl').write_text('{}\n')
old_time = dt.datetime.fromisoformat(old).timestamp()
os.utime(claude_dir/'agent-old.jsonl', (old_time, old_time))
# Deterministic process evidence, without inspecting real worker/session state.
fakebin = root/'fakebin'; fakebin.mkdir()
(fakebin/'ps').write_text('#!/bin/sh\nprintf "1 fixture-init\\n"\n')
(fakebin/'ps').chmod(0o755)
env = dict(os.environ, CLAUDE_CONFIG_DIR=str(claude_root), PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
for name in (key, 'CODEX_THREAD_ID', 'CLAUDE_CODE_SESSION_ID', 'AGENT_SESSION_ID'):
    env.pop(name, None)
config(project_config/'config.json', None)
config(wt_config/'config.json', None)
config(root/'config.json', None)
counter = 0
def handoff(label, expected, override=False, extra_env=None, cwd=drift):
    global counter
    counter += 1
    out = root/f'draft-{counter}.md'
    args = [str(binpath/'hub'), 'handoff', '--stage', 'policy-stage', '--session', parent, '--out', str(out)]
    if override:
        args.append('--allow-live-subagents')
    result = subprocess.run(args, cwd=cwd, env=dict(env, **(extra_env or {})), text=True, capture_output=True)
    print(f'{label}: exit={result.returncode} expected={expected}')
    print(result.stdout, end=''); print(result.stderr, end='')
    assert result.returncode == expected, label
    assert out.exists() == (expected == 0), label + ': draft creation'
    return out.read_text() if out.exists() else result.stderr
handoff('default expire preserves TTL', 0)
config(root/'config.json', 'block')
handoff('home block', 2)
config(wt_config/'config.json', 'expire')
handoff('registered worktree overrides home', 0)
config(project_config/'config.json', 'expire')
config(wt_config/'config.json', 'block')
assert 'worktree' not in json.loads((stage/'roles.json').read_text())['roles']['hub']
text = handoff('native cwd-only worktree block survives other-repository cwd drift', 2)
assert all(sid in text for sid in children) and 'old  ' not in text
register(path_key='worktree')
handoff('legacy worktree-only record retains custom worktree block', 2)
register()
# cwd wins if a compatible legacy field is also present.
roles = json.loads((stage/'roles.json').read_text())
roles['roles']['hub']['worktree'] = str(repo)
(stage/'roles.json').write_text(json.dumps(roles))
handoff('native cwd takes precedence over legacy worktree/main-project expire', 2)
register()
handoff('environment expire overrides project block', 0, extra_env={key: 'expire'})
text = handoff('explicit override preserves all child evidence', 0, override=True)
assert all(sid in text for sid in children) and 'unknown;' in text and 'lost:' in text
config(wt_config/'config.json', 'expire')
handoff('environment block overrides project expire', 2, extra_env={key: 'block'})
for invalid in ('typo', '', 'BLOCK', True, [], 1, {'policy': 'block'}):
    config(wt_config/'config.json', invalid)
    text = handoff(f'invalid project value {invalid!r}', 2, override=True)
    assert key+' must be expire or block' in text
(wt_config/'config.json').write_text(json.dumps({key: None}))
text = handoff('null project policy refuses', 2)
assert key+' must be expire or block' in text
config(wt_config/'config.json', 'typo')
handoff('environment expire takes precedence over invalid project setting', 0, extra_env={key: 'expire'})
config(wt_config/'config.json', 'block')
handoff('registered block survives outside-repository cwd drift', 2, cwd=root)
for invalid in ('typo', ''):
    text = handoff(f'invalid environment value {invalid!r}', 2, extra_env={key: invalid})
    assert key+' must be expire or block' in text
# A worktree without its own config inherits the main checkout's config.
(wt_config/'config.json').unlink(); wt_config.rmdir()
handoff('registered main project expire fallback', 0)
config(project_config/'config.json', 'block')
handoff('registered main project block fallback', 2)
register(tree_path=root/'lost-worktree')
text = handoff('lost native registered cwd refuses despite available main project', 2,
               override=True, extra_env={key: 'expire'})
assert 'cannot resolve handoff policy' in text
roles = json.loads((stage/'roles.json').read_text())
roles['roles']['hub']['worktree'] = str(worktree)
(stage/'roles.json').write_text(json.dumps(roles))
text = handoff('lost native cwd cannot fall back to available legacy worktree', 2,
               override=True, extra_env={key: 'expire'})
assert 'cannot resolve handoff policy' in text
register(tree_path=drift)
text = handoff('native cwd in another project refuses', 2)
assert 'cannot resolve handoff policy' in text
register(repo_path=root/'lost-project', tree_path=worktree)
text = handoff('lost registered project refuses despite existing role worktree', 2)
assert 'cannot resolve handoff policy' in text
register(repo_path=root/'lost-project', tree_path=root/'lost-worktree')
text = handoff('lost registered project refuses even with override and env expire', 2,
               override=True, extra_env={key: 'expire'})
assert 'cannot resolve handoff policy' in text
register()
(stage/'stage.json').write_text('[]')
text = handoff('malformed project registration refuses', 2)
assert 'cannot resolve handoff policy' in text
register(no_project=True)
config(drift/'.agent-hub'/'config.json', 'block')
config(root/'config.json', 'typo')
text = handoff('invalid home policy refuses', 2)
assert key+' must be expire or block' in text
config(root/'config.json', 'expire')
handoff('explicit no-project uses home, ignoring drift and stale role project', 0)
register()
# Recent Claude children still block under both policies; old ones stay filtered.
(claude_dir/'agent-recent.meta.json').write_text('{}')
(claude_dir/'agent-recent.jsonl').write_text('{}\n')
for policy in ('expire', 'block'):
    text = handoff('recent Claude blocks under '+policy, 2, extra_env={key: policy})
    assert 'recent' in text and 'old  ' not in text
(claude_dir/'agent-recent.meta.json').unlink()
for sid in children:
    with (sessions/f'rollout-{sid}.jsonl').open('a') as f:
        f.write(json.dumps(dict(type='event_msg', timestamp=old, payload=dict(
            type='task_complete', turn_id='fixture', last_agent_message='done')))+'\n')
handoff('proven terminal children do not block', 0, extra_env={key: 'block'})
print('PASS public handoff policy, precedence, cwd drift, invalid/lost source, override evidence, terminal and Claude controls')
PY
