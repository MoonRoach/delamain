#!/usr/bin/env python3
"""Public-protocol fixture: never starts a model, loads or resumes a thread."""
import json
import os
import sys
import time
from pathlib import Path

assert sys.argv[1:] == ['app-server', 'proxy'], sys.argv
mode = os.environ.get('TELL_PROXY_MODE', 'active')
log = Path(os.environ['TELL_PROXY_LOG'])
reads = 0
for line in sys.stdin:
    request = json.loads(line)
    with log.open('a') as out:
        out.write(json.dumps(request) + '\n')
    method = request['method']
    assert method in ('initialize', 'initialized', 'thread/read', 'turn/steer', 'turn/start'), method
    if method == 'initialized':
        continue
    result = {}
    if method == 'initialize' and mode == 'reject-init':
        print(json.dumps({'id': request['id'], 'error': {'code': -32600}}), flush=True)
        continue
    if method == 'thread/read':
        reads += 1
        if mode == 'unavailable':
            print(json.dumps({'id': request['id'], 'error': {'code': -32000, 'message': 'not found'}}), flush=True)
            continue
        if mode == 'hang-read':
            time.sleep(30)
        if mode == 'takeover' and reads == 1:
            path = Path(os.environ['TELL_REGISTRY'])
            data = json.loads(path.read_text())
            data['roles']['hub']['session'] = 'cccccccc-3333-4333-8333-333333333333'
            path.write_text(json.dumps(data))
        state = 'idle' if mode in ('idle', 'idle-bad-ack', 'idle-to-active') else 'notLoaded' if mode == 'notLoaded' else 'active'
        turn = 'turn-new' if mode == 'turn-race' and reads == 2 else 'turn-current'
        sid = request['params']['threadId'] if mode != 'wrong-uuid' else 'bbbbbbbb-2222-4222-8222-222222222222'
        result = {'thread': {'id': sid, 'status': {'type': state},
                             'turns': [] if state != 'active' or mode == 'missing-turn' else
                             [{'id': turn, 'status': 'inProgress', 'items': []}]}}
    elif method in ('turn/steer', 'turn/start'):
        assert reads == 2
        assert set(request['params']) == ({'threadId', 'input', 'expectedTurnId'} if method == 'turn/steer'
                                          else {'threadId', 'input'})
        if method == 'turn/steer':
            assert request['params']['expectedTurnId'] == 'turn-current'
        if mode == 'timeout':
            time.sleep(30)
        if mode == 'malformed':
            print('not json', flush=True)
            continue
        if mode == 'reject-turn':
            print(json.dumps({'id': request['id'], 'error': {'code': -32600, 'message': 'turn changed'}}), flush=True)
            continue
        # Both reads were idle; another client starts after the final read, before this mutation.
        # Public turn/start can add our input to that already-active turn without an expected-idle guard.
        acknowledged = 'turn-other-client' if mode == 'idle-to-active' else 'turn-idle-start'
        result = {'turnId': 'wrong-turn' if mode == 'wrong-turn' else 'turn-current'} if method == 'turn/steer' else {'turn': {'id': acknowledged, 'status': 'completed' if mode == 'idle-bad-ack' else 'inProgress'}}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
