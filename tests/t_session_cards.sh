#!/bin/bash
# session_cards hook: in a session registered as a stage's hub, Desktop's session cards (start_session with initiation
# own_initiative / offer) and forks (hand_off_to_session) are denied with the replacement named; user_asked and an
# accepted card (proposal_id) pass; nothing is denied outside a hub, with a missing or a corrupt registry. Every deny has
# an allow beside it that differs only in the rule's own input.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; export CLAUDE_SESSIONS_DIR=$R/sessions HUB_STAGE=stage-a
HOOK=$HOOKS/session_cards.py
HUB=11111111-1111-4111-8111-111111111111          # a terminal hub (cli id)
LOC=22222222-2222-4222-8222-222222222222          # a Desktop hub: local_ id …
LOCCLI=aaaaaaaa-2222-4222-8222-222222222222       # … and its current CLI session
WORKER=33333333-3333-4333-8333-333333333333
mkdir -p $CLAUDE_SESSIONS_DIR/a/b
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub stage-a #3","isArchived":false}' $LOC $LOCCLI > $CLAUDE_SESSIONS_DIR/a/b/local_$LOC.json

# hook TOOL INPUT-JSON SESSION [HOST]: the hook's stdout for one PreToolUse event
hook(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"session_id":sys.argv[3],"cwd":sys.argv[4],"tool_input":json.loads(sys.argv[2])}))' "$1" "$2" "$3" "$R" \
  | CLAUDE_CODE_HOST_SESSION_ID="${4:-}" python3 $HOOK pre-tool; }
denied(){ hook "$@" | grep -q '"permissionDecision": "deny"'; }
S=mcp__ccd_session__start_session; H=mcp__ccd_session__hand_off_to_session; SP=mcp__ccd_session__spawn_task

# Both registry lookup paths and the hook must delegate identity matching to hubcore.
python3 - "$B" "$HOOKS" <<'PYTEST'; check $? 0 "hook and registry share the session matcher"
import sys
sys.path[:0] = sys.argv[1:]
import hubcore as hc
import session_cards as cards
from unittest.mock import patch
from pathlib import Path
rec = {"session": "registered"}
assert hc.session_matches(rec, "registered", "")
assert not hc.session_matches(rec, "other", "")
with patch.object(hc, "session_matches", return_value=True) as match, \
     patch.object(hc, "roles_load", return_value={"roles": {"hub": rec}}), \
     patch.object(hc, "root", return_value=Path(sys.argv[1])), \
     patch.object(Path, "iterdir", return_value=iter([Path("stage-a")])), \
     patch.object(Path, "is_file", return_value=True):
    assert cards.is_hub("from-hook")
    assert match.call_args.args[1] == "from-hook"
    assert hc.role_for_session("stage-a", "from-registry")[0] == "hub"
    assert match.call_args.args[1] == "from-registry"
    with patch.object(hc, "session_id", return_value="from-caller"):
        assert hc.role_for_caller("stage-a")[0] == "hub"
    assert match.call_args.args[1] == "from-caller"
PYTEST

# ---- no registry at all: nobody is a hub, nothing is denied (and nothing is printed)
denied $S '{"initiation":"own_initiative","title":"x","prompt":"y"}' $HUB; check $? 1 "no registry: own_initiative passes"
check "$(hook $S '{"initiation":"own_initiative"}' $HUB | wc -c | tr -d ' ')" 0 "no registry: no output"

$B/roles set hub $HUB --kind cli --tag hub-3 >/dev/null; check $? 0 "register a terminal hub"
$B/roles set hub-d local_$LOC --tag hub-d >/dev/null; check $? 0 "register a Desktop session as a role (not the hub role)"
$B/roles --stage stage-b set hub local_$LOC --tag hub-4 >/dev/null; check $? 0 "register the Desktop session as the hub of stage-b"
$B/roles set builder $WORKER --kind headless --tag builder >/dev/null; check $? 0 "register an executor"

# ---- denied in a hub
denied $S '{"initiation":"own_initiative","title":"fix","prompt":"do it"}' $HUB; check $? 0 "hub: start_session own_initiative is denied"
denied $S '{"initiation":"offer","title":"fix","prompt":"do it"}' $HUB; check $? 0 "hub: start_session offer is denied"
denied $S '{"initiation":"Own_Initiative"}' $HUB; check $? 0 "hub: the initiation is compared without case"
denied $H '{"title":"fork","prompt":"continue"}' $HUB; check $? 0 "hub: hand_off_to_session is denied"
denied $H '{}' $HUB; check $? 0 "hub: hand_off_to_session with no arguments is denied"
denied $SP '{"title":"fix","prompt":"do it"}' $HUB; check $? 0 "hub: spawn_task (a task card) is denied"
out=$(hook $S '{"initiation":"own_initiative"}' $HUB)
for w in 'agent spawn' 'ask add' 'hub handoff' 'agent-top' 'context \\"fork\\"'; do echo "$out" | grep -q -- "$w"; check $? 0 "deny text names: $w"; done
check "$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"].splitlines()))')" 3 "deny text is at most 4 lines (3)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]=="PreToolUse" and d["permissionDecision"]=="deny"'; check $? 0 "deny output has the PreToolUse shape"

# ---- allowed in a hub: the owner's own words, an accepted card, and anything else of the tool
denied $S '{"initiation":"user_asked","title":"talk","prompt":"hi"}' $HUB; check $? 1 "hub: start_session user_asked passes"
denied $S '{"proposal_id":"p-123"}' $HUB; check $? 1 "hub: start_session with proposal_id passes"
denied $S '{"initiation":"own_initiative","proposal_id":"p-123"}' $HUB; check $? 1 "hub: a card accepted with proposal_id passes even with its initiation"
denied $S '{"title":"no initiation"}' $HUB; check $? 1 "hub: start_session without initiation is left to the app"
denied mcp__ccd_session__list_start_targets '{"initiation":"own_initiative"}' $HUB; check $? 1 "hub: another tool of the server is not this hook's"
check "$(hook $S '{"initiation":"user_asked"}' $HUB | wc -c | tr -d ' ')" 0 "hub: an allow prints nothing"

# ---- a Desktop hub: by its local_ id and the CLI session Desktop's record names
denied $S '{"initiation":"offer"}' $LOCCLI "local_$LOC"; check $? 0 "Desktop hub: denied by host id + Desktop's record of its CLI session"
denied $S '{"initiation":"offer"}' $WORKER "local_$LOC"; check $? 1 "negative: a child that only inherited the host id is not the hub"
denied $S '{"initiation":"offer"}' $LOCCLI ""; check $? 0 "Desktop hub: its registered CLI session is found without the host id"
RESTART=bbbbbbbb-2222-4222-8222-222222222222       # the CLI restarted under the same local_ id: Desktop's record names it
python3 - "$CLAUDE_SESSIONS_DIR/a/b/local_$LOC.json" $RESTART <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["cliSessionId"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
denied $S '{"initiation":"offer"}' $RESTART "local_$LOC"; check $? 0 "Desktop hub after a CLI restart: denied by host id + Desktop's record"
denied $S '{"initiation":"offer"}' $RESTART ""; check $? 1 "negative: …but not without the host id"
denied $S '{"initiation":"offer"}' $RESTART "local_99999999-9999-4999-8999-999999999999"; check $? 1 "negative: another host id"
denied $S '{"initiation":"offer"}' $WORKER "local_$LOC"; check $? 1 "negative: a child that only inherited the host id is not the hub"

# ---- not a hub
denied $S '{"initiation":"own_initiative"}' $WORKER; check $? 1 "executor (registered, not the hub role): passes"
denied $H '{}' $WORKER; check $? 1 "executor: hand_off_to_session passes"
denied $SP '{"title":"fix"}' $WORKER; check $? 1 "executor: spawn_task passes"
denied $S '{"initiation":"own_initiative"}' 44444444-4444-4444-8444-444444444444; check $? 1 "unregistered session: passes"
denied $H '{}' ""; check $? 1 "no session id: passes"
$B/roles retire hub >/dev/null; check $? 0 "retire the hub role"
denied $S '{"initiation":"own_initiative"}' $HUB; check $? 1 "a retired hub: passes"
denied $S '{"initiation":"own_initiative"}' $LOCCLI "local_$LOC"; check $? 0 "control: the same Desktop session is still the hub of stage-b"

# ---- a corrupt or unreadable registry never blocks
echo '{not json' > $R/stage-b/roles.json
denied $S '{"initiation":"own_initiative"}' $LOCCLI "local_$LOC"; check $? 1 "corrupt registry: passes"
$B/roles set hub $HUB --kind cli --tag hub-3 >/dev/null
mkdir -p $R/aaa-bad; echo '{not json' > $R/aaa-bad/roles.json   # sorts before stage-a: read first
denied $S '{"initiation":"own_initiative"}' $HUB; check $? 0 "control: a readable registry beside a corrupt one read earlier still finds the hub"
echo '[1, 2]' > $R/stage-a/roles.json
denied $S '{"initiation":"own_initiative"}' $HUB; check $? 1 "registry of the wrong shape: passes"
rm -rf $R/stage-a $R/stage-b $R/aaa-bad
denied $S '{"initiation":"own_initiative"}' $HUB; check $? 1 "registry gone: passes"
echo 'garbage' | python3 $HOOK pre-tool; check $? 0 "garbage on stdin: exit 0"
python3 $HOOK pre-tool < /dev/null; check $? 0 "empty stdin: exit 0"
( export AGENT_HUB_HOME=/nonexistent/hub-home; denied $S '{"initiation":"own_initiative"}' $HUB ); check $? 1 "missing hub home: passes"

# ---- SessionStart: the context line, only in a hub
new_home; R=$AGENT_HUB_HOME; export CLAUDE_SESSIONS_DIR=$R/sessions
$B/roles set hub $HUB --kind cli --tag hub-3 >/dev/null
ss(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SessionStart","session_id":sys.argv[1],"cwd":sys.argv[2]}))' "$1" "$R" | python3 $HOOK session-start; }
out=$(ss $HUB); echo "$out" | grep -q 'superseded'; check $? 0 "SessionStart: a hub gets the line"
echo "$out" | grep -q '"hookEventName": "SessionStart"'; check $? 0 "SessionStart: the output has the SessionStart shape"
echo "$out" | grep -q 'agent spawn' && echo "$out" | grep -q 'ask add' && echo "$out" | grep -q 'wrap_up'; check $? 0 "SessionStart: the line names agent spawn, ask add and wrap_up"
check "$(ss $WORKER | wc -c | tr -d ' ')" 0 "SessionStart: a non-hub hears nothing"

# ---- `hub start` / `hub takeover` carry the same line in their digest (Claude host), not on Codex
$B/hub start --stage digest-a --goal "digest check" --session $WORKER > $R/start.out 2>&1; check $? 0 "hub start runs"
grep -q 'Desktop.s follow-up-card rules are superseded' $R/start.out; check $? 0 "hub start digest has the line"
rm -rf $R/digest-a; CODEX_THREAD_ID=thread-1 $B/hub start --stage digest-b --goal "digest check" --session $WORKER > $R/start-codex.out 2>&1
grep -q 'follow-up-card rules' $R/start-codex.out; check $? 1 "negative: a Codex hub's digest does not carry it"

# ---- hooks.json wires both events to this script
python3 - "$T/../hooks/hooks.json" <<'PY'; check $? 0 "hooks.json: session_cards on SessionStart and on the Desktop tools"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
def has(event, matcher, tail):
    return any(g.get("matcher") == matcher and any(h["command"].endswith(tail) for h in g["hooks"]) for g in hooks[event])
assert has("SessionStart", None, 'session_cards.py" session-start')
assert has("PreToolUse", "mcp__ccd_session__start_session|mcp__ccd_session__hand_off_to_session|mcp__ccd_session__spawn_task", 'session_cards.py" pre-tool')
PY
exit $fail
