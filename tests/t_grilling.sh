#!/bin/bash
# No automatic handoff in the middle of a grilling (bin/grilling.py): how the budget hook marks a hub's grilling (Claude's
# Skill call, Codex's SKILL.md read, an owner prompt invoking the skill), what it says and gates while the mark holds,
# the ceiling, the staleness bound, and `hub succeed` / `hub handoff` refusing unless --owner-asked.
. "$(dirname "$0")/lib.sh"
unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT $(env | sed -n 's/^\(AGENT_HUB_\(CONTEXT\|AUTO\|SUCCESSOR\|STATE\|GRILLING\)[A-Z_]*\)=.*/\1/p')
export CLAUDE_BIN=$T/fake_claude_bg.py CLAUDE_SESSIONS_DIR=$(mktemp -d) AGENT_HUB_SUCCESSOR_TIMEOUT=2 AGENT_HUB_AUTO_HANDOFF=on
export CLAUDE_EFFORT=high
HUB1=11111111-1111-4111-8111-111111111111; HUB2=22222222-2222-4222-8222-222222222222

setup(){
  new_home; R=$AGENT_HUB_HOME; export FAKE_BG_LOG=$R/bg.log AGENT_HUB_STATE_DIR=$R/state
  $B/hub start --stage stage-a --session $HUB1 > $R/start.out 2>&1 || { echo "FAIL setup: hub start"; cat $R/start.out; fail=1; }
  H=$R/stage-a/coordinator/HANDOFF-hub-stage-a-2026-10-01-1200.md
  printf '# Handoff "Hub stage-a #1" → "Hub stage-a #2" — stage-a\n\n## 0. First steps\n1. take over\n' > $H
  W=$R/work; mkdir -p $W; TR=$R/tr.jsonl; rm -f $TR
}
J(){ cat "$(journal stage-a)" 2>/dev/null; }
MK(){ echo "$AGENT_HUB_STATE_DIR/grilling/${1:-$HUB1}.json"; }
marked(){ [ -f "$(MK "$@")" ] && echo yes || echo no; }
usage(){ python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":int(sys.argv[1])}}}))' "$1" >> $TR; }
# cbh EVENT [TOOL] [TOOL_INPUT_JSON]: one hook call in the main thread of $SID (default the hub), prompt $PROMPT
cbh(){ python3 -c 'import json,sys; d={"hook_event_name":sys.argv[1],"session_id":sys.argv[5],"transcript_path":sys.argv[2],"tool_name":sys.argv[3],"tool_input":json.loads(sys.argv[4]),"permission_mode":"acceptEdits","cwd":"/repo/x","prompt":sys.argv[6],"effort":{"level":"high"}}
if sys.argv[7]: d["agent_id"]=sys.argv[7]
print(json.dumps(d))' "$1" "$TR" "${2:-}" "${3:-null}" "${SID:-$HUB1}" "${PROMPT:-}" "${AGENT:-}" | python3 $HOOKS/context_budget.py; }
skill(){ cbh PostToolUse Skill "$(python3 -c 'import json,sys; print(json.dumps({"skill":sys.argv[1]}))' "$1")"; }
bash_in(){ python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$1"; }
succeed(){ CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --dry-run "$@"; }

# ================================================================== setting the mark
setup; usage 1000
skill delamain:hub > /dev/null; check "$(marked)" no "mark, negative: another skill (delamain:hub) sets nothing"
SID=$HUB2 skill mattpocock-skills:grilling > /dev/null; check "$(marked $HUB2)" no "mark, negative: a session that is not a stage's hub is not marked"
AGENT=a1 skill mattpocock-skills:grilling > /dev/null; check "$(marked)" no "mark, negative: a sub-agent of the hub loading the skill does not mark the hub"
skill mattpocock-skills:grilling > /dev/null; check "$(marked)" yes "mark: the hub's Skill call of mattpocock-skills:grilling marks it (Claude Code)"
J | grep -q '\[autopilot\] grilling in progress (mattpocock-skills:grilling, the Skill tool)'; check $? 0 "mark: journaled"
$B/hub grilling status --stage stage-a | grep -q '^grilling in progress in the hub of stage-a'; check $? 0 "status: shows the mark"
$B/hub grilling end --stage stage-a > /dev/null; check "$(marked)" no "end: \`hub grilling end\` at a terminal clears it"
$B/hub grilling status --stage stage-a | grep -q '^no grilling in progress'; check $? 0 "status: …and says so"
# Codex loads a skill by reading its SKILL.md through the shell
cbh PostToolUse Bash "$(bash_in 'cat /x/skills/hub/SKILL.md')" > /dev/null; check "$(marked)" no "mark, Codex negative: reading another skill's SKILL.md sets nothing"
for c in 'ls /x/skills/grilling/SKILL.md' 'test -f ~/.codex/skills/grilling/SKILL.md && echo y' 'git diff -- skills/grilling/SKILL.md'; do
  cbh PostToolUse Bash "$(bash_in "$c")" > /dev/null; check "$(marked)" no "mark, Codex negative: naming the file is not reading it — $c"
done
cbh PostToolUse Bash "$(bash_in "sed -n '1,200p' ~/.codex/plugins/cache/mattpocock-skills/skills/grilling/SKILL.md")" > /dev/null; check "$(marked)" yes "mark, Codex: a shell read of the grilling skill's SKILL.md marks it"
$B/hub grilling end --stage stage-a > /dev/null
PROMPT='а что такое грилинг вообще?' cbh UserPromptSubmit > /dev/null; check "$(marked)" no "mark, negative: words about grilling in a prompt are not an invocation"
PROMPT='$grilling the pricing plan' cbh UserPromptSubmit > /dev/null; check "$(marked)" yes "mark: an owner prompt invoking \$grilling (Codex) marks it"
$B/hub grilling end --stage stage-a > /dev/null
PROMPT='/mattpocock-skills:grill-me план релиза' cbh UserPromptSubmit > /dev/null; check "$(marked)" yes "mark: an owner prompt invoking /…:grill-me (Claude Code) marks it"
$B/hub grilling end --stage stage-a > /dev/null
AGENT_HUB_GRILLING_SKILL='^interview$' skill mattpocock-skills:grilling > /dev/null; check "$(marked)" no "mark: AGENT_HUB_GRILLING_SKILL replaces the pattern (grilling no longer matches)"
AGENT_HUB_GRILLING_SKILL='^interview$' skill interview > /dev/null; check "$(marked)" yes "mark: …and its own skill name marks it"
$B/hub grilling end --stage stage-a > /dev/null
# the explicit command, either engine
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub grilling start --stage stage-a > $R/g.out 2>&1; check "$?:$(marked $HUB2)" "2:no" "start: a session that is not the stage's hub is refused"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub grilling start --topic "цены" > $R/g.out 2>&1; check "$?:$(marked)" "0:yes" "start: the hub's own \`hub grilling start\` (stage found from the session) marks it"

# ================================================================== the hook while it holds
usage 320000
cbh UserPromptSubmit > $R/w1.out
grep -q 'A grilling with the owner is in progress in this hub' $R/w1.out && ! grep -q 'Autopilot is on' $R/w1.out && ! grep -q 'hub succeed --stage' $R/w1.out
check $? 0 "hook, warn: while grilling, no handoff advice — finish the grilling instead"
grep -qF 'grilling end --stage stage-a' $R/w1.out; check $? 0 "hook, warn: …and it names \`hub grilling end\`"
cbh PostToolUse Bash "$(bash_in ls)" > $R/w2.out; check "$(wc -c < $R/w2.out | tr -d ' ')" 0 "hook, warn: said once per step, not on every call"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub grilling end --why "frontier empty" > /dev/null
cbh PostToolUse Bash "$(bash_in ls)" > $R/w3.out; grep -q 'Autopilot is on' $R/w3.out && grep -qF 'hub succeed --stage stage-a' $R/w3.out
check $? 0 "hook, warn: once the grilling ends, the handoff procedure comes at once (same step)"
skill mattpocock-skills:grilling > $R/w4.out; grep -q 'A grilling with the owner is in progress' $R/w4.out
check $? 0 "hook, warn: a grilling that starts after the handoff advice is said at once, on the Skill call itself (it cancels the advice)"
usage 510000
cbh PreToolUse Bash "$(bash_in 'ask close q-1 --answer B')" > $R/b1.out; check "$(wc -c < $R/b1.out | tr -d ' ')" 0 "hook, block: while grilling the hub's Bash is not gated (answers go to \`ask\`)"
cbh PreToolUse Edit '{"file_path":"/x/notes.md"}' > $R/b2.out; check "$(wc -c < $R/b2.out | tr -d ' ')" 0 "hook, block: …nor Edit"
cbh PreToolUse Agent '{"prompt":"go"}' > $R/b3.out; grep -q '"deny"' $R/b3.out && grep -q 'grilling with the owner is in progress' $R/b3.out && ! grep -q Autopilot $R/b3.out
check $? 0 "hook, block: the delegation tools stay closed, with the grilling text"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub grilling end > /dev/null
cbh PreToolUse Bash "$(bash_in 'ask close q-1 --answer B')" | grep -q '"deny".*Hand over now'; check $? 0 "hook, block, control: without the mark the same Bash is denied with \"hand over now\""
cbh PreToolUse Bash "$(bash_in 'hub grilling status --stage stage-a')" > $R/b4.out; check "$(wc -c < $R/b4.out | tr -d ' ')" 0 "hook, block: \`hub grilling\` is a handover command"

# ================================================================== the ceiling
skill mattpocock-skills:grilling > /dev/null
export AGENT_HUB_GRILLING_CEILING=600000
usage 610000
cbh PreToolUse Bash "$(bash_in 'git status')" > $R/c1.out
grep -q '"deny"' $R/c1.out && grep -q 'do not hand over by yourself' $R/c1.out && grep -q 'carry the grilling in its § 0' $R/c1.out && grep -q 'ask whether to hand over now' $R/c1.out
check $? 0 "ceiling: mid-grilling the gate returns; the text says to write the handoff carrying the grilling and to ask the owner"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["ceiling"]' "$(MK)"; check $? 0 "ceiling: recorded in the mark"
J | grep -q 'grilling: the context ceiling is reached'; check $? 0 "ceiling: journaled"
cbh UserPromptSubmit > $R/c2.out; grep -q 'The context ceiling 600k is reached mid-grilling' $R/c2.out && grep -q 'Autopilot is on' $R/c2.out && grep -q 'with --owner-asked added' $R/c2.out
check $? 0 "ceiling: the warning gives the handoff procedure, to run only on the owner's yes (--owner-asked)"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a --out $R/ceil.md > $R/c3.out 2>&1; check $? 0 "ceiling: \`hub handoff\` passes without a flag (the handoff is prepared)"
grep -q '^5\. A grilling with the owner was in progress' $R/ceil.md; check $? 0 "ceiling: …and its § 0 carries the grilling"
succeed > $R/c4.out 2>&1; check "$?:$(grep -c 'context ceiling is reached: write the handoff and ask the owner' $R/c4.out)" "2:1" "ceiling: \`hub succeed\` still refuses without the owner's word"
succeed --owner-asked > $R/c5.out 2>&1; check $? 0 "ceiling: …and passes with --owner-asked"
unset AGENT_HUB_GRILLING_CEILING
# Codex: the ceiling defaults to 95% of the rollout's window
setup; skill mattpocock-skills:grilling > /dev/null
codex_usage(){ python3 -c 'import json,sys; print(json.dumps({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":int(sys.argv[1])},"model_context_window":400000}}}))' "$1" >> $TR; }
codex_usage 350000; cbh PreToolUse Bash "$(bash_in 'git status')" > $R/x1.out; check "$(wc -c < $R/x1.out | tr -d ' ')" 0 "ceiling, Codex: past the block (85%) but under 95% of the window, the grilling holds"
codex_usage 385000; cbh PreToolUse Bash "$(bash_in 'git status')" | grep -q 'carry the grilling'; check $? 0 "ceiling, Codex: at 95% of the window the handoff is prepared, carrying the grilling"

# ================================================================== staleness and the session binding
setup; usage 1000; skill mattpocock-skills:grilling > /dev/null
age(){ python3 - "$(MK)" "$1" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["touched"] = time.time() - int(sys.argv[2]) * 60; json.dump(d, open(p, "w"))
PY
}
touched(){ python3 -c 'import json,sys,time; print(int((time.time()-json.load(open(sys.argv[1]))["touched"])//60))' "$(MK)"; }
age 100; PROMPT='[delamain watchdog] stage-a: 1 journal lines…' cbh UserPromptSubmit > /dev/null; check "$(touched)" 100 "stale: the watchdog's wake is not the owner, it does not refresh the mark"
PROMPT='вариант B, дальше' cbh UserPromptSubmit > /dev/null; check "$(touched)" 0 "stale: the owner's answer refreshes the mark"
age 300; PROMPT='я вернулся, продолжим' cbh UserPromptSubmit > /dev/null; check "$(marked)" no "stale: the prompt that ends a pause past the bound does not revive the mark"
skill mattpocock-skills:grilling > /dev/null
age 241; usage 320000
cbh PostToolUse Bash "$(bash_in ls)" > $R/s1.out; grep -q 'Autopilot is on' $R/s1.out; check "$?:$(marked)" "0:no" "stale: 241 min after the owner last spoke the mark lapses and the handoff advice returns"
J | grep -q 'grilling marker of hub session 11111111 lapsed'; check $? 0 "stale: the lapse is journaled"
setup; skill mattpocock-skills:grilling > /dev/null
age 6; succeed > $R/s2.out 2>&1; check $? 2 "stale, control: the 6-min-old mark still holds at the default bound (240)"
AGENT_HUB_GRILLING_STALE_MIN=5 succeed > $R/s3.out 2>&1; check $? 0 "stale: AGENT_HUB_GRILLING_STALE_MIN=5 lets the 6-min-old mark lapse"
setup; skill mattpocock-skills:grilling > /dev/null
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --handoff $H > /dev/null 2>&1
$B/hub grilling status --stage stage-a | grep -q '^no grilling in progress'; check $? 0 "takeover: the mark of the previous hub's session no longer holds"

# a Desktop hub has two ids: the mark is kept under the CLI one, which the hooks see, whichever names it
setup; usage 1000
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); h=d["roles"]["hub"]; h["session"]="local_abc123"; h["cli_session_id"]=sys.argv[2]; json.dump(d,open(p,"w"))' "$R/stage-a/roles.json" $HUB1
$B/hub grilling start --stage stage-a --session local_abc123 > /dev/null 2>&1; check "$(marked):$(marked local_abc123)" "yes:no" "alias: \`start --session local_…\` keeps the mark under the CLI id"
usage 510000; cbh PreToolUse Bash "$(bash_in 'ask close q-1 --answer B')" > $R/d1.out; check "$(wc -c < $R/d1.out | tr -d ' ')" 0 "alias: …so the hook (CLI id) sees it"
$B/hub grilling end --stage stage-a --session local_abc123 > /dev/null 2>&1; check "$(marked)" no "alias: \`end --session local_…\` removes it"
# an unreadable registry is not a takeover; a mark that cannot be removed is not reported as ended
setup; skill mattpocock-skills:grilling > /dev/null
cp $R/stage-a/roles.json $R/roles.bak; echo '{broken' > $R/stage-a/roles.json
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import grilling; assert grilling.active(sys.argv[2])' "$B" $HUB1; check "$?:$(marked)" "0:yes" "registry unreadable: the mark keeps holding, and stays"
cp $R/roles.bak $R/stage-a/roles.json
chmod 555 $AGENT_HUB_STATE_DIR/grilling
$B/hub grilling end --stage stage-a > $R/e1.out 2>&1; rc=$?
chmod 755 $AGENT_HUB_STATE_DIR/grilling
check "$rc:$(grep -c 'cannot remove the grilling mark' $R/e1.out):$(marked)" "1:1:yes" "end: a mark that cannot be removed is an error, not \"ended\""

# ================================================================== a successor started before the grilling began
setup; CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus > $R/t0.out 2>&1; check $? 0 "takeover: a successor is started (no grilling yet)"
skill mattpocock-skills:grilling > /dev/null
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --fallback > $R/t1.out 2>&1; check "$?:$(grep -c 'grilling with the owner is in progress' $R/t1.out)" "2:1" "fallback: refused while grilling"
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/t2.out 2>&1; check "$?:$($B/roles --stage stage-a get hub)" "2:$HUB1" "takeover: the successor's automatic takeover waits while the hub grills the owner"
grep -q 'an automatic takeover waits until it ends' $R/t2.out; check $? 0 "takeover: …and says why"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub grilling end > /dev/null
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/t3.out 2>&1; check "$?:$($B/roles --stage stage-a get hub)" "0:$HUB2" "takeover, control: after \`hub grilling end\` it goes ahead"
setup; skill mattpocock-skills:grilling > /dev/null
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --owner-asked > $R/t4.out 2>&1; check $? 0 "takeover: \`hub succeed --owner-asked\` starts a successor mid-grilling"
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/t5.out 2>&1; check "$?:$($B/roles --stage stage-a get hub)" "0:$HUB2" "takeover: …and its automatic takeover goes ahead"

# ================================================================== hub succeed / hub handoff
setup; skill mattpocock-skills:grilling > /dev/null
succeed > $R/h1.out 2>&1; rc=$?
check "$rc:$(grep -c 'a grilling with the owner is in progress in the hub of stage stage-a' $R/h1.out)" "2:1" "succeed: refused while grilling, autopilot on (exit 2)"
grep -q -- '--owner-asked' $R/h1.out && grep -qF 'grilling end --stage stage-a' $R/h1.out; check $? 0 "succeed: …the refusal names \`hub grilling end\` and --owner-asked"
check "$(call_count=$(grep -c '"--bg"' $R/bg.log 2>/dev/null); echo ${call_count:-0})" 0 "succeed: …and starts nothing"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --dry-run --again > $R/h1b.out 2>&1; check $? 2 "succeed: --again is refused too"
succeed --owner-asked > $R/h2.out 2>&1; check $? 0 "succeed: --owner-asked (the owner asked for the handoff) passes"
AGENT_HUB_AUTO_HANDOFF=off succeed --force > $R/h3.out 2>&1; check $? 0 "succeed: autopilot off, the owner by hand (--force) is not held"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a > $R/h4.out 2>&1; check "$?:$(grep -c 'hub handoff: a grilling with the owner is in progress' $R/h4.out)" "2:1" "handoff: the draft is refused while grilling, autopilot on"
AGENT_HUB_AUTO_HANDOFF=off CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a --out $R/off.md > $R/h5.out 2>&1; check $? 0 "handoff: autopilot off, a handoff by hand is not held"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a --owner-asked --out $R/asked.md > $R/h6.out 2>&1; check $? 0 "handoff: --owner-asked writes the draft"
grep -q '^5\. A grilling with the owner was in progress .*resume it .*TODO: .*`ask` ids.*open frontier.*next round' $R/asked.md; check $? 0 "handoff: …whose § 0 carries the grilling as a TODO the successor resumes from"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a --finish --handoff $R/asked.md > $R/h7.out 2>&1; check $? 2 "handoff: …and --finish refuses it until that item is filled"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub grilling end > /dev/null
succeed > $R/h8.out 2>&1; check $? 0 "succeed, control: after \`hub grilling end\` it passes without a flag"
CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub handoff --stage stage-a --out $R/plain.md > /dev/null 2>&1; grep -q 'A grilling with the owner' $R/plain.md; check $? 1 "handoff, control: a draft written with no grilling has no grilling item"
exit $fail
