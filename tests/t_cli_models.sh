#!/bin/bash
# Latest models by default, through the CLI instead of pinned ids: the newer of `claude` on PATH and Claude Desktop's
# bundled CLI is started (and named); the id the run reports is recorded and shown (meta, status, the journal line,
# agent-top screen / --once / widget / --json); a CLI older than 2.1.287 is warned about once by spawn and hub start;
# `fable` is an alias like opus/sonnet/haiku, also for the effort rules and `hub reviewer`. Stand-in CLI: fake_claude.py.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test
R=$AGENT_HUB_HOME; P=$(mktemp -d); W=$P/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
meta(){ python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" $R/stage-a/agents/$1/meta.json "$2"; }

# The version a CLI reports is remembered by path and mtime (see below). A stand-in whose answer depends on FAKE_VERSION
# gets its own state directory per call (AGENT_HUB_STATE_DIR), as a real CLI's answer depends on its file only.
# ---- the newest CLI wins, and spawn says which one
FH=$P/fakehome; BD="$FH/Library/Application Support/Claude/claude-code"
mkdir -p "$BD/2.1.300/claude.app/Contents/MacOS" $P/pathbin
printf '#!/bin/sh\n[ "$1" = "--version" ] || echo bundle > "$PWD/which.log"\nexec python3 %s "$@"\n' $T/fake_claude.py > "$BD/2.1.300/claude.app/Contents/MacOS/claude"
printf '#!/bin/sh\n[ "$1" = "--version" ] || echo path > "$PWD/which.log"\nexec python3 %s "$@"\n' $T/fake_claude.py > $P/pathbin/claude
chmod +x "$BD/2.1.300/claude.app/Contents/MacOS/claude" $P/pathbin/claude
spawn_with(){ # spawn_with ROLE PATH-CLI-VERSION: no CLAUDE_BIN, HOME with the 2.1.300 bundle, a claude on PATH of that version
  rm -f $W/which.log
  (unset CLAUDE_BIN; HOME=$FH PATH=$P/pathbin:$PATH FAKE_VERSION=$2 AGENT_HUB_STATE_DIR=$P/st-$1 $B/agent spawn --role $1 --cwd $W --model haiku --brief $W/b.md) > $P/$1.out 2>&1
  rc=$?; wait_dead $1; return $rc
}
spawn_with old 2.1.274; check $? 0 "spawn with an old claude on PATH and a newer Desktop bundle"
check "$(cat $W/which.log)" "bundle" "the newer bundled CLI is started, not the older claude on PATH"
grep -q "CLI .*2.1.300.*older" $P/old.out; check $? 0 "…and the spawn output names the CLI, its version and why"
spawn_with new 2.1.310; check $? 0 "a claude on PATH newer than the bundle"
check "$(cat $W/which.log)" "path" "negative: the newer claude on PATH is started"
grep -q "CLI .*pathbin/claude (2.1.310; claude on PATH" $P/new.out; check $? 0 "…and the output says PATH"
spawn_with tie 2.1.300; check $? 0 "a claude on PATH as new as the bundle"
check "$(cat $W/which.log)" "path" "negative: a tie keeps PATH"
spawn_with unk garbage; check $? 0 "a claude on PATH whose version cannot be read"
check "$(cat $W/which.log)" "path" "negative: an unreadable version keeps PATH"
rm -f $W/which.log
(unset CLAUDE_BIN; HOME=$FH PATH=$P/pathbin:$PATH FAKE_VERSION=2.1.274 AGENT_HUB_STATE_DIR=$P/st-pin CLAUDE_BIN=$P/pathbin/claude $B/agent spawn --role pin --cwd $W --model haiku --brief $W/b.md) > $P/pin.out 2>&1; wait_dead pin
check "$(cat $W/which.log)" "path" "negative: an explicit CLAUDE_BIN is never replaced by a newer CLI"
export CLAUDE_BIN=$T/fake_claude.py

# ---- the version is read from the "<version> (Claude Code)" line, not from the first number a shim prints
python3 - $B > $P/parse.out <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import hubcore as hc
cases = [("node 20.11.0\n2.1.285 (Claude Code)\n", (2, 1, 285)), ("2.1.285 (Claude Code)\n", (2, 1, 285)),
         ("2.1.285 (Claude Code)\nnode 20.11.0\n", (2, 1, 285)), ("banner\n2.1.285\n", (2, 1, 285)),
         ("node 20.11.0\n", None), ("Claude Code 2.1.285\n", None), ("", None)]
bad = [(t, hc.parse_version(t), want) for t, want in cases if hc.parse_version(t) != want]
print("ok" if not bad else bad)
PY
check "$(cat $P/parse.out)" ok "parse_version: the documented line wins, a last line that starts with a version is the fallback"
rm -f $W/which.log
(unset CLAUDE_BIN; HOME=$FH PATH=$P/pathbin:$PATH FAKE_VERSION=2.1.274 FAKE_VERSION_BANNER="node 20.11.0" AGENT_HUB_STATE_DIR=$P/st-shim $B/agent spawn --role shim --cwd $W --model haiku --brief $W/b.md) > $P/shim.out 2>&1; wait_dead shim
check "$(cat $W/which.log)" "bundle" "a shim that prints node 20.11.0 before its version does not beat a newer bundled CLI"
grep -q "2.1.274" $P/shim.out; check $? 0 "…and its real version is the one reported"
FAKE_VERSION=2.1.274 FAKE_VERSION_BANNER="node 20.11.0" AGENT_HUB_STATE_DIR=$P/st-shimstart $B/hub start --stage web --session 11111111-1111-4111-8111-111111111111 --dry-run > $P/shim-start.out 2>&1
grep -q '^ATTENTION: Claude Code 2.1.274 .* older than 2.1.287' $P/shim-start.out; check $? 0 "hub start: the same shim does not hide the old-CLI warning"

# ---- `--version` is bounded and remembered: a hanging shim costs seconds, not 20 s; a spawn does not run it again
mkdir -p $P/hang
printf '#!/bin/sh\n[ "$1" = "--version" ] && exec sleep 30\necho path > "$PWD/which.log"\nexec python3 %s "$@"\n' $T/fake_claude.py > $P/hang/claude; chmod +x $P/hang/claude
rm -f $W/which.log; SECONDS=0
(unset CLAUDE_BIN; HOME=$FH PATH=$P/hang:$PATH $B/agent spawn --role hang --cwd $W --model haiku --brief $W/b.md) > $P/hang.out 2>&1; rc=$?
took=$SECONDS; wait_dead hang
check $rc 0 "a claude whose --version hangs: spawn still starts the agent"
[ "$took" -lt 15 ]; check $? 0 "…within the 5 s bound ($took s, not 20)"
check "$(cat $W/which.log)" "path" "…on PATH (version unknown keeps PATH)"
grep -q "version unknown" $P/hang.out; check $? 0 "…and says the version is unknown"
mkdir -p $P/count; : > $P/vcalls.log
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo called >> %s\nexec python3 %s "$@"\n' $P/vcalls.log $T/fake_claude.py > $P/count/claude; chmod +x $P/count/claude
cspawn(){ (unset CLAUDE_BIN; HOME=$FH PATH=$P/count:$PATH $B/agent spawn --role $1 --cwd $W --model haiku --brief $W/b.md) > $P/$1.out 2>&1; wait_dead $1; }
cspawn c1; cspawn c2
check "$(wc -l < $P/vcalls.log | tr -d ' ')" 1 "two spawns (two processes) run --version once: the answer is cached by path and mtime"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[sys.argv[2]]["version"]=="2.1.287", d' $R/.state/cli-version/cache.json $P/count/claude; check $? 0 "…in <hub home>/.state/cli-version/cache.json"
sleep 1; touch $P/count/claude; cspawn c3
check "$(wc -l < $P/vcalls.log | tr -d ' ')" 2 "a CLI whose file changed (an update) is asked again"
mkdir -p $P/dry; printf '#!/bin/sh\n[ "$1" = "--version" ] && echo called >> %s\nexec python3 %s "$@"\n' $P/vcalls.log $T/fake_claude.py > $P/dry/claude; chmod +x $P/dry/claude
(unset CLAUDE_BIN; HOME=$FH PATH=$P/dry:$PATH $B/hub start --stage web --session 11111111-1111-4111-8111-111111111111 --dry-run) > $P/dry.out 2>&1
! grep -q "$P/dry/claude" $R/.state/cli-version/cache.json; check $? 0 "hub start --dry-run reads the cache but writes nothing"
AGENT_HUB_STATE_DIR=$P/state cspawn c4
[ -f $P/state/cli-version/cache.json ]; check $? 0 "AGENT_HUB_STATE_DIR moves the cache"
nohome=$P/nohome; (unset CLAUDE_BIN; AGENT_HUB_HOME=$nohome HOME=$FH PATH=$P/count:$PATH $B/hub start --stage web --session 11111111-1111-4111-8111-111111111111 --dry-run) > /dev/null 2>&1
[ ! -e $nohome ]; check $? 0 "negative: no hub home, no cache directory is made"

# ---- the model the run reports is recorded and shown
spawn_out=$($B/agent spawn --role food --cwd $W --model sonnet --brief $W/b.md 2>&1); check $? 0 "spawn --model sonnet"
wait_dead food
check "$(meta food 'm["resolved_model"]')" "claude-sonnet-5-5" "meta records the id from the init event"
check "$(meta food 'm["model"]')" "sonnet" "…next to the alias that was asked for"
python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))["roles"]["food"]["note"]; assert n=="agent-spawn claude-sonnet-5-5", n' $R/stage-a/roles.json; check $? 0 "the roles note carries the resolved id too"
grep -q 'started headless agent food (claude-sonnet-5-5/high, asked for sonnet)' $(journal stage-a); check $? 0 "the start line shows the resolved id"
$B/agent status food > $P/st.out; grep -q '^food \[food\] claude-sonnet-5-5 (asked for sonnet): ' $P/st.out; check $? 0 "agent status shows the resolved id"
$B/agent spawn --role full --cwd $W --model claude-opus-5-5 --brief $W/b.md > /dev/null 2>&1; wait_dead full
grep -q 'started headless agent full (claude-opus-5-5/high)' $(journal stage-a); check $? 0 "negative: a full id needs no 'asked for'"
$B/agent status full | grep -q 'asked for'; check $? 1 "…nor does status"
AGENT_HUB_MODEL_MAP="sonnet=claude-sonnet-4-1" $B/agent spawn --role pinned --cwd $W --model sonnet --brief $W/b.md > /dev/null 2>&1; wait_dead pinned
check "$(meta pinned 'm["model"]')" "claude-sonnet-4-1" "AGENT_HUB_MODEL_MAP still pins an alias (opt-in)"
AGENT_TOP_AGENT_BIN=$B/agent $B/agent-top --once --stage stage-a --width 120 > $P/top.out 2>&1
grep -E '^[^ ]+ food ' $P/top.out | grep -q 'sonnet-5-5/hi'; check $? 0 "agent-top --once: MODEL shows sonnet-5-5"
grep -E '^[^ ]+ food ' $P/top.out | grep -Eq ' sonnet/hi'; check $? 1 "…not the bare alias"
$B/agent-top --widget --stage stage-a > $P/widget.html 2>&1; grep -q 'sonnet-5-5/hi' $P/widget.html; check $? 0 "agent-top widget shows sonnet-5-5"
$B/agent-top --json --stage stage-a > $P/top.json 2>&1
python3 -c 'import json,sys; a={x["role"]:x for x in json.load(open(sys.argv[1]))["agents"]}; assert a["food"]["model_id"]=="claude-sonnet-5-5" and a["food"]["model"]=="sonnet", a["food"]' $P/top.json; check $? 0 "agent-top --json: model_id next to model"
$B/agent-top --once --stage stage-a --agent food --width 120 > $P/card.out 2>&1; grep -q 'sonnet-5-5/hi' $P/card.out; check $? 0 "agent-top agent card shows sonnet-5-5"
# an agent started before this change has no resolved_model in its meta: the init event of its log says it
python3 - $R/stage-a/agents/food/meta.json <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m.pop("resolved_model"); json.dump(m, open(sys.argv[1], "w"))
PY
$B/agent-top --json --stage stage-a 2>/dev/null | python3 -c 'import json,sys; a={x["role"]:x for x in json.load(sys.stdin)["agents"]}; assert a["food"]["model_id"]=="claude-sonnet-5-5", a["food"]'; check $? 0 "agent-top falls back to the init event of the log"

# ---- an old CLI is warned about once, by spawn and by hub start; a current one is not
FAKE_VERSION=2.1.274 AGENT_HUB_STATE_DIR=$P/st-oldcli $B/agent spawn --role oldcli --cwd $W --model haiku --brief $W/b.md > $P/oldcli.out 2>&1; check $? 0 "spawn with CLI 2.1.274 still starts the agent"
wait_dead oldcli
[ "$(grep -c 'older than 2.1.287' $P/oldcli.out)" = 1 ]; check $? 0 "…with one warning"
grep -q 'update Claude Code; with an older CLI the aliases' $P/oldcli.out; check $? 0 "…that says to update and why"
AGENT_HUB_STATE_DIR=$P/st-newcli $B/agent spawn --role newcli --cwd $W --model haiku --brief $W/b.md > $P/newcli.out 2>&1; wait_dead newcli
grep -q 'older than' $P/newcli.out; check $? 1 "negative: CLI 2.1.287 (the minimum) gets no warning"
FAKE_VERSION=2.1.286 AGENT_HUB_STATE_DIR=$P/st-286 $B/agent spawn --role v286 --cwd $W --model haiku --brief $W/b.md > $P/v286.out 2>&1; wait_dead v286
grep -q 'older than 2.1.287' $P/v286.out; check $? 0 "positive control: CLI 2.1.286, one below the minimum, is warned about"
FAKE_VERSION=2.1.285 AGENT_HUB_STATE_DIR=$P/st-285 $B/agent spawn --role v285 --cwd $W --model haiku --brief $W/b.md > $P/v285.out 2>&1; wait_dead v285
grep -q 'older than 2.1.287' $P/v285.out; check $? 0 "…and 2.1.285, the former minimum, now too"
H1=11111111-1111-4111-8111-111111111111
FAKE_VERSION=2.1.274 AGENT_HUB_STATE_DIR=$P/st-startold $B/hub start --stage web --session $H1 --dry-run > $P/start-old.out 2>&1; check $? 0 "hub start with CLI 2.1.274"
[ "$(grep -c 'older than 2.1.287' $P/start-old.out)" = 1 ] && grep -q '^ATTENTION: Claude Code 2.1.274' $P/start-old.out; check $? 0 "…warns once"
AGENT_HUB_STATE_DIR=$P/st-startnew $B/hub start --stage web --session $H1 --dry-run > $P/start-new.out 2>&1
grep -q 'older than' $P/start-new.out; check $? 1 "negative: hub start with CLI 2.1.287 does not warn"

# ---- idle compaction (CLI 2.1.290+, on by default): a Claude hub's start/takeover warns unless the settings that decide
# it (managed > project local > project > user) turn it off; the background successor gets it off on its command line
# (t_autopilot.sh)
CD=$P/claude-config; PJ=$P/proj; mkdir -p $CD $PJ/.claude
unset AGENT_HUB_NO_IDLE_COMPACTION_CHECK  # lib.sh sets it for every other script
# The machine's own managed settings win over everything a test writes: with one that sets the key, the block is skipped.
MANAGED=$(python3 - $B <<'PY'
import json, sys; sys.path.insert(0, sys.argv[1]); import hubcore as hc
for f in hc.MANAGED_SETTINGS:
    try:
        d = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        continue
    if isinstance(d, dict) and "idleCompaction" in d:
        print(f)
PY
)
if [ -n "$MANAGED" ]; then echo "SKIP idle compaction: $MANAGED sets idleCompaction on this machine"; else
idle_start(){ # idle_start NAME [ENGINE]: hub start from the project $PJ
  (cd $PJ && CLAUDE_CONFIG_DIR=$CD AGENT_HUB_ENGINE=${2:-claude} AGENT_HUB_STATE_DIR=$P/st-$1 \
    $B/hub start --stage web --session $H1 --dry-run) > $P/$1.out 2>&1
}
idle_start idle-none; check $? 0 "idle compaction: hub start with no settings file setting it"
grep -q "^ATTENTION: Claude Code 2.1.290+ compacts a conversation over 200K tokens left idle .*no settings file sets \"idleCompaction\": .*set \"idleCompaction\": false in $CD/settings.json" $P/idle-none.out; check $? 0 "…warns, naming the user settings file and the key"
echo '{"model": "opus", "idleCompaction": false}' > $CD/settings.json; idle_start idle-off
check "$?:$(grep -c 'idleCompaction' $P/idle-off.out)" 0:0 "negative: \"idleCompaction\": false in the user settings silences it"
echo '{"idleCompaction": true}' > $PJ/.claude/settings.local.json; idle_start idle-local
grep -q "$PJ/.claude/settings.local.json sets \"idleCompaction\": true" $P/idle-local.out; check $? 0 "…but the project's settings.local.json turning it on wins, and is named"
echo '{"idleCompaction": false}' > $PJ/.claude/settings.json; rm $CD/settings.json $PJ/.claude/settings.local.json; idle_start idle-proj
check "$?:$(grep -c 'idleCompaction' $P/idle-proj.out)" 0:0 "negative: the project's settings.json turning it off is enough"
rm $PJ/.claude/settings.json; echo '{not json' > $CD/settings.json; idle_start idle-bad
grep -q 'no settings file sets' $P/idle-bad.out; check $? 0 "an unreadable settings file counts as not setting it"
idle_start idle-codex codex
check "$?:$(grep -c 'idleCompaction' $P/idle-codex.out)" 0:0 "negative: a Codex hub is not warned about"
rm $CD/settings.json
python3 - $B $P <<'PY' > $P/idle-managed.out
import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import hubcore as hc
d = Path(sys.argv[2]) / "managed"; d.mkdir(); (d / "m.json").write_text('{"idleCompaction": true}')
p = Path(sys.argv[2]) / "mp"; (p / ".claude").mkdir(parents=True); (p / ".claude" / "settings.json").write_text('{"idleCompaction": false}')
hc.MANAGED_SETTINGS = (d / "m.json",)
print(hc.idle_compaction_source(p) == (True, d / "m.json") and f"{d / 'm.json'} sets" in (hc.idle_compaction_warning(p) or ""))
PY
check "$(cat $P/idle-managed.out)" True "managed settings win over the project's"
(cd $PJ && CLAUDE_CONFIG_DIR=$CD AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1 AGENT_HUB_STATE_DIR=$P/st-idle-skip $B/hub start --stage web --session $H1 --dry-run) > $P/idle-skip.out 2>&1
check "$?:$(grep -c 'idleCompaction' $P/idle-skip.out)" 0:0 "negative: AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1 skips the check"
# a linked worktree reads the local settings of its main checkout
GM=$P/gmain; git init -q $GM && git -C $GM -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git -C $GM worktree add -q $P/gwt -b wt && mkdir -p $GM/.claude && echo '{"idleCompaction": true}' > $GM/.claude/settings.local.json
echo '{"idleCompaction": false}' > $CD/settings.json
(cd $P/gwt && CLAUDE_CONFIG_DIR=$CD AGENT_HUB_STATE_DIR=$P/st-idle-wt $B/hub start --stage web --session $H1 --dry-run) > $P/idle-wt.out 2>&1
grep -q "$GM/.claude/settings.local.json sets \"idleCompaction\": true" $P/idle-wt.out; check $? 0 "from a linked worktree, the main checkout's settings.local.json is read (and wins over the user's)"
rm $CD/settings.json
fi

# a hub in Claude Desktop: Desktop's own CLI may not read idleCompaction, which nothing here can check, so the start says the
# handoff threshold must come first, whatever the settings files say (the skip variable and a terminal hub negative)
export CLAUDE_SESSIONS_DIR=$P/dsess; mkdir -p $CLAUDE_SESSIONS_DIR/a/b
DL=local_d637d7e1-4d6c-4366-b32f-bc735e7c56d6
printf '{"sessionId":"%s","cliSessionId":"%s","title":"Hub web #1"}' $DL $H1 > $CLAUDE_SESSIONS_DIR/a/b/$DL.json
echo '{"idleCompaction": false}' > $CD/settings.json
desk_start(){ (cd $PJ && CLAUDE_CONFIG_DIR=$CD AGENT_HUB_STATE_DIR=$P/st-$1 env "${@:3}" $B/hub start --stage web --session $2 --dry-run) > $P/$1.out 2>&1; }
desk_start desk-on $DL; check $? 0 "desktop hub: start works"
grep -q "^ATTENTION: this hub runs in Claude Desktop, with Desktop's own Claude Code .*not verified.*the context budget warns at 300k tokens, above the 200K.*AGENT_HUB_CONTEXT_WARN" $P/desk-on.out; check $? 0 "…warns that the handoff threshold must come first, naming the threshold and the knob, although the user's settings turn idle compaction off"
desk_start desk-low $DL AGENT_HUB_CONTEXT_WARN=150000
grep -q "the context budget warns at 150k tokens, below the 200K" $P/desk-low.out && ! grep -q "set AGENT_HUB_CONTEXT_WARN" $P/desk-low.out; check $? 0 "…and says the threshold is already below it when it is"
desk_start desk-term 22222222-2222-4222-8222-222222222222; check "$?:$(grep -c 'runs in Claude Desktop' $P/desk-term.out)" 0:0 "negative: a terminal hub gets no Desktop line"
desk_start desk-skip $DL AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1; check "$?:$(grep -c 'runs in Claude Desktop' $P/desk-skip.out)" 0:0 "negative: AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1 skips it"
unset CLAUDE_SESSIONS_DIR; rm -f $CD/settings.json

# ---- fable is an alias like the others
$B/agent spawn --role fab --cwd $W --model fable --brief $W/b.md > $P/fab.out 2>&1; check $? 0 "spawn --model fable is accepted"
wait_dead fab
grep -q -- '--model fable --effort high' $W/argv.log; check $? 0 "…passed to the CLI as is, with an effort"
check "$(meta fab 'm["resolved_model"]')" "claude-fable-5-1" "…and resolved to the latest fable"
mkdir -p $W/.git $W/.agent-hub
echo '{"AGENT_HUB_EFFORT_RULES": {"fable": "high|xhigh"}}' > $W/.agent-hub/config.json
$B/agent spawn --role fab2 --cwd $W --model fable --effort medium --brief $W/b.md > $P/fab2.out 2>&1; check $? 2 "the effort rules match the alias: fable at medium is denied"
grep -q 'fable runs only at effort high or xhigh' $P/fab2.out; check $? 0 "…naming the rule"
$B/agent spawn --role fab3 --cwd $W --model fable --effort xhigh --brief $W/b.md > /dev/null 2>&1; check $? 0 "positive control: fable at xhigh is allowed"
wait_dead fab3; rm $W/.agent-hub/config.json
# ---- haiku takes an effort like the others; the alias is Haiku 5.5 from CLI 2.1.296, Haiku 4.5 before it
# (the stand-in resolves the alias by FAKE_VERSION, as the real CLI does). Both generations get the flag.
for pair in "hk295 2.1.295 claude-haiku-4-5-20251001" "hk296 2.1.296 claude-haiku-5-5"; do
  set -- $pair
  FAKE_VERSION=$2 AGENT_HUB_STATE_DIR=$P/st-$1 $B/agent spawn --role $1 --cwd $W --model haiku --effort medium --brief $W/b.md > $P/$1.out 2>&1; check $? 0 "spawn --model haiku --effort medium on CLI $2"
  wait_dead $1
  tail -1 $W/argv.log | grep -q -- '--model haiku --effort medium'; check $? 0 "…the CLI got --effort medium"
  check "$(meta $1 'm["resolved_model"]')/$(meta $1 'm["effort"]')" "$3/medium" "…the alias resolved to $3, the effort is on record"
  grep -qF "started headless agent $1 ($3/medium, asked for haiku)" $(journal stage-a); check $? 0 "…and the start line shows both"
done
# the effort rules see the effort of haiku (a repository may require "never below medium")
echo '{"AGENT_HUB_EFFORT_RULES": {"haiku": "medium|high"}}' > $W/.agent-hub/config.json
$B/agent spawn --role hkr1 --cwd $W --model haiku --effort low --brief $W/b.md > $P/hkr1.out 2>&1; check $? 2 "the effort rules see the effort of haiku: haiku at low is denied"
grep -q 'haiku runs only at effort medium or high' $P/hkr1.out; check $? 0 "…naming the rule"
$B/agent spawn --role hkr2 --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1; check $? 0 "positive control: haiku without --effort lands on the default (high), which the rule allows"
tail -1 $W/argv.log | grep -q -- '--model haiku --effort high'; check $? 0 "…and the CLI got --effort high"
wait_dead hkr2; rm $W/.agent-hub/config.json
AGENT_HUB_REVIEW_MODEL=fable $B/hub reviewer > $P/rev.out 2> $P/rev.err; check $? 0 "hub reviewer takes fable as AGENT_HUB_REVIEW_MODEL"
grep -q 'agent fable/high' $P/rev.out && ! grep -q 'using opus' $P/rev.err; check $? 0 "…and keeps it (no fallback to opus)"
grep -q -- '--model fable' $P/rev.out; check $? 0 "…and the start line names it"
AGENT_HUB_REVIEW_MODEL=gpt $B/hub reviewer > $P/rev2.out 2> $P/rev2.err
grep -q 'using opus' $P/rev2.err; check $? 0 "negative: a model that is no alias still falls back"
exit $fail
