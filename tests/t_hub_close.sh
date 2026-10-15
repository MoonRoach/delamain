#!/bin/bash
# hub close: refusals (live agent, waiting owner question), the close itself (hub session stopped, locks released except
# one whose holder is live in another open stage, roles retired, journal line, stage.json mark), what a closed stage
# drops out of (agent-top, ask summary/list, the watchdog's stages), idle stages in agent-top, and the reopen by `hub start`.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
HUB=11111111-1111-4111-8111-111111111111; WK=22222222-2222-4222-8222-222222222222
AG=33333333-3333-4333-8333-333333333333; NEW=44444444-4444-4444-8444-444444444444
export CLAUDE_BIN=$T/fake_claude_bg.py FAKE_AGENTS=prev FAKE_PREV_SID=$HUB FAKE_BG_LOG=$(mktemp -d)/bg.log
python3 -c 'import os, time; os.setsid(); time.sleep(600)' $AG & SLEEPER=$!; disown $SLEEPER
trap 'kill $SLEEPER 2>/dev/null' EXIT
python3 - "$R" "$HUB" "$WK" "$AG" "$SLEEPER" <<'PY'
import json, os, sys, time
root, hub, wk, ag, pid = sys.argv[1:]
def roles(stage, recs):
    os.makedirs(f"{root}/{stage}", exist_ok=True)
    json.dump({"version": 1, "roles": recs, "retired": [], "sends": []}, open(f"{root}/{stage}/roles.json", "w"))
roles("shop", {"hub": {"session": hub, "cli_session_id": hub, "kind": "cli", "tag": "hub-3", "title": "Hub shop #3"},
               "worker": {"session": wk, "kind": "cli", "tag": "worker"}})
roles("web", {"hub": {"session": wk, "kind": "cli", "tag": "hub-1", "title": "Hub web #1"}})   # wk is live here too
os.makedirs(f"{root}/shop/agents/w1", exist_ok=True)
json.dump({"role": "w1", "pid": int(pid), "session_id": ag, "model": "sonnet", "started_at": "2026-10-14T10:00:00+00:00"},
          open(f"{root}/shop/agents/w1/meta.json", "w"))
open(f"{root}/shop/agents/w1/log.jsonl", "w").write("")
old = time.time() - 3 * 86400
os.utime(f"{root}/web/roles.json", (old, old))   # web: quiet for three days, no live agent -> idle
rows = [{"kind": "stage", "repo": "shop", "owner_name": "Hub shop #3", "session_id": hub, "until": "2099-12-31T23:59:00+00:00", "why": "shop staging"},
        {"kind": "deploy", "repo": "shop", "owner_name": "worker", "session_id": wk, "until": "2099-12-31T23:59:00+00:00", "why": "web deploy"},
        {"kind": "agent-lock", "repo": "shop", "owner_name": "w1", "session_id": ag, "until": "2099-12-31T23:59:00+00:00", "why": "w1 works"},
        {"kind": "stage", "repo": "other", "owner_name": "someone", "session_id": "99999999-9999-4999-8999-999999999999", "until": "2099-12-31T23:59:00+00:00", "why": "x"}]
open(f"{root}/board.md", "w").write("# b\n\n```locks\n" + "\n".join(json.dumps(r) for r in rows) + "\n```\n")
PY
Q=$($B/ask add --stage shop --blocks "launch" --default "launch on Monday" --due 2099-01-01T10:00 --by hub-3 "Launch on Monday?" | grep -o 'Q-[A-Z0-9]*-[0-9]*' | head -1)
check "${Q:+yes}" yes "fixture: a waiting owner question ($Q)"
locks(){ python3 - "$R/board.md" <<'PY'
import json, re, sys
t = open(sys.argv[1]).read()
print(" ".join(sorted(f"{r['kind']}/{r['repo']}" for r in (json.loads(l) for l in re.search(r"```locks\n(.*?)```", t, re.S).group(1).splitlines() if l.strip()))))
PY
}
field(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# 1. agent-top before: both stages shown, web idle, shop not (a live agent)
$B/agent-top --json > $R/top0.json; check $? 0 "agent-top --json"
check "$(field $R/top0.json 'd["stages"]')" "['shop', 'web']" "both stages listed"
check "$(field $R/top0.json 'd["stage_info"]["web"]["idle"]')" True "web is idle (quiet 3 days, no live agent)"
check "$(field $R/top0.json 'd["stage_info"]["shop"]["idle"], d["stage_info"]["shop"]["live"]')" "(False, 1)" "shop is not idle: one live agent"
check "$(field $R/top0.json 'd["closed_hidden"]')" "[]" "nothing hidden yet"

# 2. refusals: the live agent and the waiting question, both named; nothing written
before=$(snap $R)
$B/hub close --stage shop --why "shipped" > $R/c1.out 2> $R/c1err.out; check $? 2 "refused with a live agent and a waiting question"
grep -q "live agents: w1" $R/c1err.out && grep -q "agent stop --stage shop" $R/c1err.out; check $? 0 "…names the live agent and how to stop it"
grep -q "$Q" $R/c1err.out && grep -q "ask withdraw" $R/c1err.out; check $? 0 "…names the waiting question and how to resolve it"
check "$(snap $R)" "$before" "…and wrote nothing"
$B/hub close --stage nope > /dev/null 2>&1; check $? 2 "unknown stage refused"

# 3. dry run with --force: the plan, nothing written, the agent still runs
$B/hub close --stage shop --why "shipped" --force --dry-run > $R/dry.out 2>&1; check $? 0 "dry run exit 0"
head -1 $R/dry.out | grep -q "^\[plan\] close stage shop"; check $? 0 "…summary line first"
grep -q "agent stop --stage shop w1" $R/dry.out && grep -q "\[plan\] released lock stage (shop)" $R/dry.out; check $? 0 "…plans the stop and the release"
check "$(snap $R)" "$before" "…and wrote nothing"
kill -0 $SLEEPER 2>/dev/null; check $? 0 "…the agent still runs"

# 4. the question withdrawn, the close with --force stops the agent
$B/ask withdraw $Q --reason "launched anyway" > /dev/null; check $? 0 "question withdrawn"
$B/hub close --stage shop --why "shipped" --force > $R/c2.out 2>&1; check $? 0 "close exit 0"
head -1 $R/c2.out | grep -q "^closed stage shop: shipped"; check $? 0 "…summary line first"
sleep 0.5; kill -0 $SLEEPER 2>/dev/null; check $? 1 "…the live agent was stopped (agent stop)"
grep -q "stopped the stage's hub \"Hub shop #3\" (hub-3, sid 11111111, pid 4242) (\`claude stop 11111111\`" $R/c2.out
check $? 0 "…the idle background hub session was stopped"
check "$(locks)" "deploy/shop stage/other" "…the hub's and the stopped agent's locks released; the worker's (live in web) and a stranger's kept"
grep -q "kept lock deploy (shop): its holder worker — it is live in stage web" $R/c2.out; check $? 0 "…the kept lock is explained"
check "$(field $R/shop/roles.json 'sorted(d["roles"]), sorted(r["role"] for r in d["retired"])')" "([], ['hub', 'worker'])" "…every role retired"
grep -q "\[owner\] close: stage shop closed — shipped" $(journal shop); check $? 0 "…journal line by the owner"
check "$(field $R/shop/stage.json 'd["closed"]["why"], d["closed"]["hub"]')" "('shipped', 'hub-3')" "…stage.json closed record"

# 5. a closed stage drops out
$B/agent-top --json > $R/top1.json
check "$(field $R/top1.json 'd["stages"], d["closed_hidden"]')" "(['web'], ['shop'])" "agent-top hides the closed stage and says so"
$B/agent-top --json --all > $R/top2.json
check "$(field $R/top2.json 'd["stage_info"]["shop"]["closed"]["why"], d["stage_info"]["shop"]["idle"]')" "('shipped', False)" "--all shows it, closed and not idle"
$B/agent-top --json --stage shop > $R/top3.json
check "$(field $R/top3.json 'd["stages"]')" "['shop']" "a closed stage named by --stage is shown"
$B/agent-top --once --width 120 > $R/once.out 2>&1
grep -q "1 closed stage(s) hidden (a shows them): shop" $R/once.out && grep -q "web IDLE" $R/once.out; check $? 0 "--once: Stages block marks idle and hidden closed"
$B/ask add --stage shop --blocks "x" --default "y" --due 2099-01-01T10:00 --by owner "Late question?" > /dev/null
$B/ask summary | grep -q "^shop"; check $? 1 "ask summary leaves the closed stage out"
$B/ask list --stage shop | grep -q "Late question"; check $? 0 "…ask list --stage still reads it"
python3 - <<PY
import sys; sys.path.insert(0, "$B")
import importlib.machinery, importlib.util
l = importlib.machinery.SourceFileLoader("wd", "$B/watchdog"); m = importlib.util.module_from_spec(importlib.util.spec_from_loader("wd", l)); l.exec_module(m)
sys.exit(0 if m.stage_names() == ["web"] and m.stage_names("shop") == [] else 1)
PY
check $? 0 "the watchdog leaves the closed stage out"
$B/agent spawn --stage shop --role late --cwd "$R" --model sonnet --brief /dev/null > $R/sp.out 2>&1; check $? 2 "agent spawn into a closed stage refused"
grep -q "stage shop is closed" $R/sp.out; check $? 0 "…and says how to reopen it"
$B/hub close --stage shop > $R/c3.out 2>&1; check $? 0 "closing again is exit 0"
grep -q "already closed" $R/c3.out; check $? 0 "…and says when and why"

# 6. reopen: a new hub of the stage
$B/hub start --stage shop --session $NEW > $R/start.out 2>&1; check $? 0 "hub start on a closed stage"
grep -q "reopened the stage closed" $R/start.out; check $? 0 "…says it reopened it"
check "$(field $R/shop/stage.json '"closed" in d')" False "…the closed mark is gone"
grep -q "\[hub-4\] start: .*reopened the stage closed" $(journal shop); check $? 0 "…and the start line says so"
$B/agent-top --json > $R/top4.json
check "$(field $R/top4.json 'd["stages"]')" "['shop', 'web']" "agent-top lists it again"

# 7. a hub session another open stage still holds is not stopped; a Desktop hub is named in the first line
python3 - "$R" "$WK" "$HUB" <<'PY'
import json, os, sys
root, wk, hub = sys.argv[1:]
def roles(stage, recs, retired=()):
    os.makedirs(f"{root}/{stage}", exist_ok=True)
    json.dump({"version": 1, "roles": recs, "retired": list(retired), "sends": []}, open(f"{root}/{stage}/roles.json", "w"))
roles("twin", {"hub": {"session": wk, "kind": "cli", "tag": "hub-2", "title": "Hub twin #2"}})        # wk: also the hub of web
roles("desk", {"hub": {"session": "local_" + hub, "cli_session_id": hub, "kind": "desktop", "tag": "hub-5", "title": "Hub desk #5"}})
roles("retry", {}, [{"role": "hub", "session": "x", "tag": "hub-7", "retired_why": "stage closed: interrupted"}])  # a close that died mid-way
PY
$B/hub close --stage twin > $R/c4.out 2>&1; check $? 0 "close of a stage whose hub session is live in another stage"
grep -q "left the hub session $WK running: it is live in stage web" $R/c4.out; check $? 0 "…that session is not stopped"
$B/hub close --stage desk > $R/c5.out 2>&1; check $? 0 "close of a stage with a Desktop hub"
head -1 $R/c5.out | grep -q "^closed stage desk: .* ATTENTION: the stage's hub .* archive it in Desktop (local_$HUB)"; check $? 0 "…the first line says to archive the Desktop hub"
$B/hub close --stage retry > $R/c6.out 2>&1; check $? 0 "a re-run after a close that died after retiring the roles"
check "$(field $R/retry/stage.json 'd["closed"]["hub"]')" "hub-7" "…keeps the hub's tag from the retired record"
# 7b. a headless hub stopped by --force is not taken for a takeover; a retired agent's lock (a close that died after
# `agent stop`) is released
HL=55555555-5555-4555-8555-555555555555; S9=66666666-6666-4666-8666-666666666666
python3 -c 'import os, time; os.setsid(); time.sleep(600)' $HL & HPID=$!; disown $HPID
python3 - "$R" "$HL" "$HPID" "$S9" <<'PY'
import json, os, sys
root, hl, pid, s9 = sys.argv[1:]
os.makedirs(f"{root}/headless/agents/hub", exist_ok=True)
json.dump({"version": 1, "roles": {"hub": {"session": hl, "kind": "headless", "tag": "hub-2", "title": "Hub headless #2"}},
           "retired": [{"role": "w9", "session": s9, "kind": "headless", "tag": "w9", "retired_why": "agent-stop"}], "sends": []},
          open(f"{root}/headless/roles.json", "w"))
json.dump({"role": "hub", "pid": int(pid), "session_id": hl, "model": "opus"}, open(f"{root}/headless/agents/hub/meta.json", "w"))
open(f"{root}/headless/agents/hub/log.jsonl", "w").write("")
t = open(f"{root}/board.md").read().replace("\n```\n", f'\n{{"kind": "w9-lock", "repo": "headless", "owner_name": "w9", "session_id": "{s9}", "until": "2099-12-31T23:59:00+00:00", "why": "w9"}}\n```\n')
open(f"{root}/board.md", "w").write(t)
PY
$B/hub close --stage headless --force > $R/c8.out 2>&1; check $? 0 "close --force of a stage whose hub is a headless agent"
sleep 0.5; kill -0 $HPID 2>/dev/null; check $? 1 "…the headless hub was stopped"
check "$(field $R/headless/stage.json 'd["closed"]["hub"]')" "hub-2" "…and the stage is closed, not taken for a takeover"
grep -q "released lock w9-lock (headless)" $R/c8.out; check $? 0 "…a retired agent's lock is released"

# 8. an unreadable registry of another stage keeps the lock (its holder may be live there)
python3 - "$R" <<'PY'
import json, os, sys
root = sys.argv[1]
os.makedirs(f"{root}/solo", exist_ok=True); os.makedirs(f"{root}/broken", exist_ok=True)
json.dump({"version": 1, "roles": {"hub": {"session": "77777777-7777-4777-8777-777777777777", "kind": "cli", "tag": "hub-1"}}, "retired": [], "sends": []}, open(f"{root}/solo/roles.json", "w"))
open(f"{root}/broken/roles.json", "w").write("{not json")
t = open(f"{root}/board.md").read().replace("\n```\n", '\n{"kind": "solo-lock", "repo": "solo", "owner_name": "solo", "session_id": "77777777-7777-4777-8777-777777777777", "until": "2099-12-31T23:59:00+00:00", "why": "solo"}\n```\n')
open(f"{root}/board.md", "w").write(t)
PY
$B/hub close --stage solo > $R/c7.out 2>&1; check $? 0 "close with an unreadable registry elsewhere"
grep -q "kept lock solo-lock (solo): its holder hub — a registry of another stage could not be read" $R/c7.out; check $? 0 "…keeps the lock and says why"
check "$(locks)" "deploy/shop solo-lock/solo stage/other" "…the lock is still on the board"
exit $fail
