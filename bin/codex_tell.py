"""Bounded tell dispatch through the existing public Codex app-server proxy.

No server launch, thread load/resume, queue fallback or private Desktop transport.
A native handoff is a caller obligation, never evidence of delivery.
"""
from __future__ import annotations

import json
import os
import re
import selectors
import subprocess
import time
import uuid

import engines
import hubcore as hc

UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
TIMEOUT = 5
MAX_OUTPUT = 4_000_000


class Unavailable(Exception):
    pass


class Rejected(Exception):
    pass


class Proxy:
    """One public proxy connection, one deadline, bounded reads and writes."""
    def __init__(self, cwd=None):
        self.proc = subprocess.Popen([engines.codex_bin(cwd), 'app-server', 'proxy'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=hc.child_env())
        self.ready = selectors.DefaultSelector()
        self.ready.register(self.proc.stdout, selectors.EVENT_READ)
        os.set_blocking(self.proc.stdin.fileno(), False)
        self.deadline = time.monotonic() + TIMEOUT
        self.pending = b''
        self.total = 0
        self.serial = 0

    def remaining(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Unavailable('public proxy deadline exceeded')
        return left

    def send(self, message):
        data = json.dumps(message).encode() + b'\n'
        with selectors.DefaultSelector() as writable:
            writable.register(self.proc.stdin, selectors.EVENT_WRITE)
            while data:
                if not writable.select(self.remaining()):
                    raise Unavailable('public proxy write timed out')
                try:
                    count = os.write(self.proc.stdin.fileno(), data)
                    data = data[count:]
                except BlockingIOError:
                    continue

    def rpc(self, method, params):
        self.serial += 1
        request_id = self.serial
        self.send({'id': request_id, 'method': method, 'params': params})
        while True:
            while b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise Unavailable('invalid public proxy response')
                if message.get('id') == request_id:
                    if 'error' in message:
                        raise Rejected(f'{method} rejected by public proxy')
                    result = message.get('result')
                    if not isinstance(result, dict):
                        raise Unavailable('invalid public proxy result')
                    return result
            if not self.ready.select(self.remaining()):
                raise Unavailable('public proxy read timed out')
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise Unavailable('public proxy closed')
            self.total += len(chunk)
            if self.total > MAX_OUTPUT:
                raise Unavailable('public proxy response limit exceeded')
            self.pending += chunk

    def close(self):
        self.ready.close()
        if self.proc.poll() is None:
            self.proc.terminate()  # our connection only
        try:
            self.proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=1)
        self.proc.stdin.close()
        self.proc.stdout.close()


def thread_state(proxy, sid):
    try:
        thread = proxy.rpc('thread/read', {'threadId': sid, 'includeTurns': True}).get('thread')
    except Rejected as exc:
        raise Unavailable(str(exc)) from None
    if not isinstance(thread, dict) or thread.get('id') != sid:
        raise Rejected('thread/read did not return the exact registered UUID')
    status = thread.get('status', {}).get('type')
    turns = thread.get('turns')
    if not isinstance(turns, list):
        raise Unavailable('thread/read omitted turn history')
    active = [t.get('id') for t in turns if isinstance(t, dict) and t.get('status') == 'inProgress']
    if status == 'active' and len(active) == 1 and isinstance(active[0], str) and active[0]:
        return status, active[0]
    if status == 'idle' and not active:
        return status, None
    raise Unavailable('exact active turn or loaded idle runtime unavailable')


def native_handoff(stage, role, rec, sid, message, source, reason):
    """Literal caller handoff. Source is attribution, not fabricated human authority."""
    return {'state': 'pending', 'transport': 'native-caller', 'reason': reason,
            'request_id': str(uuid.uuid4()), 'thread_id': sid, 'message': message,
            'stage': stage, 'role': role, 'registry_path': str(hc.roles_path(stage)),
            'registry_record': rec, 'source': source,
            'human_authority': {'state': 'requires-caller-verification', 'reference': None},
            'native_tool': 'send_message_to_thread',
            'receipt': {'state': 'pending', 'tool_result': None, 'immediacy': 'unverified'},
            'caller_action': 'Before waiting or any next action: verify explicit human authority for this '
                             'communication and the supported native tool schema; reread registry and require '
                             'this exact record/full UUID; call send_message_to_thread with the literal UUID '
                             'and message. Record the actual tool receipt. Accepted alone does not prove active '
                             'steer; validate same-turn delivery. Unknown results must not be retried. If the '
                             'tool or human proof is unavailable, retain pending and report the capability gap. '
                             'This communication does not grant finance, production, role or goal changes.'}


def dispatch(stage, role, rec, message, source):
    """Return exact-turn steered or mode-unverified accepted acknowledgements."""
    sid = rec.get('cli_session_id') or rec.get('session')
    receipt = {'state': 'failed', 'transport': 'public-proxy', 'thread_id': sid, 'source': source}
    if not isinstance(sid, str) or not UUID.fullmatch(sid):
        return {**receipt, 'reason': 'registry recipient must be a full UUID'}
    proxy = None
    attempted = False
    try:
        proxy = Proxy(rec.get('cwd'))
        try:
            proxy.rpc('initialize', {'clientInfo': {'name': 'delamain_tell', 'version': '1'}})
        except Rejected as exc:
            raise Unavailable(str(exc)) from None
        proxy.send({'method': 'initialized'})
        state, turn_id = thread_state(proxy, sid)
        # Serialize the final registry check and mutation against normal role takeovers.
        with hc.roles_lock(stage):
            if hc.roles_load(stage)['roles'].get(role) != rec:
                raise Rejected('registry holder changed before delivery')
            if thread_state(proxy, sid) != (state, turn_id):
                raise Rejected('runtime turn changed before delivery')
            params = {'threadId': sid, 'input': [{'type': 'text', 'text': message}]}
            if state == 'active':
                params['expectedTurnId'] = turn_id
            attempted = True  # a write/response failure from here may already have delivered
            result = proxy.rpc('turn/steer' if state == 'active' else 'turn/start', params)
        returned = result.get('turnId') if state == 'active' else result.get('turn', {}).get('id')
        if state == 'idle' and result.get('turn', {}).get('status') != 'inProgress':
            raise Unavailable('turn/start did not acknowledge an in-progress turn')
        if not isinstance(returned, str) or not returned or (state == 'active' and returned != turn_id):
            raise Unavailable('mutation acknowledgement did not match the expected turn')
        if state == 'active':
            return {**receipt, 'state': 'steered', 'turn_id': returned}
        # turn/start has no atomic expected-idle condition: another client may have begun this turn.
        return {**receipt, 'state': 'accepted', 'turn_id': returned, 'delivery_mode': 'unverified'}
    except Rejected as exc:
        return {**receipt, 'reason': str(exc)}
    except (Unavailable, hc.Failure, hc.UsageError, OSError, subprocess.SubprocessError,
            ValueError, TypeError, AttributeError) as exc:
        if attempted:
            return {**receipt, 'state': 'unknown', 'reason': str(exc), 'retry': 'forbidden'}
        # Revalidate even when probing failed; never hand off to a replaced recipient.
        with hc.roles_lock(stage):
            if hc.roles_load(stage)['roles'].get(role) != rec:
                return {**receipt, 'reason': 'registry holder changed before native handoff'}
            return native_handoff(stage, role, rec, sid, message, source, str(exc))
    finally:
        if proxy is not None:
            try:
                proxy.close()
            except (OSError, subprocess.SubprocessError):
                pass
