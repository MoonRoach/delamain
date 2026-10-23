#!/bin/bash
# Lessons of the shift (AGENT_HUB_HANDOFF_LESSONS, hub home only, off by default): with the setting on, `hub handoff` adds an
# optional § 7 and `--finish` / `succeed --handoff` WARN (never refuse) while it holds TODO; <stage>/lessons.md is pointed at
# by the takeover digest whenever it exists. Off, the draft is what it always was.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; HUB1=11111111-1111-4111-8111-111111111111; HUB2=22222222-2222-4222-8222-222222222222
export CLAUDE_BIN=$T/fake_claude_bg.py FAKE_AGENTS=none FAKE_BG_LOG=$R/bg.log   # never the real `claude`
$B/hub start --stage stage-a --session $HUB1 > $R/start.out 2>&1; check $? 0 "setup: hub start"
C=$R/stage-a/coordinator; L=$R/stage-a/lessons.md
WARN='ATTENTION: § 7 (lessons) still holds TODO'
# fill_012 SRC DST: TODO of § 0–2 replaced, the rest (§ 3–7) untouched
fill_012() { python3 - "$1" "$2" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
out = []
for p in re.split(r"(?m)^(?=## )", t):
    m = re.match(r"## (\d)\.", p)
    out.append(p.replace("TODO", "done:") if m and int(m.group(1)) <= 2 else p)
open(sys.argv[2], "w", encoding="utf-8").write("".join(out))
PY
}

# 1. off (the default)
$B/hub handoff --stage stage-a --n 1 --out $C/off.md > $R/o1.out 2>&1; check $? 0 "off: the draft is written"
grep -q '^## 7\.' $C/off.md; check $? 1 "off: no § 7"
fill_012 $C/off.md $C/off-filled.md
$B/hub handoff --stage stage-a --finish --handoff $C/off-filled.md > $R/o2.out 2> $R/o2.err; check $? 0 "off: --finish on a filled draft passes"
grep -q 'lessons' $R/o2.err; check $? 1 "off: no lessons warning"
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/off-filled.md --dry-run > $R/o3.out 2>&1; check $? 0 "off: takeover dry run"
grep -q 'Lessons of earlier shifts' $R/o3.out; check $? 1 "off: no lessons line in the digest without a file"

# 2. on, through the hub home's config.json: a JSON boolean and the word "on"
echo '{"AGENT_HUB_HANDOFF_LESSONS": true}' > $R/config.json
$B/hub handoff --stage stage-a --n 1 --out $C/on1.md > $R/n1.out 2>&1; check $? 0 "on (true): the draft is written"
grep -q '^## 7\. Lessons of this shift' $C/on1.md && grep -q "$L" $C/on1.md; check $? 0 "on (true): § 7 with the real path of lessons.md"
sed -n '/^## 7\./,$p' $C/on1.md | grep -q 'TODO ids (L-…)' && sed -n '/^## 7\./,$p' $C/on1.md | grep -q 'TODO "L-… helped'; check $? 0 "on: § 7 has its TODO"
grep -q '^Open lessons to judge: none yet$' $C/on1.md; check $? 0 "on: no lessons file: \"none yet\""
python3 - $C/on1.md <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
assert t.index("## 6. Skills") < t.index("## 7. Lessons") < t.index("<!-- Last [hub-1] journal lines"), "order"
PY
check $? 0 "on: § 7 comes after § 6 and before the journal comment"
echo '{"AGENT_HUB_HANDOFF_LESSONS": "on"}' > $R/config.json
$B/hub handoff --stage stage-a --n 1 --out $C/on2.md > $R/n2.out 2>&1; check $? 0 "on (\"on\"): the draft is written"
grep -q '^## 7\.' $C/on2.md; check $? 0 "on (\"on\"): § 7 is there"

# 3. a lessons file of three entries: proposed, confirmed, retired
cat > $L <<'MD'
# Lessons — stage-a

## L-001 — before merging a change that touches the lock board
- status: proposed
- by: hub-1, 2026-10-20
- lesson: read lock list first.
- evidence: journal 10:12 [hub-1]
- confidence: low

## L-002 — when a reviewer returns no findings in a minute
- status: confirmed: 2026-10-21 hub-2
- by: hub-1, 2026-10-20
- lesson: check that it read the diff.
- evidence: ask Q-A-004
- confidence: medium
- verdict: hub-2 2026-10-21 helped — journal 14:03 [hub-2]

## L-003 — when a worker loops on one test
- status: retired: 2026-10-22 hub-3 — hurt
- by: hub-1, 2026-10-20
- lesson: stop it after three runs.
- evidence: journal 09:00 [hub-1]
- confidence: high
MD
$B/hub handoff --stage stage-a --n 1 --out $C/on3.md > $R/n3.out 2>&1; check $? 0 "on, 3 lessons: the draft is written"
OPEN=$(grep '^Open lessons to judge:' $C/on3.md)
case "$OPEN" in *"L-001 before merging a change that touches the lock board"*"L-002 when a reviewer"*) r=0;; *) r=1;; esac; check $r 0 "on: lists the proposed and the confirmed lesson, in file order"
case "$OPEN" in *L-003*|*"worker loops"*) r=1;; *) r=0;; esac; check $r 0 "on: …and not the retired one"
{ for i in 1 2 3 4 5 6 7 8 9 10; do printf '## L-%03d — cue number %d\n- status: proposed\n- evidence: x\n\n' $((i+10)) $i; done; } >> $L
$B/hub handoff --stage stage-a --n 1 --out $C/on4.md > $R/n4.out 2>&1
grep '^Open lessons to judge:' $C/on4.md | grep -q '… 4 more$'; check $? 0 "on: more than 8 open lessons: the first 8, then \"… 4 more\""
# back to a short file for the digest checks below
cat > $L <<'MD'
## L-001 — first
- status: proposed
- evidence: x

## L-002 — second
- status: confirmed: 2026-10-21 hub-2
- evidence: x

## L-003 — third
- status: retired: 2026-10-22 hub-3 — hurt
- evidence: x
MD

# 4. --finish: a warning, never a refusal
fill_012 $C/on3.md $C/on3-filled.md
$B/hub handoff --stage stage-a --finish --handoff $C/on3-filled.md > $R/f1.out 2> $R/f1.err; check $? 0 "on: § 0–2 filled, § 7 TODO: --finish exits 0"
grep -qF "$WARN — write 0–3 lessons with evidence or \"none: <reason>\"" $R/f1.err; check $? 0 "…with the ATTENTION line on stderr"
grep -q 'handoff ready' $R/f1.out; check $? 0 "…and the ready line"
python3 - $C/on3-filled.md $C/on3-done.md <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r'(?m)^New entries in .*$', 'New entries: none: nothing came up.', t)
t = re.sub(r'(?m)^Verdicts on lessons .*$', 'Verdicts: L-002 helped — journal 14:03 [hub-2]', t)
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
$B/hub handoff --stage stage-a --finish --handoff $C/on3-done.md > $R/f2.out 2> $R/f2.err; check $? 0 "§ 7 filled: --finish passes"
grep -q 'lessons' $R/f2.err; check $? 1 "…without a lessons warning"
$B/hub handoff --stage stage-a --finish --handoff $C/off-filled.md > $R/f3.out 2> $R/f3.err; check $? 0 "a handoff without § 7 while the setting is on: --finish passes"
grep -qF 'ATTENTION: the handoff has no § 7 (lessons)' $R/f3.err; check $? 0 "…but warns: it was not written from this draft"
$B/hub handoff --stage stage-a --finish --handoff $C/on3.md > $R/f4.out 2> $R/f4.err; check $? 2 "negative: § 0–2 still TODO: --finish still exits 2"
grep -q 'still hold [0-9]* TODO line' $R/f4.err; check $? 0 "…for § 0–2"
$B/hub handoff --stage stage-a --finish --handoff $C/on3.md --allow-todo > $R/f5.out 2> $R/f5.err; check $? 0 "--allow-todo: exit 0"
grep -q 'ATTENTION: --allow-todo' $R/f5.err && grep -qF "$WARN" $R/f5.err; check $? 0 "…both warnings"

# 5. succeed shows the same warning
$B/hub succeed --stage stage-a --handoff $C/on3-filled.md --model opus --effort high --dry-run --cwd $R > $R/s1.out 2> $R/s1.err; check $? 0 "succeed --dry-run on a draft with § 7 TODO: exit 0"
grep -qF "$WARN" $R/s1.err; check $? 0 "…and the same warning"
grep -q '^\[plan\] auto-handoff' $R/s1.out; check $? 0 "…and the plan"
$B/hub succeed --stage stage-a --handoff $C/on3-done.md --model opus --effort high --dry-run --cwd $R > $R/s2.out 2> $R/s2.err; check $? 0 "succeed on a draft with § 7 filled: exit 0"
grep -q 'lessons' $R/s2.err; check $? 1 "…without a warning"
$B/hub succeed --stage stage-a --handoff $C/on3.md --model opus --effort high --dry-run --cwd $R > $R/s3.out 2> $R/s3.err; check $? 2 "negative: succeed on § 0–2 TODO still refuses"

# 6. takeover digest: the lessons line, on or off
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/on3-done.md --dry-run > $R/t1.out 2>&1; check $? 0 "takeover dry run with lessons.md"
grep -qF "Lessons of earlier shifts — read before planning; at your handoff give a verdict on each that acts in your shift: $L (proposed 1, confirmed 1)" $R/t1.out; check $? 0 "…the digest line with the right counts"
LINE=$(grep '^Lessons of earlier shifts' $R/t1.out | head -1); [ "$(printf %s "$LINE" | wc -c)" -le "$((260 + ${#L}))" ]; check $? 0 "…within 260 bytes besides the path"
echo '{}' > $R/config.json   # setting off again
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/off-filled.md --dry-run > $R/t2.out 2>&1; check $? 0 "takeover dry run, setting off, lessons.md present"
grep -qF "(proposed 1, confirmed 1)" $R/t2.out; check $? 0 "…the line is there whether or not the setting is on"

# 7. a repository's .agent-hub/config.json cannot switch it (negative control)
PROJ=$(mktemp -d); mkdir -p $PROJ/.git $PROJ/.agent-hub; echo '{"AGENT_HUB_HANDOFF_LESSONS": true}' > $PROJ/.agent-hub/config.json
echo '{}' > $R/config.json   # the home does not set it
( cd $PROJ && $B/hub handoff --stage stage-a --n 1 --out $C/proj.md > $R/p1.out 2> $R/p1.err ); check $? 0 "a repository's config: the draft is written"
grep -q '^## 7\.' $C/proj.md; check $? 1 "…and § 7 is not written: the repository cannot switch the setting on"
# the config layer says why when any setting is read from that repository (the handoff itself reads no repository key)
( cd $PROJ && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; hubcore.setting("AGENT_HUB_DEFAULT_EFFORT")' "$B" ) 2> $R/p2.err
grep -q 'AGENT_HUB_HANDOFF_LESSONS is not a setting this file may set (hub-wide: set it in the hub home' $R/p2.err; check $? 0 "…and the config layer refuses it with the hub-wide warning"

# 8. the 12 KB cut: a large register of facts forces it, § 7 and the journal comment survive whole
echo '{"AGENT_HUB_HANDOFF_LESSONS": true}' > $R/config.json
python3 - $R/stage-a/handoff-facts.sh <<'PY'
import sys
rows = "\n".join(f'echo "| Fact {i} | {"x" * 150} | `cmd {i}` |"' for i in range(120))
open(sys.argv[1], "w").write("#!/bin/sh\n" + rows + "\n")
PY
chmod +x $R/stage-a/handoff-facts.sh
for i in $(seq 1 30); do $B/ask add --stage stage-a --title "Question number $i with a long enough title to fill the digest line well" --by hub-1 > /dev/null 2>&1; done
$B/hub handoff --stage stage-a --n 1 --out $C/big.md > $R/b1.out 2>&1; check $? 0 "big draft: written"
SZ=$(wc -c < $C/big.md | tr -d ' '); [ "$SZ" -le 12288 ]; check $? 0 "…within 12 KB ($SZ bytes)"
grep -q '…cut' $C/big.md; check $? 0 "control: the cut did happen"
grep -q '^## 7\. Lessons of this shift' $C/big.md && grep -q '^Open lessons to judge: L-001 first; L-002 second$' $C/big.md; check $? 0 "…and § 7 survived whole"
tail -n 3 $C/big.md | grep -q -- '-->'; check $? 0 "…and the journal comment is closed"
$B/hub handoff --stage stage-a --finish --handoff $C/big.md --allow-todo > $R/b2.out 2> $R/b2.err; grep -qF "$WARN" $R/b2.err; check $? 0 "…and the cut draft still gets the § 7 warning"
# 9. review edge cases: the cut inside a comment, a damaged lessons.md, a huge id, code blocks, counts per entry
# 9a. the cut fell inside a comment of the front: it is closed before § 7, so a filled § 0–2 passes --finish and the TODO
# of § 7 is still seen. The facts' size is stepped until the cut point lands inside one.
for n in $(seq 40 4 140); do
  python3 - $R/stage-a/handoff-facts.sh $n <<'PY2'
import sys
rows = "\n".join(f'echo "| Fact {i} | {"x" * 60} | `cmd {i}` |"' for i in range(int(sys.argv[2])))
open(sys.argv[1], "w").write("#!/bin/sh\n" + rows + "\n")
PY2
  rm -f $C/cut-$n.md; $B/hub handoff --stage stage-a --n 1 --out $C/cut-$n.md > /dev/null 2>&1
  python3 - $C/cut-$n.md <<'PY2' && { CUT=$C/cut-$n.md; break; }
import sys
t = open(sys.argv[1], encoding="utf-8").read(); front = t[:t.index("## 7. Lessons")]
i = front.rfind("…cut")
sys.exit(0 if i > 0 and front.rfind("<!--", 0, i) > front.rfind("-->", 0, i) else 1)
PY2
done
[ -n "${CUT:-}" ]; check $? 0 "setup: a draft whose cut lands inside a comment (${CUT:-none})"
if [ -n "${CUT:-}" ]; then
  fill_012 $CUT $CUT.filled
  $B/hub handoff --stage stage-a --finish --handoff $CUT.filled > $R/c1.out 2> $R/c1.err; check $? 0 "…filled § 0–2: --finish passes (the open comment was closed before § 7)"
  grep -qF "$WARN" $R/c1.err; check $? 0 "…and § 7's TODO is still seen (a warning)"
fi
# 9b. a damaged lessons.md (not UTF-8) breaks neither the draft nor the takeover digest
cp $L $R/lessons.good; printf '## L-009 \xff\xfe broken\n- status: proposed\n' >> $L
rm -f $R/stage-a/handoff-facts.sh
$B/hub handoff --stage stage-a --n 1 --out $C/bad.md > $R/d1.out 2>&1; check $? 0 "damaged lessons.md: the draft is written"
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/on3-done.md --dry-run > $R/d2.out 2>&1; check $? 0 "…and the takeover digest is built"
grep -qF "(proposed 2, confirmed 1)" $R/d2.out; check $? 0 "…counting the readable entries"
# 9c. a huge id is not an entry
cp $R/lessons.good $L; { printf '## L-%s — flood\n- status: proposed\n' "$(printf '1%.0s' $(seq 1 3000))"; } >> $L
$B/hub handoff --stage stage-a --n 1 --out $C/flood.md > $R/f1.out 2>&1; check $? 0 "huge id: the draft is written"
grep -q 'L-1111' $C/flood.md; check $? 1 "…without the flooding entry"
SZ=$(wc -c < $C/flood.md | tr -d ' '); [ "$SZ" -le 12288 ]; check $? 0 "…within 12 KB ($SZ bytes)"
# 9d. code blocks: a heading or an entry inside a fence counts for nothing; counts are per entry, not per status line
cp $R/lessons.good $L
printf '%s\n' '' '```markdown' '## L-099 — an example entry' '- status: proposed' '```' >> $L
python3 - $L <<'PY2'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("- status: proposed", "- status: proposed\n- status: confirmed: 2026-10-23 hub-2", 1)  # two status lines, one entry
open(p, "w", encoding="utf-8").write(t)
PY2
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/on3-done.md --dry-run > $R/k1.out 2>&1; check $? 0 "fenced example: takeover dry run"
grep -qF "(proposed 1, confirmed 1)" $R/k1.out; check $? 0 "…counts per entry, the fenced example and the second status line not counted"
$B/hub handoff --stage stage-a --n 1 --out $C/fence.md > $R/k2.out 2>&1; grep -q 'L-099' $C/fence.md; check $? 1 "…and § 7 does not list the fenced example"
python3 - $C/on3-done.md $C/fence6.md $C/fence8.md <<'PY2'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("## 7. Lessons")
# § 6 quotes a § 7 heading in a code block: no warning comes from it (§ 7 itself is filled)
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + "```\n## 7. Lessons\nTODO example\n```\n\n" + t[i:])
# a fenced § 8 inside a § 7 that still holds TODO does not hide it
open(sys.argv[3], "w", encoding="utf-8").write(t[:i] + "## 7. Lessons of this shift\n```\n## 8. Example\n```\nNew entries: TODO ids\n\n")
PY2
$B/hub handoff --stage stage-a --finish --handoff $C/fence6.md > $R/k3.out 2> $R/k3.err; check $? 0 "a fenced § 7 heading in § 6: --finish passes"
grep -qF "$WARN" $R/k3.err; check $? 1 "…without a false warning"
$B/hub handoff --stage stage-a --finish --handoff $C/fence8.md > $R/k4.out 2> $R/k4.err; check $? 0 "a fenced § 8 heading inside § 7: --finish passes"
grep -qF "$WARN" $R/k4.err; check $? 0 "…and the TODO after it is still seen"
# 9e. a fence closes only on its own character and length: a ~~~ inside a ``` block, a ``` inside a ```` block
cp $R/lessons.good $L
printf '%s\n' '' '````markdown' '```' '## L-098 — a nested example' '- status: proposed' '```' '````' >> $L
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/on3-done.md --dry-run > $R/k5.out 2>&1
grep -qF "(proposed 1, confirmed 1)" $R/k5.out; check $? 0 "a \`\`\` block inside a \`\`\`\` one: its example entry is not counted"
python3 - $C/on3-done.md $C/fence-mixed.md <<'PY2'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("## 7. Lessons")
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + "## 7. Lessons of this shift\n```markdown\n~~~\n```\nNew entries: TODO ids\n\n")
PY2
$B/hub handoff --stage stage-a --finish --handoff $C/fence-mixed.md > $R/k6.out 2> $R/k6.err; check $? 0 "a ~~~ inside a \`\`\` block of § 7: --finish passes"
grep -qF "$WARN" $R/k6.err; check $? 0 "…and the TODO after the block is still seen"
# 10. a § 7 that answers nothing (personal-finance 23.10: "None recorded: lessons module not used", copied on by the next
# shift) warns at --finish, at succeed and at the successor's takeover; ids or "none: <reason>" are answers
python3 - $C/on3-done.md $C/dismiss.md <<'PY2'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("## 7. Lessons")
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + "## 7. Lessons of this shift\nNone recorded: lessons module not used in this repo.\n")
PY2
DISMISS='ATTENTION: § 7 (lessons) names no lesson id (L-…) and no "none: <reason>"'
$B/hub handoff --stage stage-a --finish --handoff $C/dismiss.md > $R/x1.out 2> $R/x1.err; check $? 0 "a dismissive § 7: --finish passes"
grep -qF "$DISMISS" $R/x1.err; check $? 0 "…and warns that § 7 answers nothing"
$B/hub succeed --stage stage-a --handoff $C/dismiss.md --model opus --effort high --dry-run --cwd $R > $R/x2.out 2> $R/x2.err; check $? 0 "succeed on it: exit 0"
grep -qF "$DISMISS" $R/x2.err; check $? 0 "…with the same warning"
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/dismiss.md --dry-run > $R/x3.out 2>&1; check $? 0 "takeover from it (dry run)"
grep -qF "ATTENTION: the handoff dismiss.md: § 7 (lessons) names no lesson id" $R/x3.out && grep -q 'ask it to fill § 7 before it ends' $R/x3.out; check $? 0 "…warns the successor and says what to do"
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/off-filled.md --dry-run > $R/x4.out 2>&1
grep -qF "ATTENTION: the handoff off-filled.md: the handoff has no § 7 (lessons)" $R/x4.out; check $? 0 "takeover from a handoff without § 7 warns too"
$B/hub takeover --stage stage-a --session $HUB2 --handoff $C/on3-done.md --dry-run > $R/x5.out 2>&1
grep -q 'ATTENTION: the handoff on3-done.md' $R/x5.out; check $? 1 "control: an answered § 7 gives no takeover warning"
grep -q 'lessons module is ON in this hub home' $C/on1.md; check $? 0 "the draft's § 7 says the module is on and what to do"
grep -qi 'optional module' $C/on1.md && sed -n '/^## 7\./,$p' $C/on1.md | grep -qi 'optional module'; check $? 1 "…and no longer calls itself an optional module"
# 10b. placeholders are not answers: none: n/a, none: TBD, a bare none:, a quoted copy of the "Open lessons" line
for v in 'New entries: none: n/a' 'New entries: none: TBD.' 'New entries: none:
Verdicts: none' 'None recorded: not used.
> Open lessons to judge: L-001 first' 'None recorded.
   Open lessons to judge: L-001 first'; do
  python3 - $C/on3-done.md $C/ph.md "$v" <<'PY2'
import sys
t = open(sys.argv[1], encoding="utf-8").read(); i = t.index("## 7. Lessons")
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + "## 7. Lessons of this shift\n" + sys.argv[3] + "\n")
PY2
  $B/hub handoff --stage stage-a --finish --handoff $C/ph.md > $R/ph.out 2> $R/ph.err
  grep -qF "$DISMISS" $R/ph.err; check $? 0 "placeholder answer warns: $(printf %s "$v" | head -1)"
done
exit $fail
