"""Focused tell controls, using only mocked public/native transports."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import codex_tell as ct
import hubcore as hc

loader = importlib.machinery.SourceFileLoader('tell_cli', str(Path(sys.argv[1]) / 'tell'))
spec = importlib.util.spec_from_loader(loader.name, loader)
tell = importlib.util.module_from_spec(spec)
loader.exec_module(tell)
root = Path(sys.argv[2])
sid = 'aaaaaaaa-1111-4111-8111-111111111111'
rec = {'engine': 'codex', 'session': sid, 'kind': 'cli', 'tag': 'hub-1'}
source = {'tag': 'sender-hub-2', 'journal_path': 'journal', 'journal_line': 'audit'}
message = 'literal message (from sender-hub-2)'
log = Path(os.environ['TELL_PROXY_LOG'])
os.environ['TELL_REGISTRY'] = str(hc.roles_path('target'))


def setup(mode):
    hc.roles_save('target', {'roles': {'hub': rec}, 'retired': []})
    os.environ['TELL_PROXY_MODE'] = mode
    log.unlink(missing_ok=True)


def requests():
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def mutations():
    return [r for r in requests() if r['method'] in ('turn/start', 'turn/steer')]


# Regression: idle observed twice does not establish that this request created the acknowledged turn.
setup('idle-to-active')
result = ct.dispatch('target', 'hub', rec, message, source)
assert result['state'] == 'accepted' and result['delivery_mode'] == 'unverified', result
assert result['turn_id'] == 'turn-other-client' and result['thread_id'] == sid, result
assert len(mutations()) == 1 and mutations()[0]['method'] == 'turn/start', requests()
assert 'expectedTurnId' not in mutations()[0]['params']
assert sum(r['method'] == 'thread/read' for r in requests()) == 2

for mode, state in (('active', 'steered'), ('idle', 'accepted')):
    setup(mode)
    result = ct.dispatch('target', 'hub', rec, message, source)
    assert result['state'] == state, result
    assert result['thread_id'] == sid and result['source'] == source
    if mode == 'idle':
        assert result['delivery_mode'] == 'unverified'
    else:
        assert result['turn_id'] == 'turn-current' and 'delivery_mode' not in result
    assert len(mutations()) == 1
    request = mutations()[0]
    assert request['params']['threadId'] == sid
    assert request['params']['input'] == [{'type': 'text', 'text': message}]
    assert requests()[0]['method'] == 'initialize' and requests()[1]['method'] == 'initialized'
    assert sum(r['method'] == 'thread/read' for r in requests()) == 2

for mode in ('wrong-uuid', 'turn-race', 'takeover', 'reject-turn'):
    setup(mode)
    result = ct.dispatch('target', 'hub', rec, message, source)
    assert result['state'] == 'failed', (mode, result)
    assert 'native_tool' not in result
    assert len(mutations()) == (1 if mode == 'reject-turn' else 0), (mode, requests())

for mode in ('timeout', 'wrong-turn', 'malformed', 'idle-bad-ack'):
    setup(mode)
    with patch.object(ct, 'TIMEOUT', 0.5):
        started = time.monotonic()
        result = ct.dispatch('target', 'hub', rec, message, source)
    assert time.monotonic() - started < 3
    assert result['state'] == 'unknown' and result['retry'] == 'forbidden', (mode, result)
    assert 'native_tool' not in result and len(mutations()) == 1

for mode in ('notLoaded', 'missing-turn', 'hang-read', 'unavailable', 'reject-init'):
    setup(mode)
    with patch.object(ct, 'TIMEOUT', 0.5):
        result = ct.dispatch('target', 'hub', rec, message, source)
    assert result['state'] == 'pending', (mode, result)
    assert not mutations()
    assert result['thread_id'] == sid and result['message'] == message and result['source'] == source
    assert result['native_tool'] == 'send_message_to_thread'
    assert result['human_authority']['reference'] is None
    assert result['receipt'] == {'state': 'pending', 'tool_result': None, 'immediacy': 'unverified'}
    # Mock caller: absence of actual human proof must leave the handoff pending.
    called = []
    def caller(proof, current, tool_result):
        if not proof or current != result['registry_record']:
            return {'state': 'pending'}
        called.append((result['thread_id'], result['message']))
        # Tool acceptance is not proof that active input was steered.
        return {'state': 'accepted', 'tool_result': tool_result, 'immediacy': 'unverified'}
    assert caller(None, rec, {})['state'] == 'pending' and not called
    assert caller('explicit scratch owner instruction', {**rec, 'session': 'other'}, {})['state'] == 'pending'
    receipt = caller('explicit scratch owner instruction', rec, {'accepted': True})
    assert called == [(sid, message)] and receipt['state'] == 'accepted' and receipt['immediacy'] == 'unverified'

setup('active')
with patch.object(ct.engines, 'codex_bin', side_effect=hc.Failure('not installed')):
    assert ct.dispatch('target', 'hub', rec, message, source)['state'] == 'pending'
assert not requests()
for identity in ('short', 'display-name', 'client_id'):
    result = ct.dispatch('target', 'hub', {**rec, 'session': identity}, message, source)
    assert result['state'] == 'failed' and not requests()

# End-to-end tell: a single journal line, source attribution, QUESTION and literal native payload.
os.environ['HUB_TAG'] = 'sender'
os.environ['HUB_STAGE'] = 'sender-stage'
for mode, exit_code in (('active', 0), ('idle', 0), ('idle-to-active', 0), ('notLoaded', 1), ('timeout', 1)):
    setup(mode)
    before = hc.journal_path('target').read_text() if hc.journal_path('target').exists() else ''
    completed = subprocess.run([str(Path(sys.argv[1]) / 'tell'), 'target', '--question', 'do this'],
                               capture_output=True, text=True, timeout=10)
    assert completed.returncode == exit_code, completed.stderr + completed.stdout
    after = hc.journal_path('target').read_text()
    new = after[len(before):]
    assert new.count('@hub QUESTION do this') == 1, new
    line = next(s for s in completed.stdout.splitlines() if s.startswith('codex tell receipt: '))
    receipt = json.loads(line.removeprefix('codex tell receipt: '))
    assert receipt['source']['journal_line'].endswith('@hub QUESTION do this')
    if mode in ('idle', 'idle-to-active'):
        assert receipt['state'] == 'accepted' and receipt['delivery_mode'] == 'unverified', receipt
        assert len(mutations()) == 1 and mutations()[0]['method'] == 'turn/start'
        assert receipt['turn_id'] == ('turn-other-client' if mode == 'idle-to-active' else 'turn-idle-start')
    if mode == 'active':
        assert receipt['state'] == 'steered' and receipt['turn_id'] == 'turn-current'
    if mode == 'notLoaded':
        assert receipt['message'] == 'QUESTION do this (from sender-stage-sender)', receipt
        assert receipt['state'] == 'pending'
    else:
        assert mutations()[0]['params']['input'][0]['text'] == 'QUESTION do this (from sender-stage-sender)'

# --address remains read-only, no public/native delivery attempt and retains queue as an explicit address only.
setup('active')
before = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
completed = subprocess.run([str(Path(sys.argv[1]) / 'tell'), 'target', '--address'], capture_output=True, text=True)
assert completed.returncode == 0 and f'queue --thread {sid}' in completed.stdout
assert before == {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
assert not requests()

# Promoted detached recipient retains its existing address/inbox path; no unsupported native resume or steer.
setup('active')
with patch.object(tell.codex_sessions, 'detached', return_value={'role': 'worker'}), \
     patch.object(tell.codex_tell, 'dispatch', side_effect=AssertionError('detached dispatch forbidden')):
    assert tell.main(['target', 'existing detached behavior']) == 0
assert not requests()
print('PASS active exact-turn steer; idle and post-final-read idle-to-active acknowledged with mode unverified; UUID/turn/takeover guards; unknown no retry; pending native human proof/receipt; one audit; detached and address preserved')
