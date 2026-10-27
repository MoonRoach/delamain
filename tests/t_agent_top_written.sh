#!/bin/bash
# agent-top: what a role wrote and what was said to it are two numbers. A line addressed to a hub (`[pace] @hub …`, a
# broadcast, a worker's `@hub DONE`) is not the hub's activity; the hub's own journal line or its session's transcript
# (Claude) / rollout (Codex) is, whichever is fresher. Negative controls: a hub with only addressed lines has no write,
# a hub's remark to itself is not "addressed", a worker's own line is its write.
. "$(dirname "$0")/lib.sh"
new_home
export PYTHONDONTWRITEBYTECODE=1 CLAUDE_CONFIG_DIR=$AGENT_HUB_HOME/claude CODEX_HOME=$AGENT_HUB_HOME/codex AGENT_TOP_CACHE=0
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

binpath, root = Path(sys.argv[1]), Path(sys.argv[2])
HUB_SID = '99999999-1111-4111-8111-111111111111'
CODEX_SID = 'cdcdcdcd-1111-4111-8111-111111111111'
fails = 0


def chk(name, cond, detail=None):
    global fails
    print(('PASS ' if cond else 'FAIL ') + name + ('' if cond or detail is None else f'\n     {detail}'))
    fails += 0 if cond else 1


def stage(name, roles, journal):
    work = root / name / 'coordinator' / 'work'
    work.mkdir(parents=True)
    (root / name / 'roles.json').write_text(json.dumps({'version': 1, 'roles': roles}))
    now = dt.datetime.now(dt.timezone.utc)
    lines = ''.join(f'- {(now - dt.timedelta(minutes=m)):%H:%M} [{tag}] {text}\n' for m, tag, text in journal)
    (work / f'journal-{now.date()}.md').write_text(lines)


def snapshot(name):
    out = subprocess.run([str(binpath / 'agent-top'), '--json', '--all', '--stage', name], capture_output=True, text=True, check=True).stdout
    return {r['role']: r for r in next(iter(json.loads(out)['roles'].values()))}


def once(name):
    return subprocess.run([str(binpath / 'agent-top'), '--once', '--all', '--stage', name, '--width', '160'],
                          capture_output=True, text=True, check=True).stdout


def touch_ago(path, seconds):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    t = dt.datetime.now().timestamp() - seconds
    os.utime(path, (t, t))


# 1. only lines addressed to the hub in the last hour: the hub is silent; the worker's own line is the worker's write.
# The hub's remark to itself ('@hub' in its own line) is not a message to it.
roles = {'hub': {'kind': 'cli', 'tag': 'hub-9', 'cli_session_id': HUB_SID, 'engine': 'claude'},
         'w1': {'kind': 'headless', 'tag': 'w1'}}
stage('only-addressed', roles, [
    (50, 'pace', '@hub LIMIT URGENT Claude 7d: 22% used'),
    (40, 'owner', '@hub write a handoff'),
    (30, 'w1', '@hub DONE report ready'),
    (20, 'other-stage-hub-3', '@only-addressed-hub-9 a question from another stage')])
r = snapshot('only-addressed')
chk('addressed only: the hub has no journal line of its own', r['hub']['journal_age_s'] is None)
chk('addressed only: …no last write at all', r['hub']['last_written_age_s'] is None and r['hub']['last_written_via'] is None)
chk('addressed only: …but it was addressed 20 minutes ago (the stage-qualified @name counts)',
    r['hub']['last_addressed_age_s'] is not None and 1100 <= r['hub']['last_addressed_age_s'] <= 1300)
chk('a worker\'s own line is its write, not an address', r['w1']['last_written_age_s'] is not None
    and 1700 <= r['w1']['last_written_age_s'] <= 1900 and r['w1']['last_written_via'] == 'journal' and r['w1']['last_addressed_age_s'] is None)

text = once('only-addressed')
chk('--once: a hub with only addressed lines reads "wrote —, addressed 20m ago"', '* hub [hub-9] cli wrote —, addressed 20m ago' in text, text)

# 2. the hub's own line is its write; a line it wrote to itself is not an address; the broadcasts are
stage('own-line', roles, [
    (90, 'hub-9', '@hub note to myself'),
    (30, 'pace', '@hub LIMIT'),
    (10, 'hub-9', 'back to work on the plan')])
r = snapshot('own-line')['hub']
chk('own line: written 10 minutes ago via the journal', 500 <= r['last_written_age_s'] <= 700 and r['last_written_via'] == 'journal'
    and r['journal_age_s'] == r['last_written_age_s'])
chk('own line: addressed = the broadcast 30 minutes ago, not the hub\'s own words', 1700 <= r['last_addressed_age_s'] <= 1900)
# an @name that only starts like the hub\'s is another one: @hub-90 is not @hub-9
stage('other-hub', roles, [(5, 'pace', '@hub-90 something for another hub')])
chk('@hub-90 does not address hub-9', snapshot('other-hub')['hub']['last_addressed_age_s'] is None)

# 3. the transcript: a silent journal and a transcript written 5 hours ago -> written 5 hours ago, via the transcript
transcript = root / 'claude' / 'projects' / 'proj' / f'{HUB_SID}.jsonl'
touch_ago(transcript, 5 * 3600)
stage('transcript', roles, [(20, 'pace', '@hub LIMIT URGENT')])
r = snapshot('transcript')['hub']
chk('transcript only: written 5 h ago via the transcript',
    r['last_written_via'] == 'transcript' and abs(r['last_written_age_s'] - 5 * 3600) < 120, r)
chk('transcript only: the journal age stays the journal\'s (none)', r['journal_age_s'] is None)
chk('transcript only: the address is still 20 minutes ago', 1100 <= r['last_addressed_age_s'] <= 1300)
text = once('transcript')
chk('--once: "wrote 5h00 ago (transcript), addressed 20m ago"', '* hub [hub-9] cli wrote 5h00 ago (transcript), addressed 20m ago' in text, text)
# the fresher one wins: a transcript written a minute ago beats a journal line from 10, a journal line beats an old transcript
stage('fresh-journal', roles, [(10, 'hub-9', 'a line of its own')])
chk('journal line (10 min) beats the 5 h transcript', snapshot('fresh-journal')['hub']['last_written_via'] == 'journal')
touch_ago(transcript, 60)
stage('fresh-transcript', roles, [(10, 'hub-9', 'a line of its own')])
r = snapshot('fresh-transcript')['hub']
chk('a transcript written a minute ago beats the journal line of 10', r['last_written_via'] == 'transcript' and r['last_written_age_s'] < 200)
# a worker role is not judged by a transcript (only a hub has no other sign of life)
touch_ago(root / 'claude' / 'projects' / 'proj' / 'aaaaaaaa-2222-4222-8222-222222222222.jsonl', 60)
stage('worker-transcript', {'hub': roles['hub'], 'w2': {'kind': 'cli', 'tag': 'w2', 'cli_session_id': 'aaaaaaaa-2222-4222-8222-222222222222'}}, [])
chk('a worker\'s transcript does not count', snapshot('worker-transcript')['w2']['last_written_age_s'] is None)

# 4. a Codex hub: the newest rollout of its thread
rollout = root / 'codex' / 'sessions' / '2026' / '10' / '27' / f'rollout-fixture-{CODEX_SID}.jsonl'
rollout.parent.mkdir(parents=True)
rollout.write_text(json.dumps({'timestamp': '2026-10-27T10:00:00Z', 'type': 'session_meta', 'payload': {'id': CODEX_SID, 'source': 'cli'}}) + '\n')
touch_ago(rollout, 7 * 3600)
stage('codex-hub', {'hub': {'kind': 'cli', 'tag': 'hub-4', 'cli_session_id': CODEX_SID, 'engine': 'codex'}}, [(5, 'pace', '@hub LIMIT')])
r = snapshot('codex-hub')['hub']
chk('a Codex hub: written 7 h ago via its rollout', r['last_written_via'] == 'transcript' and abs(r['last_written_age_s'] - 7 * 3600) < 120, r)

# 5. a dead session id: nothing to find, no invented number
stage('no-transcript', {'hub': {'kind': 'cli', 'tag': 'hub-5', 'cli_session_id': 'eeeeeeee-1111-4111-8111-111111111111', 'engine': 'claude'}}, [])
r = snapshot('no-transcript')['hub']
chk('a session without a transcript and a journal: no write, not zero', r['last_written_age_s'] is None and r['last_addressed_age_s'] is None)

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fail=1
exit $fail
