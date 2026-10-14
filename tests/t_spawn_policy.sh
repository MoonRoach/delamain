#!/bin/bash
# Spawn policy (bin/spawn_policy.py): the default effort per model, a reason for an effort or a model above the default
# (warning, refusal, off), the same for Codex, the resume limit of `agent send`, the agent's title from the brief's
# first heading, the no-plan warning. Stand-in CLIs only; no model is called.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; printf '# Brief: refactor the parser — phase 2\n\nbody\n' > $W/b.md
meta(){ python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print($2)" $R/stage-a/agents/$1/meta.json; }
wait_dead(){ for i in $(seq 1 60); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.25; done; }
spawn(){ local r=$1; shift; $B/agent spawn --role $r --cwd $W --brief $W/b.md "$@" > $R/$r.out 2> $R/$r.err; }
last_argv(){ tail -1 $W/argv.log; }
$B/ask plan --stage stage-a "plan for the tests" > /dev/null

# ---- 1. the default effort per model
export AGENT_HUB_EFFORT_DEFAULTS='{"opus": "medium", "sonnet": "xhigh"}' AGENT_HUB_DEFAULT_EFFORT=low
spawn d1 --model opus; check $? 0 "spawn opus"; wait_dead d1
last_argv | grep -q -- '--effort medium'; check $? 0 "AGENT_HUB_EFFORT_DEFAULTS: a plain word matches the model, its effort is used"
spawn d2 --model sonnet --reason "long careful change"; wait_dead d2
last_argv | grep -q -- '--effort xhigh'; check $? 0 "…another model, another default"
spawn d3 --model fable; wait_dead d3
last_argv | grep -q -- '--effort low'; check $? 0 "a model without an entry falls back to AGENT_HUB_DEFAULT_EFFORT"
spawn d4 --model opus --effort high; wait_dead d4
last_argv | grep -q -- '--effort high'; check $? 0 "--effort beats the default of the model"
AGENT_HUB_MODEL_MAP=fast=claude-opus-x-y spawn d5 --model fast; wait_dead d5
last_argv | grep -q -- '--effort medium'; check $? 0 "a key matches the id an alias maps to"
unset AGENT_HUB_DEFAULT_EFFORT
spawn d6 --model fable; wait_dead d6
last_argv | grep -q -- '--effort high'; check $? 0 "no setting at all: high"
AGENT_HUB_EFFORT_DEFAULTS='{"opus": "turbo"}' spawn d7 --model opus; check $? 2 "negative: a default that is not an effort level is a usage error"
grep -q 'AGENT_HUB_EFFORT_DEFAULTS' $R/d7.err; check $? 0 "…naming the setting"
AGENT_HUB_EFFORT_DEFAULTS='[1]' spawn d8 --model opus; check $? 0 "a setting of the wrong shape is ignored (and reported), the spawn goes on"
grep -q 'JSON object' $R/d8.err; check $? 0 "…with a note"; wait_dead d8
unset AGENT_HUB_EFFORT_DEFAULTS
# haiku decides its effort by the same path as every model: --effort, else its AGENT_HUB_EFFORT_DEFAULTS entry, else
# AGENT_HUB_DEFAULT_EFFORT, else high (Haiku 5.5 has the setting; Haiku 4.5 takes the flag)
export AGENT_HUB_EFFORT_DEFAULTS='{"haiku": "high"}' AGENT_HUB_DEFAULT_EFFORT=medium
spawn h1 --model haiku; check $? 0 "spawn haiku"; wait_dead h1
last_argv | grep -q -- '--model haiku --effort high'; check "$? $(meta h1 'm["effort"]')" "0 high" "haiku: its AGENT_HUB_EFFORT_DEFAULTS entry is the effort passed and recorded"
spawn h2 --model haiku --effort medium; wait_dead h2
last_argv | grep -q -- '--model haiku --effort medium'; check $? 0 "haiku: --effort beats the entry"
AGENT_HUB_EFFORT_DEFAULTS='{"opus": "xhigh"}' spawn h3 --model haiku; wait_dead h3
last_argv | grep -q -- '--model haiku --effort medium'; check $? 0 "haiku: an entry of another model is not its own — AGENT_HUB_DEFAULT_EFFORT"
AGENT_HUB_MODEL_MAP=quick=claude-haiku-5-5 spawn h4 --model quick; wait_dead h4
last_argv | grep -q -- '--model claude-haiku-5-5 --effort high'; check $? 0 "haiku: a key matches the id an alias maps to"
unset AGENT_HUB_EFFORT_DEFAULTS AGENT_HUB_DEFAULT_EFFORT
spawn h5 --model haiku; wait_dead h5
last_argv | grep -q -- '--model haiku --effort high'; check $? 0 "haiku: no setting at all: high"

# ---- 1b. a resume gives an agent with no effort on record (spawned before haiku took one: `effort: null`) the effort a
# spawn would, checks it against the effort rules like a spawn, and records it; an effort on record is kept
nulleffort(){ python3 -c "import json,sys; f=sys.argv[1]; m=json.load(open(f)); m['effort']=None; json.dump(m, open(f,'w'))" $R/stage-a/agents/$1/meta.json; }
spawn lg1 --model haiku; wait_dead lg1; nulleffort lg1
check "$(meta lg1 'm["effort"]')" None "legacy meta: a haiku agent with effort null"
AGENT_HUB_EFFORT_DEFAULTS='{"haiku": "medium"}' $B/agent send lg1 "again" > $R/lg1.out 2>&1; check $? 0 "resume of the legacy agent"; wait_dead lg1
last_argv | grep -q -- '--resume .* --model haiku --effort medium'; check $? 0 "…passes the effort a spawn would: its AGENT_HUB_EFFORT_DEFAULTS entry"
check "$(meta lg1 'm["effort"]')" medium "…and records it"
spawn lg2 --model haiku; wait_dead lg2; nulleffort lg2
$B/agent send lg2 "again" > $R/lg2.out 2>&1; check $? 0 "resume of a legacy agent with no setting at all"; wait_dead lg2
last_argv | grep -q -- '--resume .* --model haiku --effort high'; check "$? $(meta lg2 'm["effort"]')" "0 high" "…high, passed and recorded"
spawn lg3 --model haiku --effort medium; wait_dead lg3
AGENT_HUB_EFFORT_DEFAULTS='{"haiku": "xhigh"}' $B/agent send lg3 "again" > /dev/null 2>&1; wait_dead lg3
last_argv | grep -q -- '--resume .* --model haiku --effort medium'; check "$? $(meta lg3 'm["effort"]')" "0 medium" "control: an effort on record is kept, not replaced by the defaults"
spawn lg4 --model haiku; wait_dead lg4; nulleffort lg4
runs=$(wc -l < $W/argv.log); inbox=$(wc -l < $R/stage-a/agents/lg4/inbox.md)
AGENT_HUB_EFFORT_RULES='{"haiku": "medium|xhigh"}' $B/agent send lg4 "again" > $R/lg4.out 2>&1; check $? 2 "negative: the effort rules refuse the effort the legacy agent would get (high)"
grep -q 'haiku runs only at effort medium or xhigh' $R/lg4.out; check $? 0 "…naming the rule"
check "$(wc -l < $W/argv.log):$(wc -l < $R/stage-a/agents/lg4/inbox.md):$(meta lg4 'm["effort"]')" "$runs:$inbox:None" "…nothing was resumed, queued or recorded"
AGENT_HUB_EFFORT_RULES='{"haiku": "high"}' $B/agent send lg4 "again" > /dev/null 2>&1; check $? 0 "positive control: a rule that allows high lets the same resume through"; wait_dead lg4

# ---- 2. a reason above the default (default policy: warn)
spawn r1 --model opus --effort xhigh; check $? 0 "above the default without a reason: spawn goes on"
grep -q 'effort xhigh is above the default high.*--reason' $R/r1.err; check $? 0 "…with one warning naming the effort and the flag"
[ "$(grep -c 'above the default' $R/r1.err)" = 1 ]; check $? 0 "…exactly one line"
check "$(meta r1 'm.get("reason")')" None "…no reason on record"; wait_dead r1
spawn r2 --model opus --effort xhigh --reason "cross-module refactor, medium missed it twice"; check $? 0 "above the default with a reason"
grep -q 'above the default' $R/r2.err; check $? 1 "negative: no warning when a reason is given"
check "$(meta r2 'm["reason"]')" "cross-module refactor, medium missed it twice" "the reason is in meta.json"
grep 'started headless agent r2' $(journal stage-a) | grep -q 'reason: cross-module refactor, medium missed it twice'; check $? 0 "…and in the journal start line"
wait_dead r2
spawn r3 --model opus --effort high; grep -q 'above the default' $R/r3.err; check $? 1 "negative: the default effort itself needs no reason"; wait_dead r3
spawn r4 --model haiku --effort max; grep -q 'effort max is above the default high.*--reason' $R/r4.err; check $? 0 "haiku: an effort above the default needs a reason like any model (positive control)"; wait_dead r4
spawn r4b --model haiku --effort high; grep -q 'above the default' $R/r4b.err; check $? 1 "negative: haiku at the default effort needs none"; wait_dead r4b
AGENT_HUB_REASON_POLICY=refuse spawn r5 --model opus --effort max; check $? 2 "policy refuse: above the default without a reason is refused"
grep -q 'above the default' $R/r5.err; check $? 0 "…saying why"
[ ! -e $R/stage-a/agents/r5 ]; check $? 0 "…and nothing was started"
AGENT_HUB_REASON_POLICY=refuse spawn r6 --model opus --effort max --reason "needed"; check $? 0 "policy refuse: accepted with a reason"; wait_dead r6
AGENT_HUB_REASON_POLICY=refuse spawn r7 --model opus --effort high; check $? 0 "policy refuse: the default needs no reason"; wait_dead r7
AGENT_HUB_REASON_POLICY=off spawn r8 --model opus --effort max; grep -q 'above the default' $R/r8.err; check $? 1 "policy off: no warning"; wait_dead r8
AGENT_HUB_REASON_POLICY=sometimes spawn r9 --model opus; check $? 2 "negative: an unknown policy is a usage error"
AGENT_HUB_EFFORT_DEFAULTS='{"opus": "xhigh"}' spawn r10 --model opus --effort xhigh; grep -q 'above the default' $R/r10.err; check $? 1 "the default of the model is the yardstick: xhigh is not above it"; wait_dead r10
# a model above the default
export AGENT_HUB_REASON_MODELS='["fable"]'
spawn m1 --model fable; check $? 0 "AGENT_HUB_REASON_MODELS: spawn goes on"
grep -q 'model fable is above the default' $R/m1.err; check $? 0 "…with a warning for a listed model without a reason"; wait_dead m1
spawn m2 --model fable --reason "judgement on a design"; grep -q 'above the default' $R/m2.err; check $? 1 "…none with a reason"; wait_dead m2
spawn m3 --model opus; grep -q 'above the default' $R/m3.err; check $? 1 "negative: a model not on the list needs none"; wait_dead m3
AGENT_HUB_REASON_POLICY=refuse spawn m4 --model fable; check $? 2 "policy refuse: a listed model without a reason is refused"
unset AGENT_HUB_REASON_MODELS
# config.json: a repository may set the defaults but not loosen the user's limits
mkdir -p $W/.git $W/.agent-hub
echo '{"AGENT_HUB_EFFORT_DEFAULTS": {"opus": "low"}, "AGENT_HUB_REASON_POLICY": "off"}' > $W/.agent-hub/config.json
spawn c1 --model opus --effort medium; check $? 0 "repository config.json spawn"
last_argv | grep -q -- '--effort medium'; check $? 0 "…"; wait_dead c1
grep -q 'AGENT_HUB_REASON_POLICY is not a setting' $R/c1.err; check $? 0 "a repository cannot set the reason policy (hub home only)"
grep -q 'effort medium is above the default low' $R/c1.err; check $? 0 "…but its per-model default counts"
rm -rf $W/.agent-hub $W/.git

# ---- 3. Codex follows the same policy
export AGENT_HUB_EFFORT_DEFAULTS='{"fixture": "low"}'
spawn x1 --engine codex --model gpt-fixture; check $? 0 "codex spawn"; wait_dead x1
grep -q 'model_reasoning_effort=.*low' $W/codex-argv.jsonl; check $? 0 "codex: the default effort of the model applies"
spawn x2 --engine codex --model gpt-fixture --effort xhigh; grep -q 'effort xhigh is above the default low' $R/x2.err; check $? 0 "codex: above the default without a reason warns"; wait_dead x2
spawn x3 --engine codex --model gpt-fixture --effort xhigh --reason "hard diagnosis"; grep -q 'above the default' $R/x3.err; check $? 1 "codex: negative: a reason silences it"
check "$(meta x3 'm["reason"]')" "hard diagnosis" "codex: the reason is in meta.json"; wait_dead x3
AGENT_HUB_REASON_POLICY=refuse spawn x4 --engine codex --model gpt-fixture --effort max; check $? 2 "codex: policy refuse"
unset AGENT_HUB_EFFORT_DEFAULTS

# a Codex spawn without --model: the model the CLI will choose is unknown, the plugin does not read the Codex config
export CODEX_HOME=$R/codexhome; mkdir -p $CODEX_HOME
printf 'model = "gpt-6-big"\n' > $CODEX_HOME/config.toml   # present, and deliberately not read
export AGENT_HUB_REASON_MODELS='["big"]'
spawn y1 --engine codex; check $? 0 "codex without --model, REASON_MODELS set, policy warn: spawn goes on"
grep -q 'cannot be checked: pass --model' $R/y1.err && grep -q 'check skipped' $R/y1.err; check $? 0 "…with a warning that the model check was skipped"
[ "$(grep -c 'cannot be checked' $R/y1.err)" = 1 ]; check $? 0 "…exactly one"
grep -q 'model gpt-6-big' $R/y1.err; check $? 1 "negative: the Codex config file is not guessed at"; wait_dead y1
AGENT_HUB_REASON_POLICY=refuse spawn y2 --engine codex; check $? 2 "policy refuse: refused"
grep -q 'the model the Codex CLI will choose cannot be checked: pass --model' $R/y2.err; check $? 0 "…saying to pass --model"
[ ! -e $R/stage-a/agents/y2 ]; check $? 0 "…nothing was started"
AGENT_HUB_REASON_POLICY=refuse spawn y3 --engine codex --reason "needed"; check $? 2 "…a reason does not make the model known"
AGENT_HUB_REASON_POLICY=refuse spawn y4 --engine codex --model gpt-fixture; check $? 0 "a given --model is checked and fine"; wait_dead y4
AGENT_HUB_REASON_POLICY=off spawn y5 --engine codex; check $? 0 "policy off: nothing is checked"; wait_dead y5
AGENT_HUB_EFFORT_DEFAULTS='{"big": "low"}' spawn y6 --engine codex; wait_dead y6
tail -1 $W/codex-argv.jsonl | grep -qF 'model_reasoning_effort=\"high\"'; check $? 0 "the effort default of an unknown model is the general one"
unset AGENT_HUB_REASON_MODELS
AGENT_HUB_REASON_POLICY=refuse spawn y7 --engine codex; check $? 0 "REASON_MODELS empty (the default): nothing changes"; wait_dead y7
spawn y8 --engine codex; grep -q 'cannot be checked' $R/y8.err; check $? 1 "…and no warning"; wait_dead y8
export CODEX_HOME="$(mktemp -d)"   # back to an empty one: the limit-pace reader must not see the real ~/.codex

# ---- 4. the resume limit
spawn s1 --model haiku; wait_dead s1
ctx(){ local sub=${3:-}; python3 -c "
import json,sys
with open(sys.argv[1], 'a') as f:
    ev = {'type': 'assistant', 'message': {'id': 'm$2', 'content': [], 'usage': {'input_tokens': 10, 'cache_read_input_tokens': $2, 'cache_creation_input_tokens': 0}}}
    if len(sys.argv) > 2: ev['parent_tool_use_id'] = 'toolu_1'
    f.write(json.dumps(ev) + '\n')" $R/stage-a/agents/$1/log.jsonl $sub; }
ctx s1 100000
$B/agent status s1 | grep -q 'ctx 100k'; check $? 0 "status shows the context size"
runs(){ meta s1 'len(m["runs"])'; }
N=$(runs); $B/agent send s1 "task below the limit" > $R/rs1.out 2>&1; check $? 0 "resume below the limit"; wait_dead s1
check "$(runs)" $((N + 1)) "…started a run"
ctx s1 300000
$B/agent status s1 | grep -q 'ctx 300k'; check $? 0 "status shows the last context"
N=$(runs); $B/agent send s1 "a new task above the limit" > $R/rs2.out 2>&1; check $? 1 "resume above the limit is refused"
grep -q 'fresh agent from a handoff file' $R/rs2.out && grep -q '300k' $R/rs2.out && grep -q -- '--resume-anyway' $R/rs2.out; check $? 0 "…with the advice, the size and the override"
check "$(runs)" "$N" "…no run was started"
grep -q 'a new task above the limit' $R/stage-a/agents/s1/inbox.md; check $? 1 "…and the message was not queued"
AGENT_HUB_RESUME_MAX_CTX=400k $B/agent send s1 "limit raised" > $R/rs3.out 2>&1; check $? 0 "AGENT_HUB_RESUME_MAX_CTX raises the limit"; wait_dead s1
ctx s1 300000
AGENT_HUB_RESUME_MAX_CTX=0 $B/agent send s1 "no limit" > $R/rs4.out 2>&1; check $? 0 "AGENT_HUB_RESUME_MAX_CTX=0: no limit"; wait_dead s1
ctx s1 300000
$B/agent send s1 --resume-anyway "override" > $R/rs5.out 2>&1; check $? 0 "--resume-anyway overrides"; wait_dead s1
ctx s1 300000
$B/agent send --resume-anyway s1 "flag first" > $R/rs5b.out 2>&1; check $? 0 "--resume-anyway before the role works too"; wait_dead s1
$B/agent send --stage --bogus --stage stage-a s1 "x" > $R/rs5g.out 2>&1; check $? 2 "--stage followed by a flag is an argument error"
grep -q 'needs a stage name' $R/rs5g.out; check $? 0 "…saying so"
$B/agent send --stage=-x s1 "x" > /dev/null 2>&1; check $? 2 "--stage=-x too"
$B/agent send --nonsense s1 "x" > $R/rs5c.out 2>&1; check $? 2 "negative: an unknown option before the role is a usage error"
ctx s1 300000
$B/agent send s1 --resume-anyway -- -dashed-text > $R/rs5d.out 2>&1; check $? 0 "after --: a word that starts with a dash is the message"; wait_dead s1
grep -qx -- '.*-dashed-text.*' $W/prompts.log; check $? 0 "…and reaches the agent"
ctx s1 300000
$B/agent send s1 --resume-anyway "- please fix" > $R/rs5e.out 2>&1; check $? 0 "a message that starts with '- ' after the flag is accepted"; wait_dead s1
grep -q -- '- please fix' $W/prompts.log; check $? 0 "…and reaches the agent"
ctx s1 300000
$B/agent send s1 --resume-anyway --odd-word "x" > $R/rs5f.out 2>&1; check $? 0 "after the role even a word that looks like an option is the message"; wait_dead s1
grep -q -- '--odd-word x' $W/prompts.log; check $? 0 "…and reaches the agent"
ctx s1 900000 sub   # a sub-agent's call (parent_tool_use_id) is not this agent's context
python3 - $R/stage-a/agents/s1/log.jsonl <<'PY'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
ev = json.loads(lines[-1]); ev["parent_tool_use_id"] = "toolu_1"; lines[-1] = json.dumps(ev)
lines.insert(len(lines) - 1, json.dumps({"type": "assistant", "message": {"id": "main", "content": [], "usage": {"input_tokens": 5000}}}))
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
$B/agent send s1 "sub-agent context ignored" > $R/rs6.out 2>&1; check $? 0 "a sub-agent's context does not count"; wait_dead s1
# one liveness reading per send: a process that dies right after the first reading must not slip a resume past the limit
ctx s1 300000
python3 - $B $R <<'PY'
import importlib.machinery, importlib.util, sys, os
bindir, home = sys.argv[1:3]
sys.path.insert(0, bindir)
loader = importlib.machinery.SourceFileLoader("agent_cli", os.path.join(bindir, "agent"))
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("agent_cli", loader)); loader.exec_module(mod)
readings, launched = [], []
def alive(meta):
    readings.append(1)
    return len(readings) <= 2          # alive for the first two readings, gone afterwards
mod.alive = alive
mod.launch = lambda *a, **k: launched.append(1) or 4242
rc = None
try:
    with __import__("contextlib").redirect_stdout(__import__("io").StringIO()):
        mod._send_locked("stage-a", __import__("argparse").Namespace(role="s1", text=["x"], stage=None, resume_anyway=False), "x")
except Exception as e:
    rc = e
assert not launched, "a 300k agent was resumed without --resume-anyway"
print("ok")
PY
check $? 0 "a process that dies between liveness readings is not resumed past the limit"
AGENT_HUB_RESUME_MAX_CTX=lots $B/agent send s1 "x" > $R/rs7.out 2>&1; check $? 2 "negative: a bad limit is a usage error"
$B/agent spawn --role s2 --cwd $W --brief $W/b.md --model haiku > /dev/null; wait_dead s2
$B/agent send s2 "unknown context resumes" > /dev/null 2>&1; check $? 0 "a log without context numbers is not refused"; wait_dead s2

# ---- 5. the title
check "$(meta d1 'm["title"]')" "d1 — refactor the parser — phase 2 (stage-a)" "title: <role> — first heading without 'Brief:' (<stage>)"
grep -q -- '-n d1 — refactor the parser — phase 2 (stage-a)' $W/argv.log; check $? 0 "…is the session name passed to the CLI"
check "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['roles']['d1']['title'])" $R/stage-a/roles.json)" "d1 — refactor the parser — phase 2 (stage-a)" "…and the title of the role"
printf 'no heading here\n' > $W/plain.md
$B/agent spawn --role t2 --cwd $W --brief $W/plain.md --model haiku > /dev/null 2>&1; wait_dead t2
check "$(meta t2 'm["title"]')" "agent t2 (stage-a)" "a brief without a heading keeps the old title"
printf '```\n# not a heading\n```\n## Real one\n' > $W/fenced.md
$B/agent spawn --role t3 --cwd $W --brief $W/fenced.md --model haiku > /dev/null 2>&1; wait_dead t3
check "$(meta t3 'm["title"]')" "t3 — Real one (stage-a)" "a heading inside a code fence is skipped"
python3 -c "print('# Brief: ' + 'very long ' * 30)" > $W/long.md
$B/agent spawn --role t4 --cwd $W --brief $W/long.md --model haiku > /dev/null 2>&1; wait_dead t4
python3 -c "
import json,sys; t=json.load(open(sys.argv[1]))['title']; assert t.startswith('t4 — very long') and t.endswith('… (stage-a)') and len(t) <= 90, t" $R/stage-a/agents/t4/meta.json
check $? 0 "a long heading is trimmed"
$B/agent spawn --role t5 --cwd $W --brief $W/b.md --model haiku --title "my own" > /dev/null 2>&1; wait_dead t5
check "$(meta t5 'm["title"]')" "my own" "--title still wins"

printf -- '---\n# a yaml comment\ntitle: x\n---\n# Brief: Port to C#\n' > $W/fm.md
$B/agent spawn --role t6 --cwd $W --brief $W/fm.md --model haiku > /dev/null 2>&1; wait_dead t6
check "$(meta t6 'm["title"]')" "t6 — Port to C# (stage-a)" "front matter is skipped and a '#' glued to the word stays"
printf '## Closing hashes ##\n' > $W/ch.md
$B/agent spawn --role t7 --cwd $W --brief $W/ch.md --model haiku > /dev/null 2>&1; wait_dead t7
check "$(meta t7 'm["title"]')" "t7 — Closing hashes (stage-a)" "closing hashes after a space are still stripped"

# ---- 6. the no-plan warning text
export HUB_STAGE=stage-b
$B/agent spawn --role p1 --stage stage-b --cwd $W --brief $W/b.md --model haiku > /dev/null 2> $R/p1.err
grep -q "show the plan to the owner; record \`ask plan\` only after the owner's yes" $R/p1.err; check $? 0 "no plan: the warning says to show the plan first and record it after the owner's yes"
grep -q 'after the owner.s yes, `ask plan' $R/p1.err; check $? 1 "negative: the old wording (which nudged recording first) is gone"
exit $fail
