#!/bin/bash
# Mixed-engine raw logs and native rollouts: totals are not context, forks do
# not inherit completion, process tokens detect PID reuse, monitoring is read-only.
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a PYTHONDONTWRITEBYTECODE=1 CODEX_HOME=$AGENT_HUB_HOME/codex CLAUDE_CONFIG_DIR=$AGENT_HUB_HOME/claude
MON_TOKEN=monitor-token-positive
python3 -c 'import time; time.sleep(600)' "$MON_TOKEN" & MON_PID=$!
trap 'kill "$MON_PID" 2>/dev/null; test_cleanup' EXIT
python3 - "$B" "$AGENT_HUB_HOME" "$MON_PID" "$MON_TOKEN" <<'PY'
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

binpath, root, pid, token = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, str(binpath))
loader = importlib.machinery.SourceFileLoader('agent_top', str(binpath / 'agent-top'))
spec = importlib.util.spec_from_loader(loader.name, loader)
top = importlib.util.module_from_spec(spec)
loader.exec_module(top)
now = time.time()
timestamp = dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat()
parent = '11111111-1111-4111-8111-111111111111'
doneid = 'aaaaaaaa-1111-4111-8111-111111111111'
liveid = 'bbbbbbbb-1111-4111-8111-111111111111'
failid = 'cccccccc-1111-4111-8111-111111111111'
ghostid = 'dddddddd-1111-4111-8111-111111111111'

def write(path, events):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(e) + '\n' for e in events))

def worker(role, events, process_token=None):
    folder = root / 'stage-a' / 'agents' / role
    meta = {'role': role, 'engine': 'codex', 'session_id': '22222222-2222-4222-8222-222222222222',
            'model': 'configured-alias', 'cwd': str(root), 'pid': pid if process_token else 99999999,
            'effort': 'high', 'runs': [{}]}
    if process_token:
        meta['process_token'] = process_token
    write(folder / 'log.jsonl', events)
    folder.joinpath('meta.json').write_text(json.dumps(meta))
    return folder / 'log.jsonl'

cli = [
    {'type': 'thread.started', 'thread_id': '22222222-2222-4222-8222-222222222222'},
    {'type': 'turn.started'},
    {'type': 'item.completed', 'item': {'id': 'item_0', 'type': 'reasoning', 'text': 'Plan the checks'}},
    {'type': 'item.completed', 'item': {'id': 'item_1', 'type': 'agent_message', 'text': 'Running checks'}},
    {'type': 'item.started', 'item': {'id': 'item_2', 'type': 'command_execution', 'command': 'pytest -x', 'status': 'in_progress'}},
]
live_log = worker('coder', cli, token)
finish = {'type': 'turn.completed', 'usage': {'input_tokens': 23000, 'cached_input_tokens': 19000, 'output_tokens': 1200}}
worker('done', cli + [
    {'type': 'item.completed', 'item': {'id': 'item_2', 'type': 'command_execution', 'command': 'pytest -x', 'aggregated_output': 'passed', 'exit_code': 0}},
    {'type': 'item.completed', 'item': {'id': 'item_3', 'type': 'agent_message', 'text': 'DONE: all checks passed'}},
    finish])
worker('failed', cli + [{'type': 'turn.failed', 'error': {'message': 'fixture failure'}}])
worker('reused', cli, 'unrelated-token')
worker('resumed', cli + [finish, {'type': 'thread.started', 'thread_id': parent}, {'type': 'turn.started'}])

native = root / 'codex' / 'sessions' / '2026' / '10' / '02'
def event(kind, payload):
    return {'timestamp': timestamp, 'type': kind, 'payload': payload}

def rollout(sid, end, owner=parent, inherited=False):
    source = 'cli' if sid == parent else {'subagent': {'thread_spawn': {'parent_thread_id': owner, 'agent_path': '/root/check', 'agent_nickname': 'Fixture'}}}
    birth = int(now) - 5
    header = event('session_meta', {'id': sid, 'source': source, 'cwd': str(root),
                                  'timestamp': dt.datetime.fromtimestamp(birth + .836, dt.timezone.utc).isoformat()})
    header['timestamp'] = dt.datetime.fromtimestamp(birth + 1.108, dt.timezone.utc).isoformat()
    events = [header]
    if inherited:
        events += [event('session_meta', {'id': parent, 'source': 'cli'}),
                   event('event_msg', {'type': 'task_started', 'turn_id': 'parent-old', 'started_at': int(now) - 200}),
                   event('event_msg', {'type': 'task_complete', 'last_agent_message': 'INHERITED COMPLETION'})]
    events += [event('event_msg', {'type': 'task_started', 'turn_id': 'own-' + sid, 'started_at': birth}),
               event('turn_context', {'model': 'gpt-6-sol', 'effort': 'high'}),
               event('response_item', {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Check the fixture'}]}),
               event('response_item', {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'OWN MESSAGE'}]}),
               event('response_item', {'type': 'function_call', 'call_id': 'call_1', 'name': 'exec_command', 'arguments': '{"cmd":"pytest"}'}),
               event('response_item', {'type': 'function_call_output', 'call_id': 'call_1', 'output': 'passed'}),
               event('event_msg', {'type': 'token_count', 'info': {
                   'total_token_usage': {'input_tokens': 310000, 'cached_input_tokens': 290000, 'output_tokens': 1200, 'total_tokens': 311200},
                   'last_token_usage': {'input_tokens': 17000, 'cached_input_tokens': 12000, 'output_tokens': 100},
                   'model_context_window': 200000}})]
    if end:
        events += [event('event_msg', {'type': end, 'last_agent_message': 'NATIVE DONE', 'reason': 'interrupted'})]
    path = native / ('rollout-fixture-' + sid + '.jsonl')
    write(path, events)
    os.utime(path, (now - 7200, now - 7200))  # native Windows creation mtime remains fixed
    return path

parentlog = rollout(parent, 'task_complete')
donelog = rollout(doneid, 'task_complete', inherited=True)
livelog = rollout(liveid, None, inherited=True)
faillog = rollout(failid, 'turn_aborted')
rollout(ghostid, 'task_complete', owner='99999999-1111-4111-8111-111111111111')
# An existing empty Claude registry is not evidence that a Codex session died.
(root / 'claude' / 'sessions').mkdir(parents=True)
subprocess.run([str(binpath / 'roles'), 'set', 'hub', parent, '--kind', 'cli'], check=True, stdout=subprocess.DEVNULL)

before = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in root.rglob('*') if p.is_file() and p.suffix != '.lock'}
snap = json.loads(subprocess.run([str(binpath / 'agent-top'), '--json', '--agent', 'done', '--feed', '50'],
                                capture_output=True, text=True, check=True).stdout)
agents = {a['role']: a for a in snap['agents']}
assert agents['coder']['state'] == 'live' and agents['coder']['action']['tool'] == 'Bash'
assert agents['coder']['session_id'] not in top.process_table()[pid], 'positive token liveness without thread ID in argv'
assert agents['reused']['state'] == 'dead', 'negative process token control'
assert agents['done']['state'] == 'done' and agents['failed']['state'] == 'error'
assert agents['resumed']['state'] == 'dead', 'started after completion must not stay done'
assert agents['resumed']['turns'] == 2 and agents['resumed']['run_turns'] == 1
assert agents['done']['turns'] == 1, 'items are not user turns'
assert agents['done']['ctx_tokens'] is None and agents['done']['cost_usd'] is None
assert agents['done']['model_id'] is None, 'CLI does not report the resolved model'
assert agents['done']['usage_tokens']['input_tokens'] == 23000
assert agents['done']['usage_scope'] == 'session'
assert agents['failed']['result']['text'] == 'fixture failure'
assert agents['done']['result']['text'] == 'DONE: all checks passed'
assert agents['hub']['kind'] == 'session' and agents['hub']['state'] == 'done'
assert agents['hub/aaaaaaa']['state'] == 'done' and agents['hub/ccccccc']['state'] == 'stopped'
assert agents['hub/aaaaaaa']['age_s'] < 10, 'parsed completion time survives fixed creation mtime'
assert agents['hub/aaaaaaa']['last_event_at'] == dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(timespec='seconds')
assert agents['hub/ccccccc']['result']['is_error'] is False
child = agents['hub/bbbbbbb']
assert child['state'] == 'unknown' and child['turns'] == 1, 'copied completion excluded; activity is not process identity'
assert child['last_text'] == 'OWN MESSAGE' and child['model_id'] == 'gpt-6-sol'
assert child['ctx_tokens'] == 17000 and child['usage_tokens']['input_tokens'] == 310000
assert child['ctx_source'] == 'last_input_tokens' and child['context_window'] == 200000
assert child['usage_scope'] == 'session'
assert child['action'] is None, 'native tool result closes its matching call'
assert not any('ddddddd' in role for role in agents), 'unregistered parent ignored'

# Incremental reads tolerate torn writes, ignore repeated updates and reset after replacement.
state = top.LogState(live_log)
state.update()
assert state.turns == 1 and state.action()['text'] == 'pytest -x'
state.update()
assert state.turns == 1 and state.tool_calls == 1
with live_log.open('ab') as f:
    f.write(json.dumps(finish).encode())
state.update()
assert state.last_result is None, 'partial terminal event ignored'
with live_log.open('ab') as f:
    f.write(b'\n')
state.update()
assert state.last_result and state.usage_tokens['input_tokens'] == 23000 and state.action() is None
write(live_log, [cli[0], cli[1]])
state.update()
assert state.turns == 1 and state.usage_tokens is None and state.last_result is None

# Native resume invalidates previous completion only when a new task starts.
from subagents import Finder
finder = Finder()
assert finder.codex_session(doneid, None, now, True).state == 'done'
with donelog.open('a') as f:
    f.write(json.dumps(event('event_msg', {'type': 'task_started', 'turn_id': 'resume', 'started_at': int(now)})) + '\n')
assert finder.codex_session(doneid, None, now, True).state == 'unknown'
assert finder.codex_session(doneid, False, now, True).state == 'dead'

feed = top.Feed(livelog)
feed.update()
assert all('INHERITED' not in i.text for i in feed.items)
assert any(i.kind == 'tool' and i.tool == 'exec_command' for i in feed.items)
# Malformed optional usage records cannot crash a view or invent context.
norm = top.codex_rollouts.Normalizer()
assert norm.events(event('event_msg', {'type': 'token_count', 'info': {'last_token_usage': 'bad'}}))[0]['context_tokens'] is None
assert norm.events(event('event_msg', {'type': 'error', 'message': 'retrying'})) == [], 'recoverable error is not terminal'
view = subprocess.run([str(binpath / 'agent-top'), '--once', '--agent', 'hub', '--width', '120'], capture_output=True, text=True, check=True).stdout
assert 'native Codex session; read-only' in view and 'input usage' in view
widget = subprocess.run([str(binpath / 'agent-top'), '--widget'], capture_output=True, text=True, check=True).stdout
assert 'hub/bbbbbbb' in widget
# Compare only paths not intentionally changed by the incremental controls.
for p, fingerprint in before.items():
    if p not in (live_log, donelog):
        assert (p.stat().st_mtime_ns, p.read_bytes()) == fingerprint, f'monitoring modified {p}'
print('PASS Codex CLI/native monitoring: states, tokens, forks, resume, partial writes, feed and read-only controls')
PY
check $? 0 "Codex monitoring controls"
exit $fail
