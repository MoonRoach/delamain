#!/bin/bash
# `ask inbox`: the owner's digest across stages — content, size cap, --since, --if-quiet on both sides of the threshold,
# --json, read-only. A fixture hub home with three stages (relative to the clock, UTC): `quiet-s` (the owner's last answer
# 5 h ago, nothing newer), `overdue-s` (an overdue question, a blocked and a live agent) and `busy-s` (D- decisions and
# DONE / MERGED / released lines).
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; O=$(mktemp -d)   # outputs go to $O, so the read-only check sees only the hub home
unset AGENT_HUB_OWNER_DIGEST_AFTER

# gen.py ARGS: writes the fixture; `answer H` adds an owner answer H hours ago to quiet-s
GEN="$R/gen.py"
cat > "$GEN" <<'PY'
import datetime as dt, json, os, sys
root = os.environ["AGENT_HUB_HOME"]
now = dt.datetime.now(dt.timezone.utc).replace(second=0, microsecond=0, tzinfo=None)
ago = lambda h: now - dt.timedelta(hours=h)
st = lambda t: t.strftime("%Y-%m-%d %H:%M")
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M")

def reg(stage, prefix, blocks):
    d = os.path.join(root, stage); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "questions.md"), "w") as f:
        f.write(f"# Owner questions — {stage}\n\n<!-- ask:v1 prefix={prefix} -->\n" + "".join(blocks))

def q(i, title, status, asked, due="not set", default="not set"):
    return (f"\n## Q-{i} — {title}\n- kind: question\n- status: {status}\n- asked: {st(asked)}\n- by: hub-1\n- due: {due}\n"
            f"- blocks: x\n- default: {default}\n- source: test\n")

def dec(i, title, at):
    return (f"\n## D-{i} — {title}\n- kind: decided\n- status: standing\n- asked: {st(at)}\n- by: hub-1\n- alternative: none\n"
            f"- contest: decided by default — the owner may contest\n- source: test\n")

def journal(stage, lines):
    d = os.path.join(root, stage, "coordinator", "work"); os.makedirs(d, exist_ok=True)
    by_day = {}
    for t, tag, text in lines:
        by_day.setdefault(t.date().isoformat(), []).append(f"- {t:%H:%M} [{tag}] {text}\n")
    for day, ls in by_day.items():
        with open(os.path.join(d, f"journal-{day}.md"), "a") as f:
            f.writelines(ls)

def roles(stage, spec):
    os.makedirs(os.path.join(root, stage), exist_ok=True)
    with open(os.path.join(root, stage, "roles.json"), "w") as f:
        json.dump({"version": 1, "roles": {r: {"kind": "headless", "tag": r} for r in spec}}, f)
    for r, (pid, sid) in spec.items():
        d = os.path.join(root, stage, "agents", r); os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "meta.json"), "w") as f:
            json.dump({"role": r, "tag": r, "stage": stage, "pid": pid, "session_id": sid, "dir": d}, f)

if sys.argv[1] == "answer":   # a fresh owner answer in quiet-s
    h = float(sys.argv[2])
    with open(os.path.join(root, "quiet-s", "questions.md"), "a") as f:
        f.write(q("QU-002", "Fresh question", f"answered: yes ({st(ago(h))})", ago(h + 1)))
    sys.exit(0)

if sys.argv[1] == "many":     # twelve stages with news: the size cap
    for n in range(12):
        s = f"many-{n:02d}"
        reg(s, f"M{n:02d}", [q(f"M{n:02d}-001", f"A fairly long question number {n} about the release plan and the data", "open",
                               ago(30), iso(ago(5)), "take the safe option and carry on with the rest of the work"),
                             q(f"M{n:02d}-002", f"Second question {n}", "open", ago(30), iso(ago(-9)), "wait"),
                             dec(f"M{n:02d}-003", f"A decision the hub took on its own number {n}, with a long enough text", ago(2))])
        journal(s, [(ago(1), "w", f"DONE /x/y/work-{n}-REPORT.md PR #{n}: a sentence about what changed and where it shows")])
    sys.exit(0)

if sys.argv[1] == "overdue28":   # 28 stages, one overdue question each, nothing else
    for n in range(28):
        reg(f"ov-{n:02d}", f"V{n:02d}", [q(f"V{n:02d}-001", f"Overdue question number {n}", "open", ago(40), iso(ago(30)), "carry on")])
    sys.exit(0)

if sys.argv[1] == "first20":    # the most urgent stage has more overdue questions than fit, the others one each
    reg("aa-first", "FI", [q(f"FI-{n:03d}", f"Overdue question number {n} of the first stage, with a longer text", "open",
                             ago(60), iso(ago(50 - n)), "carry on with the safe default") for n in range(20)])
    for n in range(27):
        reg(f"ov-{n:02d}", f"V{n:02d}", [q(f"V{n:02d}-001", f"Overdue question number {n}", "open", ago(40), iso(ago(30)), "carry on")])
    sys.exit(0)

if sys.argv[1] == "agents":     # live-s: two live agents and no other news; idle-s: nothing; bk-s: blocked three days ago
    pid = sys.argv[2]
    roles("live-s", {"w1": (int(pid), "sid-live"), "w2": (int(pid), "sid-live")})
    reg("idle-s", "ID", [])
    roles("bk-s", {"w1": (999999, "sid-dead")})
    journal("bk-s", [(ago(73), "w1", "DONE old finished thing"), (ago(71), "w1", "BLOCKED waits for the hub")])
    sys.exit(0)

if sys.argv[1] == "edge":       # DONE two minutes ago (journal minute precision)
    journal("edge-s", [(now - dt.timedelta(minutes=2), "a", "DONE just before the since boundary")])
    sys.exit(0)

if sys.argv[1] == "bad":        # a register with a broken UTF-8 byte and an overdue question
    reg("bad-s", "BD", [q("BD-001", "Overdue", "open", ago(40), iso(ago(30)), "x")])
    with open(os.path.join(root, "bad-s", "questions.md"), "ab") as f:
        f.write(b"\n<!-- \xff -->\n")
    reg("good-s", "GD", [q("GD-001", "Fine", "open", ago(2), iso(ago(-5)), "y")])
    sys.exit(0)

pid, sid = sys.argv[2], sys.argv[3]
reg("quiet-s", "QU", [q("QU-001", "Old question", f"answered: ok ({st(ago(5))})", ago(6)),
                      dec("QU-003", "An old decision", ago(72))])
journal("quiet-s", [(ago(6), "w", "DONE old work before the window")])
reg("overdue-s", "OV", [q("OV-001", "Ship the release?", "open", ago(40), iso(ago(30)), "ship it"),
                        q("OV-002", "Rename the service?", "open", ago(10), iso(ago(-20)), "keep the name"),
                        q("OV-003", "Third", "default-taken: 2026-01-01", ago(10), iso(ago(9)), "done by default")])
journal("overdue-s", [(ago(3), "w1", "@hub QUESTION which branch?"), (ago(3), "w1", "BLOCKED /r/w1-REPORT.md waits for the hub"),
                      (ago(2), "w2", "PROGRESS half way")])
roles("overdue-s", {"w1": (999999, "sid-dead"), "w2": (int(pid), sid), "w3": (int(pid), "some-other-session")})
reg("busy-s", "BU", [dec("BU-001", "Use Parquet for the export", ago(3)), dec("BU-002", "Older decision outside the window", ago(8))])
journal("busy-s", [(ago(8), "a", "DONE long before the window"),
                   (ago(4), "a", "DONE a-REPORT.md first thing finished"),
                   (ago(2), "b", "MERGED PR #7 second thing"),
                   (ago(1.5), "cli", "@a (session resumed) report DONE when finished"),
                   (ago(1.2), "a", "PROGRESS almost DONE"),
                   (ago(1), "c", "DONE /abs/path/to/c-REPORT.md PR https://github.com/x/y/pull/9 — third thing finished")])
journal("busy-s", [(ago(0.5), "hub-1", "released 1.2.3 to the tap")])
PY

# a live process whose command line holds a session id, the way `agent status` recognises a live agent
python3 -c 'import time; time.sleep(300)' sid-live &
LIVE=$!
trap 'kill $LIVE 2>/dev/null; test_cleanup' EXIT
python3 "$GEN" fixture "$LIVE" sid-live
before=$(snap "$R")

# ---- content
$B/ask inbox > $O/inbox.out 2> $O/inbox.err; check $? 0 "inbox runs"
check "$(wc -c < $O/inbox.err | tr -d ' ')" 0 "…and prints nothing on stderr"
[ "$(wc -c < $O/inbox.out)" -le 2000 ]; check $? 0 "text digest within 2000 characters"
sed -n 1p $O/inbox.out | grep -q '^Since .* (your last answer, 5 h .* ago): 3 questions wait for you (1 overdue), 4 done, 1 decision by the hubs\.$'
check $? 0 "header: since the owner's last answer, totals first"
check "$(grep -n '^overdue-s — ' $O/inbox.out | cut -d: -f1)" 2 "the stage with the overdue question comes first"
grep -q '^overdue-s — 3 questions (1 overdue), 1 blocked, 1 live$' $O/inbox.out; check $? 0 "overdue-s: question, blocked and live counts (a reused pid is not live)"
grep -q '^  Q-OV-001 overdue 30 h .*: Ship the release? → default: ship it$' $O/inbox.out; check $? 0 "the overdue question carries its text and default"
grep -q '^  Q-OV-002 due ' $O/inbox.out; check $? 0 "an open question shows its due time"
l1=$(grep -n 'Q-OV-001' $O/inbox.out | cut -d: -f1); l2=$(grep -n 'Q-OV-002' $O/inbox.out | cut -d: -f1)
[ "$l1" -lt "$l2" ]; check $? 0 "overdue first"
grep -q '^busy-s — 4 done, 1 decision$' $O/inbox.out; check $? 0 "busy-s: DONE / MERGED / released lines counted, PROGRESS and an addressed line are not"
grep -q '^  last done [0-9][0-9]\.[0-9][0-9] [0-9:]* hub-1 released: 1\.2\.3 to the tap$' $O/inbox.out; check $? 0 "the last finished line is shown"
grep -q '^  D-BU-001 (decided by the hub): Use Parquet for the export$' $O/inbox.out; check $? 0 "the hub's decision since is listed"
grep -q 'D-BU-002\|D-QU-003' $O/inbox.out; check $? 1 "negative: a decision before the window is not"
grep -q '^1 stage quiet: quiet-s$' $O/inbox.out; check $? 0 "the quiet stage is one summary line"
grep -q 'quiet-s —' $O/inbox.out; check $? 1 "negative: a quiet stage has no block of its own"
[ "$(snap "$R")" = "$before" ]; check $? 0 "read-only: the hub home is byte-identical after the runs"

# --since narrows the window
$B/ask inbox --stage busy-s --since 70m > $O/s70.out
grep -q 'last done .* hub-1 released' $O/s70.out; check $? 0 "--since 70m keeps the newest line"
$B/ask inbox --stage busy-s --since 100m > $O/s100.out
grep -q '^busy-s — 2 done$' $O/s100.out && ! grep -q 'D-BU-001' $O/s100.out; check $? 0 "--since 100m: the c and released lines only, the 3 h old decision is out"
$B/ask inbox --stage busy-s --since 70m --json > $O/c.json
python3 - "$O/c.json" <<'PY'; check $? 0 "--since 70m --json: the c line, path shortened, URL kept"
import json, sys
d = json.load(open(sys.argv[1]))
lines = d["stages"][0]["done"]["lines"]
assert d["since_source"] == "--since", d
assert [l["tag"] for l in lines] == ["c", "hub-1"], lines
assert lines[0]["text"] == "c-REPORT.md PR https://github.com/x/y/pull/9 — third thing finished", lines[0]
PY

# ---- --stage, --json
$B/ask inbox --stage busy-s > $O/one.out; sed -n 1p $O/one.out | grep -q 'questions wait'; check $? 1 "--stage busy-s: only its own totals"
$B/ask inbox --stage nosuch > /dev/null 2>&1; check $? 1 "negative: an unknown stage is refused"
$B/ask inbox --since yesterdayish > /dev/null 2>&1; check $? 1 "negative: an unparsable --since is refused"
$B/ask inbox --json > $O/all.json
python3 - "$O/all.json" <<'PY'; check $? 0 "--json: the whole digest, structured"
import json, sys
d = json.load(open(sys.argv[1]))
names = [s["stage"] for s in d["stages"]]
assert names == sorted(names, key=lambda n: {"overdue-s": 0, "busy-s": 1}[n]), names
assert d["quiet_stages"] == ["quiet-s"], d["quiet_stages"]
assert d["last_answer"]["id"] == "Q-QU-001" and d["since_source"] == "owner-answer" and d["quiet"] is True, d
ov = d["stages"][0]
assert [w["id"] for w in ov["waiting"]] == ["Q-OV-001", "Q-OV-003", "Q-OV-002"], ov["waiting"]
assert ov["waiting"][0]["overdue"] and ov["waiting"][0]["default"] == "ship it", ov["waiting"][0]
assert ov["agents"] == {"live": 1, "blocked": 1}, ov["agents"]
busy = d["stages"][1]
assert busy["done"]["count"] == 4 and [x["id"] for x in busy["decided"]] == ["D-BU-001"], busy
assert d["threshold"] == "180m", d["threshold"]
PY

# ---- --if-quiet: the owner's last answer is 5 h old
$B/ask inbox --if-quiet > $O/q1.out 2>&1; check $? 0 "--if-quiet exits 0"
[ -s $O/q1.out ] && grep -q '^Since ' $O/q1.out; check $? 0 "--if-quiet prints the digest after 5 h of silence (threshold 3h)"
AGENT_HUB_OWNER_DIGEST_AFTER=6h $B/ask inbox --if-quiet > $O/q2.out 2>&1; check $? 0 "--if-quiet, threshold 6h: exits 0"
[ -s $O/q2.out ]; check $? 1 "negative: threshold 6h, answered 5 h ago: prints nothing"
echo '{"AGENT_HUB_OWNER_DIGEST_AFTER": "6h"}' > $R/config.json
$B/ask inbox --if-quiet > $O/q3.out 2>&1
[ -s $O/q3.out ]; check $? 1 "the threshold read from the hub home's config.json: prints nothing"
AGENT_HUB_OWNER_DIGEST_AFTER=2h $B/ask inbox --if-quiet > $O/q4.out 2>&1
grep -q '^Since ' $O/q4.out; check $? 0 "the environment beats config.json (2h: the digest is shown)"
AGENT_HUB_OWNER_DIGEST_AFTER=6h $B/ask inbox --if-quiet --json > $O/q5.out 2>&1; [ -s $O/q5.out ]; check $? 1 "--if-quiet --json inside the threshold: prints nothing"
rm $R/config.json
AGENT_HUB_OWNER_DIGEST_AFTER=soon $B/ask inbox --if-quiet > $O/q6.out 2> $O/q6.err
grep -q 'AGENT_HUB_OWNER_DIGEST_AFTER' $O/q6.err && grep -q '^Since ' $O/q6.out; check $? 0 "a bad value warns on stderr and falls back to 3h"
python3 "$GEN" answer 1
$B/ask inbox --if-quiet > $O/q7.out 2>&1; [ -s $O/q7.out ]; check $? 1 "the owner answered 1 h ago (threshold 3h): prints nothing"
$B/ask inbox > $O/q8.out; sed -n 1p $O/q8.out | grep -q '^Since .* (your last answer, 6[01] min ago)'; check $? 0 "without --if-quiet the digest is still available, counted since that answer"
AGENT_HUB_OWNER_DIGEST_AFTER=30m $B/ask inbox --if-quiet > $O/q9.out 2>&1; grep -q '^Since ' $O/q9.out; check $? 0 "threshold 30m, answered 1 h ago: the digest is shown"
# no answer anywhere: 24 h window, and quiet
E=$(mktemp -d); mkdir -p $E/s1/coordinator/work; AGENT_HUB_HOME=$E $B/ask inbox --if-quiet > $O/e.out 2>&1
grep -q '^Since .* (last 24 h, 24 h .* ago): nothing new\. 1 stage quiet: s1$' $O/e.out; check $? 0 "no answer in any register: 24 h window, nothing new"

# ---- the size cap with twelve stages that have news
python3 "$GEN" many
$B/ask inbox --since 6h --stage many-00 --stage many-01 --stage many-02 --stage many-03 --stage many-04 --stage many-05 \
    --stage many-06 --stage many-07 --stage many-08 --stage many-09 --stage many-10 --stage many-11 > $O/many.out
chars=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' $O/many.out)
[ "$chars" -le 2000 ]; check $? 0 "twelve active stages: output within 2000 characters ($chars)"
grep -q 'more: ask inbox --stage many-' $O/many.out; check $? 0 "…the cut is announced with a command to see the rest"
grep -q '^many-00 — ' $O/many.out && grep -q '^many-11 — \|more stage' $O/many.out; check $? 0 "…every stage with news is a summary line or named in 'more stages'"
grep -q 'M00-001 overdue' $O/many.out; check $? 0 "…overdue questions are kept first"
$B/ask inbox --since 6h --stage many-11 > $O/m11.out; grep -q 'D-M11-003' $O/m11.out && ! grep -q 'more: ask inbox' $O/m11.out; check $? 0 "the stage named in the cut shows everything on its own"
$B/ask inbox --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["stages"])==14, len(d["stages"])'; check $? 0 "--json is not cut"

# ---- review round 1 (each check fails on the first version of the command)
# the cut keeps the overdue question lines of the most urgent stages; the stages that no longer fit are named in one line
new_home; R2=$AGENT_HUB_HOME
python3 "$GEN" overdue28
$B/ask inbox --since 6h > $O/o28.out
chars=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' $O/o28.out)
[ "$chars" -le 2000 ]; check $? 0 "28 stages with one overdue question each: within 2000 characters ($chars)"
grep -q 'Q-V00-001 overdue' $O/o28.out; check $? 0 "…the first stage's overdue question is in the output"
s=$(grep -c '^ov-[0-9][0-9] — ' $O/o28.out); q=$(grep -c '^  Q-V[0-9][0-9]-001 overdue' $O/o28.out)
[ "$s" = "$q" ] && [ "$s" -ge 5 ]; check $? 0 "…every stage shown keeps its overdue question line ($s stages, $q questions)"
grep -q '^[0-9]* more stages with news: ask inbox --stage ov-' $O/o28.out; check $? 0 "…the stages that do not fit are named in one line"

# the most urgent stage has more overdue questions than fit: as many as fit (the most overdue first), never none
new_home
python3 "$GEN" first20
$B/ask inbox --since 6h > $O/f20.out
chars=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' $O/f20.out)
[ "$chars" -le 2000 ]; check $? 0 "first stage with 20 overdue questions: within 2000 characters ($chars)"
grep -q '^  Q-FI-000 overdue' $O/f20.out; check $? 0 "…its most overdue question is in the output"
n=$(grep -c '^  Q-FI-' $O/f20.out); [ "$n" -ge 1 ] && [ "$n" -lt 20 ]; check $? 0 "…as many of its overdue questions as fit ($n of 20)"
grep -q '^aa-first — 20 questions (20 overdue) \[[0-9]* more: ask inbox --stage aa-first\]' $O/f20.out; check $? 0 "…the rest is announced as 'K more'"

# a stage with live agents is not idle; blocked now does not depend on the window
new_home; R2=$AGENT_HUB_HOME
python3 "$GEN" agents "$LIVE"
$B/ask inbox --since 1h > $O/ag.out
grep -q 'quiet: idle-s, live-s (2 live)$' $O/ag.out; check $? 0 "text: a stage with only live agents shows its count in the quiet line"
$B/ask inbox --since 1h --json > $O/ag.json
python3 - "$O/ag.json" <<'PY'; check $? 0 "--json: agent counts for every stage; blocked since three days ago still counts with --since 1h"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["agents"]["live-s"] == {"live": 2, "blocked": 0}, d["agents"]
assert d["agents"]["idle-s"] == {"live": 0, "blocked": 0}, d["agents"]
assert d["agents"]["bk-s"]["blocked"] == 1, d["agents"]
bk = [s for s in d["stages"] if s["stage"] == "bk-s"]
assert bk and bk[0]["agents"]["blocked"] == 1 and bk[0]["done"]["count"] == 0, d["stages"]
assert "bk-s" not in d["quiet_stages"] and "live-s" in d["quiet_stages"], d["quiet_stages"]
PY
grep -q '^bk-s — 1 blocked' $O/ag.out; check $? 0 "text: the blocked stage has its own line"

# minute precision: the journal says 10:00, since is 10:00:30
for attempt in 1 2 3; do
    new_home; m1=$(date -u +%M); python3 "$GEN" edge
    $B/ask inbox --stage edge-s --since 90s > $O/edge.out; m2=$(date -u +%M)
    [ "$m1" = "$m2" ] && break
done
grep -q '^edge-s — 1 done' $O/edge.out; check $? 0 "a DONE line two minutes ago is counted with --since 90s (the boundary minute is kept)"

# an unreadable register is not "no questions"
new_home; python3 "$GEN" bad
$B/ask inbox --since 6h > $O/bad.out 2> $O/bad.err; check $? 0 "unreadable register: the digest still exits 0"
grep -q 'bad-s/questions.md' $O/bad.err; check $? 0 "…stderr names the file"
grep -q '^bad-s — register unreadable' $O/bad.out; check $? 0 "…the text marks the stage"
grep -q 'quiet: .*bad-s\|quiet: bad-s' $O/bad.out; check $? 1 "…and never lists it as quiet"
grep -q 'good-s — 1 question' $O/bad.out; check $? 0 "…the other stages are served"
$B/ask inbox --since 6h --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); b=[s for s in d["stages"] if s["stage"]=="bad-s"][0]; assert b["register_unreadable"] is True and "bad-s" not in d["quiet_stages"]'; check $? 0 "…--json says so"

# ---- docs and skill
grep -q 'ask inbox --if-quiet' "$T/../skills/hub/SKILL.md"; check $? 0 "the hub skill names the digest command"
grep -q 'AGENT_HUB_OWNER_DIGEST_AFTER' "$T/../docs/reference.md"; check $? 0 "the setting is documented"
grep -q '`ask inbox`' "$T/../docs/reference.md"; check $? 0 "the command is in the reference"
exit $fail
