#!/usr/bin/env bash
# PR20 review controls: actual config steps, command dispatch, generated briefs and skill text.
# Every case uses a throwaway home and stand-in CLIs; no model or native app is called.
# Select L1, L2, L3, L3_cli, L3_desktop, L3_skill or M3 with PR20_CASE (default: all).
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" "${PR20_CASE:-all}" <<'PY'
import contextlib
import datetime as dt
import fcntl
import io
import json
import os
import pathlib
import re
import runpy
import shlex
import subprocess
import sys

root, tmp = map(pathlib.Path, sys.argv[1:3])
selected = sys.argv[3]
sys.path.insert(0, str(root / 'bin'))
old = '11111111-1111-4111-8111-111111111111'
new = '22222222-2222-4222-8222-222222222222'
for key in list(os.environ):
    if key.startswith(('AGENT_', 'HUB_', 'CODEX_', 'CLAUDE_')) or key == 'PLUGIN_ROOT':
        del os.environ[key]
fake = tmp / 'fake-cli'
fake.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo "2.1.300 (Claude Code)"; else exit 1; fi\n')
fake.chmod(0o755)
(tmp / 'sessions').mkdir()
os.environ.update(HOME=str(tmp), AGENT_HUB_TZ='UTC', AGENT_HUB_NO_PROJECT='1',
                  AGENT_HUB_NO_NAMING='1', CLAUDE_BIN=str(fake), CODEX_BIN=str(fake),
                  CLAUDE_SESSIONS_DIR=str(tmp / 'sessions'), CODEX_HOME=str(tmp / 'codex'),
                  AGENT_HUB_JWAIT_FOR='1s')
import autopilot as ap
import hubcore as hc
hub = runpy.run_path(str(root / 'bin/hub'), run_name='pr20_control')

def setup(name, engine='claude'):
    home = tmp / name
    stage = home / 'stage-a'
    stage.mkdir(parents=True)
    os.environ['AGENT_HUB_HOME'] = str(home)
    os.environ['AGENT_HUB_ENGINE'] = engine
    os.environ.pop('CODEX_THREAD_ID', None)
    os.environ.pop('CLAUDE_CODE_SESSION_ID', None)
    (stage / 'roles.json').write_text(json.dumps({'roles': {'hub': {
        'session': old, 'cli_session_id': old, 'tag': 'hub-1', 'kind': 'cli'}}}))
    handoff = stage / 'HANDOFF-hub-fixture.md'
    handoff.write_text('# Handoff "Hub stage-a #1" → "Hub stage-a #2" — stage-a\n'
                       '\n## Business DoD\nComplete the approved fixture validation; source: owner fixture.\n'
                       'Boundary: no merge or production authority.\n## 0. First steps\nTake over.\n## 2. Queue\n'
                       'The finite queue snapshot is empty; reconcile outstanding validation against Business DoD.\n')
    return home, stage, handoff

def command(*args):
    return subprocess.run([str(root / 'bin/hub'), *map(str, args)], cwd=tmp,
                          capture_output=True, text=True, timeout=15)

def l1():
    # Positive scope controls: shortening the mutex must still serialize role/state publication.
    scope_home, _, scope_handoff = setup('l1-scope')
    observed = []
    def require_locked(label):
        with open(scope_home / '.auto-handoff-stage-a.lock', 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                observed.append(label)
            else:
                raise AssertionError(f'L1: {label} must hold the state mutex')
    original_takeover = ap.on_takeover
    original_loader = hub['main'].__globals__['load_script']
    def on_takeover(*args, **kwargs):
        require_locked('on_takeover')
        return original_takeover(*args, **kwargs)
    def loader(name):
        module = original_loader(name)
        if name == 'roles':
            original_set = module.set_role
            def set_role(*args, **kwargs):
                require_locked('role update')
                return original_set(*args, **kwargs)
            module.set_role = set_role
        return module
    ap.on_takeover = on_takeover
    hub['main'].__globals__['load_script'] = loader
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            assert hub['main'](['takeover', '--stage', 'stage-a', '--session', new,
                                '--handoff', str(scope_handoff), '--no-project']) == 0
    finally:
        ap.on_takeover = original_takeover
        hub['main'].__globals__['load_script'] = original_loader
    assert observed == ['role update', 'on_takeover'], observed
    original_preflight = ap.desktop_preflight
    def preflight(*args, **kwargs):
        require_locked('Desktop preflight')
        raise hc.Failure('scope-control-stop-before-mutation')
    ap.desktop_preflight = preflight
    try:
        try:
            hub['main'](['takeover', '--stage', 'stage-a', '--session', new, '--auto-handoff',
                         '--handoff', str(scope_handoff), '--desktop-request', 'fixture-request'])
        except hc.Failure as error:
            assert str(error) == 'scope-control-stop-before-mutation', error
        else:
            raise AssertionError('L1: Desktop preflight seam was not called')
    finally:
        ap.desktop_preflight = original_preflight
    assert observed[-1] == 'Desktop preflight', observed
    home, stage, handoff = setup('l1')
    probe = stage / 'mutex-probe.json'
    # The actual most-specific config layer must run check/apply/check outside the state mutex.
    step = stage / 'takeover.sh'
    step.write_text('#!/usr/bin/env python3\n' +
        'import fcntl,json,os,pathlib,sys\n' +
        'p=pathlib.Path(os.environ["AGENT_HUB_HOME"])\n' +
        'with open(p/".auto-handoff-stage-a.lock","a") as lock:\n' +
        '    try:\n' +
        '        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); acquired=True\n' +
        '    except BlockingIOError: acquired=False\n' +
        '    out=p/"stage-a/mutex-probe.json"\n' +
        '    rows=json.loads(out.read_text()) if out.exists() else []\n' +
        '    rows.append({"mode":sys.argv[1],"acquired":acquired})\n' +
        '    out.write_text(json.dumps(rows))\n' +
        'done=p/"stage-a/step-applied"\n' +
        'if sys.argv[1]=="apply": done.touch()\n' +
        'sys.exit(0 if done.exists() else 1)\n')
    step.chmod(0o755)
    control = subprocess.run([str(step), 'check'], capture_output=True, text=True, timeout=5)
    assert control.returncode == 1 and json.loads(probe.read_text()) == [
        {'mode': 'check', 'acquired': True}], 'L1: positive nonblocking probe control failed'
    probe.unlink()
    result = command('takeover', '--stage', 'stage-a', '--session', new,
                     '--handoff', handoff, '--no-project')
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    rows = json.loads(probe.read_text())
    assert [row['mode'] for row in rows] == ['check', 'apply', 'check'], rows
    assert all(row['acquired'] for row in rows), (
        'L1: config-layer takeover.sh must acquire the state mutex nonblocking during check/apply', rows)

def l2():
    _, stage, handoff = setup('l2', 'codex')
    os.environ.update(CODEX_THREAD_ID=old, CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',
                      CODEX_APP_TOOLS_PIPE_PATH='/never-connect')
    ap.save_state('stage-a', {'chain': 1, 'pending': {
        'n': 2, 'kind': 'headless', 'surface': 'cli', 'engine': 'codex',
        'author': old, 'handoff': str(handoff), 'taken_over': False}})
    calls = []
    original = ap.succeed
    def recorder(*args, **kwargs):
        calls.append((args, kwargs))
        return 0
    ap.succeed = recorder
    try:
        assert hub['main'](['succeed', '--stage', 'stage-a', '--replace', '--force']) == 0
    finally:
        ap.succeed = original
    assert len(calls) == 1 and calls[0][1].get('replace') is True, calls
    assert calls[0][1].get('surface') == 'cli', (
        'L2: app-origin --replace of an existing CLI successor must dispatch surface=cli', calls)

def first_wait_contract(label, text):
    plain = text.replace('`', '').lower()
    # Check one connected instruction, before the finite queue's conditional waiting rule.
    instruction = re.search(r'[^\n.!?]*(?:first[^\n.!?]*jwait|jwait[^\n.!?]*first)'
                            r'[^.!?]*(?:unconditional)[^.!?]*', plain)
    assert instruction and 'once' in instruction.group(), (
        f'L3: {label} must require the digest first jwait once unconditionally before conditional waits')
    conditional = plain.find('wait only while')
    assert conditional >= 0 and instruction.start() < conditional, (
        f'L3: {label} must preserve conditional waits after unconditional handover replay')

def followthrough_contract(label, text):
    plain = text.replace('`', '').lower()
    for phrase in ('terminal follow-through', 'business dod', 'report', 'resource ownership',
                   'next independent authorized ready work', 'blocker', 'expected event',
                   "executor's artifact/call-budget stop ends its brief", 'reconcile the finite queue snapshot',
                   'explicit owner stop', 'genuine business/authority boundary', 'source/scope'):
        assert phrase in plain, f'{label}: missing {phrase}'
    assert 'when nothing remains' not in plain and 'queue is done' not in plain, label

def l3_cli():
    _, _, handoff = setup('l3-cli', 'codex')
    # Even with an empty finite queue, the first digest wait replays a handover event.
    # Write it before starting jwait: omitting that first wait would leave it unanswered.
    since = dt.datetime.fromtimestamp(handoff.stat().st_mtime, dt.timezone.utc)
    hc.journal_append('stage-a', 'fixture-worker', 'BLOCKED @hub inherited during handover')
    argv = shlex.split(hub['jwait_command']('stage-a', 'hub-2', since))
    assert '--since' in argv, argv
    argv[0] = str(root / 'bin/jwait')
    replay = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    assert replay.returncode == 0 and 'BLOCKED @hub inherited during handover' in replay.stdout, (
        'L3: the first digest jwait must actually replay inherited events',
        replay.returncode, replay.stdout, replay.stderr)
    print('PASS L3_cli replay: empty finite queue still has an inherited BLOCKED event')
    successor = ap.CodexSuccessor('stage-a', 1, handoff, 'gpt-6.1-sol',
                                  'danger-full-access', tmp, 1, 10, effort='high')
    brief = successor.brief('fixture').read_text()
    first_wait_contract('generated CLI brief', brief)
    followthrough_contract('generated CLI brief', brief)
    claude = ap.Successor('stage-a', 1, handoff, 'opus', 'default', tmp, 1, 10, effort='high')
    claude_brief = claude.brief('fixture').read_text()
    assert 'Terminal follow-through' not in claude_brief
    assert 'When nothing is left to wait for' in claude_brief and 'Bash `timeout` 600000, `--for 9m`' in claude_brief


def l3_desktop():
    _, _, handoff = setup('l3-desktop', 'codex')
    os.environ['CODEX_THREAD_ID'] = old
    with contextlib.redirect_stdout(io.StringIO()):
        rc = ap.prepare_desktop('stage-a', 1, 2, handoff, tmp, 'gpt-6.1-sol', 'high',
                                {'type': 'danger-full-access'}, 'never', None, False)
    assert rc == 0, rc
    pending = ap.load_state('stage-a')['pending']
    brief = pathlib.Path(pending['brief']).read_text()
    assert brief == pending['create_args']['prompt']
    first_wait_contract('generated Desktop brief', brief)
    followthrough_contract('generated Desktop brief', brief)

def l3_skill():
    text = (root / 'skills/hub/references/autopilot.md').read_text().split('**Autopilot**', 1)[1]
    first_wait_contract('shared skill Autopilot', text)

def m3():
    # Immutable review contract, available in shallow CI checkouts and source archives too.
    paragraph = (root / 'tests/fixtures/autopilot-0.9.0.md').read_text().rstrip('\n')
    current = (root / 'skills/hub/references/autopilot.md').read_text()
    assert paragraph in current, 'M3: the 0.9.0 Claude/CLI Autopilot paragraph must remain verbatim'
    section = current.split('**Autopilot**', 1)[1].lower()
    assert 'desktop' in section and 'finite' in section, 'M3: Desktop and finite-queue additions must remain'

cases = {'L1': l1, 'L2': l2, 'L3_cli': l3_cli, 'L3_desktop': l3_desktop,
         'L3_skill': l3_skill, 'M3': m3}
first_wait_contract('positive wording control',
                    "Run the digest's first `jwait` once unconditionally. Then wait only while work remains.")
assert selected in {'all', 'L3', *cases}, f'unknown PR20_CASE: {selected}'
failed = []
for name, case in cases.items():
    if selected not in ('all', name) and not (selected == 'L3' and name.startswith('L3_')):
        continue
    try:
        case()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f'FAIL {name}: {error}')
        failed.append(name)
    else:
        print(f'PASS {name}')
sys.exit(bool(failed))
PY
