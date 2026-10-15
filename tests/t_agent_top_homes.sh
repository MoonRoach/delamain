#!/bin/bash
# agent-top shows the stages of every known hub home (the resolved one, ~/agent-hub, the registry of homes), not only the
# resolved home's. Isolated HOME and XDG_CONFIG_HOME; a project home (repo .agent-hub/config.json "project") next to the
# default one. Covers: both homes listed with their `home`; same-named stages stay two entries; one home prints what it
# printed before; a registry entry of a deleted home is dropped; a corrupt or unwritable registry costs nothing; `tell` and
# `agent status` hint at the home that has the stage while a new stage of the same name is still creatable; the stage guard
# for ~/agent-hub is unchanged. Each check has a negative control.
. "$(dirname "$0")/lib.sh"
export PYTHONDONTWRITEBYTECODE=1
S=$(mktemp -d); export HOME=$S/home XDG_CONFIG_HOME=$S/xdg AGENT_TOP_CACHE=0
mkdir -p $HOME $S/plain
unset AGENT_HUB_HOME
REG=$XDG_CONFIG_HOME/delamain/homes.json
H1=11111111-1111-4111-8111-111111111111; H2=22222222-2222-4222-8222-222222222222; H3=33333333-3333-4333-8333-333333333333; H4=44444444-4444-4444-8444-444444444444
mkdir -p $S/proj && (cd $S/proj && git init -q && mkdir .agent-hub && echo '{"AGENT_HUB_HOME": "project"}' > .agent-hub/config.json)
PH=$(cd $S/proj && python3 -c 'import os,sys; print(os.path.realpath(".agent-hub/local"))')
DH=$HOME/agent-hub
# mkagent HOME STAGE ROLE: a finished headless agent (an init and a result event), so the stage shows an agent row
mkagent(){ python3 - "$@" <<'PY'
import json, os, sys, time
home, stage, role = sys.argv[1:4]
d = os.path.join(home, stage, "agents", role)
os.makedirs(d, exist_ok=True)
json.dump({"role": role, "tag": role, "stage": stage, "session_id": "", "model": "sonnet", "engine": "claude", "title": role,
           "cwd": "/tmp", "dir": d, "started_at": "2026-10-15T10:00:00+00:00", "runs": []}, open(os.path.join(d, "meta.json"), "w"))
with open(os.path.join(d, "log.jsonl"), "w") as fh:
    fh.write(json.dumps({"type": "system", "subtype": "init", "session_id": "s"}) + "\n")
    fh.write(json.dumps({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "ok", "duration_ms": 1000}) + "\n")
PY
}
top_json(){ (cd "$1" && shift && $B/agent-top --json "$@" 2>/dev/null); }

# ---- (a) a stage in the default home and one in a project home: both listed, each with its home
(cd $S/plain && $B/roles set hub $H1 --tag hub-1 --stage alpha > /dev/null 2>&1); check $? 0 "a stage registered in the default home"
(cd $S/proj && $B/roles set hub $H2 --tag hub-1 --stage beta > /dev/null 2>&1); check $? 0 "a stage registered in the project home"
[ -f $REG ]; check $? 0 "the registry of homes exists (outside every home)"
mkagent $DH alpha w1; mkagent $PH beta w2
check_homes(){ python3 - "$1" "$DH" "$PH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); dh, ph = sys.argv[2:4]
info = d["stage_info"]
ok = (sorted(d["stages"]) == ["alpha", "beta · proj"]
      and info["alpha"]["home"].endswith("/home/agent-hub") and info["alpha"]["home_label"] == "" and info["alpha"]["name"] == "alpha"
      and info["beta · proj"]["home"].endswith("/proj/.agent-hub/local") and info["beta · proj"]["home_label"] == "proj"
      and info["beta · proj"]["name"] == "beta"
      and {h["label"] for h in d["homes"]} == {"", "proj"}
      and {a["stage"]: (a["stage_name"], a["home_label"]) for a in d["agents"]} == {"alpha": ("alpha", ""), "beta · proj": ("beta", "proj")})
print("ok" if ok else "bad: " + json.dumps(d["stages"]) + json.dumps(d["homes"]))
PY
}
top_json $S/plain > $S/a1.json; check "$(check_homes $S/a1.json)" ok "(a) --json from a plain directory lists both homes with the right home, name and label"
top_json $S/proj > $S/a2.json; check "$(check_homes $S/a2.json)" ok "(a) …and from inside the project the same two stages"
python3 - $REG "$PH" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
e = [h for h in reg["homes"] if h["path"] == sys.argv[2]]
ok = reg.get("version") == 1 and len(e) == 1 and e[0]["layer"] == "project" and e[0]["repo"] == sys.argv[2][:-len("/.agent-hub/local")] \
    and e[0]["first_seen"] and e[0]["last_seen"] and len(reg["homes"]) == 2
sys.exit(0 if ok else 1)
PY
check $? 0 "the registry entry: real path, layer project, the main checkout, first_seen and last_seen"
h1="$(cat $REG; ls -i $REG)"; (cd $S/plain && $B/roles set p1 $H3 --tag p-1 --stage alpha > /dev/null 2>&1); check "$(cat $REG; ls -i $REG)" "$h1" "a second registration changes nothing: the registry file is not rewritten (same inode, same bytes)"
$B/agent-top --json --stage alpha 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["stages"]))' > $S/a3.out; cat $S/a3.out > /dev/null
check "$(cd $S/plain && $B/agent-top --json --stage 'beta · proj' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stages"], len(d["agents"]))')" "['beta · proj'] 1" "--stage 'name · label' picks that stage of that home"
check "$(cd $S/plain && $B/agent-top --json --stage beta 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stages"], len(d["agents"]))')" "['beta · proj'] 1" "--stage with a bare name finds it in the other home"

# ---- (b) the same stage name in both homes: two entries
# (the stage guard refuses a stage that lives in ~/agent-hub from a project home, see (g): the fix it names is the directory)
mkdir -p $PH/alpha; (cd $S/proj && $B/roles set hub $H4 --tag hub-1 --stage alpha > /dev/null 2>&1); check $? 0 "a stage of an existing name registered in the project home too"
mkagent $PH alpha w3
top_json $S/plain > $S/b1.json
python3 - $S/b1.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = {x["stage"]: x for x in d["agents"]}
ok = (sorted(d["stages"]) == ["alpha", "alpha · proj", "beta · proj"] and a["alpha"]["role"] == "w1" and a["alpha · proj"]["role"] == "w3"
      and len(d["agents"]) == 3 and d["stage_info"]["alpha"]["home"] != d["stage_info"]["alpha · proj"]["home"]
      and set(d["roles"]) == {"alpha", "alpha · proj", "beta · proj"})
sys.exit(0 if ok else 1)
PY
check $? 0 "(b) two homes, one stage name: two stage records, two agents, two role lists, each in its own home"
(cd $S/plain && $B/agent-top --once --width 110 > $S/b2.txt 2>&1); grep -qE '^  alpha live' $S/b2.txt && grep -qE '^  alpha · proj live' $S/b2.txt; check $? 0 "(b) the text view names them apart: 'alpha' and 'alpha · proj'"
(cd $S/plain && $B/agent-top --widget > $S/b3.html 2>&1); grep -q 'alpha · proj/w3' $S/b3.html && grep -q 'alpha/w1' $S/b3.html; check $? 0 "(b) …and so does the widget"

# ---- (c) one home: the text and the JSON are what they were (the registry is not consulted for what it shows)
SC=$(mktemp -d); export HOME=$SC/home XDG_CONFIG_HOME=$SC/xdg; mkdir -p $HOME $SC/plain; DH=$HOME/agent-hub; REG=$XDG_CONFIG_HOME/delamain/homes.json
(cd $SC/plain && $B/roles set hub $H1 --tag hub-1 --stage solo > /dev/null 2>&1); mkagent $DH solo w1
# ages read in days and no clock in the header: two runs a second apart print the same picture
OLD=$(python3 -c 'import datetime as d; print((d.datetime.now()-d.timedelta(days=3)).strftime("%Y%m%d%H%M"))'); find $DH -exec touch -t $OLD {} +
once(){ (cd $SC/plain && $B/agent-top --once --all --width 100 2>&1 | sed -E '1s/[0-9]{2}:[0-9]{2}:[0-9]{2} *$//'); }
[ -f $REG ]; check $? 0 "(c) setup: the single home is registered"
once > $SC/c-with.txt; check "$(grep -c solo $SC/c-with.txt)" 3 "(c) --once with a registry (the stage in the header, the list and the Stages block)"
rm -f $REG
once > $SC/c-without.txt; check "$(grep -c solo $SC/c-without.txt)" 3 "(c) --once with no registry"
cmp -s $SC/c-with.txt $SC/c-without.txt; check $? 0 "(c) one home: the text is identical with and without the registry"
grep -qE '^  solo · |^. solo ·  ' $SC/c-with.txt; check $? 1 "(c) …and shows no home label"
grep -qE '^  solo IDLE +live 0 · last activity 3d ago' $SC/c-with.txt; check $? 0 "(c) …the stage line is the plain one"
top_json $SC/plain --all > $SC/c.json
python3 - $SC/c.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = (d["stages"] == ["solo"] and d["agents"][0]["stage"] == "solo" and list(d["stage_info"]) == ["solo"]
      and d["stage_info"]["solo"]["home_label"] == "" and len(d["homes"]) == 1 and d["homes"][0]["stages"] == ["solo"]
      and all(k in d for k in ("generated_at", "stages", "closed_hidden", "idle_after_s", "stage_info", "counts", "agents", "roles",
                               "spend", "locks", "questions", "questions_ok", "limits", "codex_limits", "limit_pace", "journal_tail")))
sys.exit(0 if ok else 1)
PY
check $? 0 "(c) one home: stage ids are the bare names, every field of before is still there, home and homes are added"
# a lone project home (nothing in ~/agent-hub): still one home, so the stage keeps its bare name; the label is in home_label only
SP=$(mktemp -d); export HOME=$SP/home XDG_CONFIG_HOME=$SP/xdg; mkdir -p $HOME $SP/lone
(cd $SP/lone && git init -q && mkdir .agent-hub && echo '{"AGENT_HUB_HOME": "project"}' > .agent-hub/config.json && $B/roles set hub $H1 --tag hub-1 --stage only > /dev/null 2>&1); check $? 0 "(c) setup: a project home and nothing else"
top_json $SP/lone > $SP/c2.json
check "$(python3 -c 'import json,sys; d=json.load(sys.stdin); i=d["stage_info"]["only"]; print(d["stages"], i["home_label"], d["multi_home"], len(d["homes"]))' < $SP/c2.json)" "['only'] lone False 1" "(c) one project home alone: the stage id is the bare name, the label is data only"
(cd $SP/lone && $B/agent-top --once --width 100 2>&1 | grep -c 'only · lone' > $SP/c2.n); check "$(cat $SP/c2.n)" 0 "(c) …and the text shows no label"
# back to the two-home setup of (a)/(b)
export HOME=$S/home XDG_CONFIG_HOME=$S/xdg; DH=$HOME/agent-hub; REG=$XDG_CONFIG_HOME/delamain/homes.json

# ---- (d) a registry entry whose home is gone is dropped, and costs nothing meanwhile
rm -rf $S/proj/.agent-hub/local
(cd $S/plain && $B/agent-top --json > $S/d1.json 2> $S/d1.err); check $? 0 "(d) a registered home that no longer exists: agent-top exits 0"
check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stages"])' $S/d1.json)" "['alpha']" "(d) …and lists only the homes that exist"
[ -s $S/d1.err ]; check $? 1 "(d) …without a word on stderr"
grep -q "$PH" $REG; check $? 0 "(d) the entry is still in the file until the next registration"
(cd $S/plain && $B/roles set p2 $H2 --tag p-2 --stage alpha > /dev/null 2>&1)
grep -q "$PH" $REG; check $? 1 "(d) the next registration drops the entry of the deleted home"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert [h["path"] for h in d["homes"]] == [sys.argv[2]], d' $REG "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' $DH)"; check $? 0 "(d) …and keeps the live one"

# ---- (e) a corrupt, unreadable or unwritable registry never fails a tool
echo '{"homes": [' > $REG
(cd $S/plain && $B/agent-top --json > $S/e1.json 2> $S/e1.err); check $? 0 "(e) corrupt registry: agent-top exits 0"
check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stages"])' $S/e1.json)" "['alpha']" "(e) …and shows the current home"
[ -s $S/e1.err ]; check $? 1 "(e) …silently"
(cd $S/plain && CLAUDE_CODE_SESSION_ID=$H1 $B/hub start --stage web --session $H1 > $S/e2.out 2> $S/e2.err); check $? 0 "(e) corrupt registry: hub start still succeeds"
[ "$(grep -c '^delamain:' $S/e2.err)" -le 1 ]; check $? 0 "(e) …with at most one stderr line about it"
check "$(cat $REG)" '{"homes": [' "(e) …and the file is left as it was (never overwritten blind)"
[ -f $DH/web/roles.json ]; check $? 0 "(e) …the stage is registered"
if [ "$(id -u)" != 0 ]; then
  rm -f $REG; (cd $S/plain && $B/roles set hub $H1 --tag hub-1 --stage alpha > /dev/null 2>&1); chmod 000 $REG
  (cd $S/plain && $B/agent-top --json > $S/e3.json 2> $S/e3.err); check $? 0 "(e) unreadable registry: agent-top exits 0"
  (cd $S/plain && $B/roles set p3 $H3 --tag p-3 --stage alpha > /dev/null 2>&1); check $? 0 "(e) …and roles set still succeeds"
  chmod 644 $REG
fi
if [ "$(id -u)" != 0 ]; then
  mkdir -p $S/ro && chmod 555 $S/ro
  (cd $S/plain && XDG_CONFIG_HOME=$S/ro $B/roles set p5 $H3 --tag p-5 --stage alpha > $S/e5.out 2> $S/e5.err); check $? 0 "(e) a read-only config directory: roles set still succeeds"
  [ "$(grep -c '^delamain:' $S/e5.err)" -le 1 ]; check $? 0 "(e) …with at most one stderr line"
  chmod 755 $S/ro
fi
echo x > $S/afile
(cd $S/plain && XDG_CONFIG_HOME=$S/afile $B/roles set p4 $H3 --tag p-4 --stage alpha > $S/e4.out 2> $S/e4.err); check $? 0 "(e) an unwritable registry location: roles set still succeeds"
[ "$(grep -c '^delamain:' $S/e4.err)" -le 1 ]; check $? 0 "(e) …with at most one stderr line"
rm -f $REG; (cd $S/proj && $B/roles set hub $H2 --tag hub-1 --stage beta > /dev/null 2>&1)   # the project home is back, registered afresh
(cd $S/plain && $B/roles set hub $H2 --tag hub-1 --stage alpha > /dev/null 2>&1)

# ---- (f) a stage of another registered home: a hint, never a new failure
mkdir -p $PH; mkagent $PH beta w2
(cd $S/plain && $B/tell beta "hello" > $S/f1.out 2> $S/f1.err); check $? 1 "(f) tell to a stage that exists only in another home fails as before (exit 1)"
grep -q "stage beta exists in home $PH; run from that project or set AGENT_HUB_HOME=$PH" $S/f1.err; check $? 0 "(f) …and names the home and how to reach it"
(cd $S/plain && $B/tell nowhere "hello" > $S/f2.out 2> $S/f2.err); check $? 1 "(f) negative: a stage that exists nowhere fails too"
grep -q "exists in home" $S/f2.err; check $? 1 "(f) …with no hint"
(cd $S/plain && $B/agent status --stage beta > $S/f3.out 2>&1); check $? 0 "(f) agent status of a stage of another home: exit 0 as before"
grep -q "stage beta exists in home $PH" $S/f3.out; check $? 0 "(f) …and the hint"
(cd $S/plain && $B/agent status --stage nowhere > $S/f4.out 2>&1); grep -q "exists in home" $S/f4.out; check $? 1 "(f) negative: no hint for a stage that exists nowhere"
(cd $S/plain && $B/hub close --stage beta > $S/f5.out 2> $S/f5.err); check $? 2 "(f) hub close of a stage of another home: refused as before (exit 2)"
grep -q "exists in home $PH" $S/f5.err; check $? 0 "(f) …with the hint"
(cd $S/plain && AGENT_HUB_HOME=$PH $B/tell beta --address > $S/f6.out 2>&1); check $? 0 "(f) control: with AGENT_HUB_HOME=<that home> the stage is found"
# a new stage of a name that exists in another project's home is creatable without any error
(cd $S/plain && $B/roles set hub $H1 --tag hub-1 --stage beta > $S/f7.out 2>&1); check $? 0 "(f) a same-named stage is creatable in this home (roles set)"
(cd $S/plain && CLAUDE_CODE_SESSION_ID=$H3 $B/hub start --stage beta2 --session $H3 > /dev/null 2>&1); check $? 0 "(f) hub start of a new stage in this home"
mkdir -p $PH/gamma2 && touch $PH/gamma2/roles.json
(cd $S/plain && CLAUDE_CODE_SESSION_ID=$H3 $B/hub start --stage gamma2 --session $H3 > $S/f8.out 2>&1); check $? 0 "(f) hub start of a stage whose name exists in a project's home: no error"

# ---- (g) the stage guard for ~/agent-hub stays what it was: a failure, not a hint
mkdir -p $DH/onlydefault/coordinator/work
(cd $S/proj && $B/jlog --stage onlydefault --tag t "x" > $S/g1.out 2> $S/g1.err); check $? 1 "(g) a stage that lives in ~/agent-hub, used from a project home: still a Failure"
grep -q "is not in the hub home $PH" $S/g1.err; check $? 0 "(g) …with the old message"
(cd $S/proj && $B/jlog --stage beta --tag t "x" > /dev/null 2>&1); check $? 0 "(g) control: a stage the project home has works"

# ---- (h) the TUI actions address a stage of another home by its own name, in its home
python3 - "$B" "$PH" <<'PY'
import importlib.machinery, importlib.util, os, sys, types
b, ph = sys.argv[1:3]
sys.path.insert(0, b)
loader = importlib.machinery.SourceFileLoader("agent_top_mod", os.path.join(b, "agent-top"))
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("agent_top_mod", loader))
loader.exec_module(mod)
coll = mod.Collector(None, False)
coll.snapshot()
ui = types.SimpleNamespace(coll=coll)
other = next(s for s in coll.where if s.endswith(" · proj"))
name, env = mod.App._stage_target(ui, other)
here, env_here = mod.App._stage_target(ui, "alpha")
ok = name == other.split(" · ")[0] and env.get("AGENT_HUB_HOME") == str(coll.where[other].home.path) \
    and here == "alpha" and env_here.get("AGENT_HUB_HOME") == os.environ.get("AGENT_HUB_HOME")
sys.exit(0 if ok else 1)
PY
check $? 0 "(h) a stage of another home: its own name and AGENT_HUB_HOME=<its home>; a stage of the current home: neither changes"
exit $fail
