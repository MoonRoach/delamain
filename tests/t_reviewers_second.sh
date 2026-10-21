#!/bin/bash
# hub reviewer --second: an optional second opinion. An entry with "second": true serves second opinions only (a plain
# walk skips it, check unrun); --second picks the primary exactly as the plain walk does and then the first other
# available entry in list order, ordinary or `second` alike; exit 1 only means no second opinion. Skill names are stand-ins.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; export PYTHONDONTWRITEBYTECODE=1
P=$(mktemp -d); OUT=$P/outside; mkdir -p $OUT
rv(){ (cd $OUT && $B/hub reviewer --author claude "$@"); }
chosen(){ rv "$@" 2>/dev/null | sed -n 's/^reviewer: \([^ ]*\) .*/\1/p'; }
jf(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
cfg(){ printf '{"AGENT_HUB_REVIEWERS": %s}\n' "$1" > $R/config.json; }
S='{"name": "argon", "kind": "skill", "skill": "delamain:agy-review", "second": true, "for": ["code", "risky"], "check": "touch '$P'/ran-argon"}'
A='{"name": "skill-a", "kind": "skill", "skill": "my-review-skill"}'
G='{"name": "agent", "kind": "agent", "model": "sonnet", "effort": "high"}'

# ---- a plain walk skips a second-only entry, even when it is first in the list and available
cfg "[$S, $A, $G]"; rm -f $P/ran-argon
check "$(chosen --for code)" skill-a "plain walk: the second-only entry listed first is passed over"
[ -e $P/ran-argon ]; check $? 1 "…its check was not even run"
rv --for code --all > $P/all.out 2>/dev/null
grep -q 'argon (skill delamain:agy-review): not available — serves second opinions only (hub reviewer --second)' $P/all.out; check $? 0 "…--all says why"
rv --for code --json > $P/plain.json 2>/dev/null
check "$(jf '"second" in d or "primary" in d' < $P/plain.json)" False "plain --json has no second/primary keys (unchanged for a plain walk)"
check "$(jf '[("second" in e) for e in d["entries"]]' < $P/plain.json)" "[True, False]" "…the skipped second entry is marked second in its entry, the chosen ordinary one is not"
cfg "[$A, $G]"; rv --for code --json > $P/plain2.json 2>/dev/null
check "$(jf 'sorted(d)' < $P/plain2.json)" "['assumed_author_engine', 'author', 'chosen', 'class', 'entries', 'helper_threshold', 'invalid', 'source', 'start']" "a config without second entries: the same JSON keys as before"
check "$(jf 'sorted(d["entries"][0])' < $P/plain2.json)" "['available', 'kind', 'name', 'skill', 'why']" "…and the same entry fields"
cfg "[$S]"; rv --for code > $P/only.out 2> $P/only.err; check $? 1 "only a second-only entry: a plain walk finds no reviewer (exit 1)"

# ---- --second: the primary is the plain walk's choice, the second opinion the first other available entry
cfg "[$S, $A, $G]"; rm -f $P/ran-argon
check "$(chosen --for code --second)" argon "--second: an available second entry listed before the primary is returned"
[ -e $P/ran-argon ]; check $? 0 "…its check ran"
rv --for code --second > $P/s.out 2>/dev/null; check $? 0 "--second: exit 0"
grep -q '^reviewer: argon (skill delamain:agy-review) — second opinion, the primary is skill-a$' $P/s.out; check $? 0 "…the output names it a second opinion and names the primary"
grep -q '^start: load skill `delamain:agy-review`; give it the brief file' $P/s.out; check $? 0 "…and prints its start line like a plain choice"
grep -q '^review helpers: ' $P/s.out; check $? 0 "…with the helper threshold line"
rv --for code --second --json > $P/s.json 2>/dev/null
check "$(jf '[d["second"], d["primary"], d["chosen"], d["start"][:26]]' < $P/s.json)" "[True, 'skill-a', 'argon', 'load skill \`delamain:agy-r']" "--second --json: second true, primary, chosen, start"
check "$(jf '[e["name"] for e in d["entries"]]' < $P/s.json)" "['argon', 'skill-a']" "…entries judged up to both finds (the agent entry after them was not judged)"
cfg "[$A, $S, $G]"; check "$(chosen --for code --second)" argon "the first other entry in list order, a second entry after the primary"
cfg "[$A, $G, $S]"; check "$(chosen --for code --second)" agent "an ordinary available entry before the second entry is the second opinion"
cfg "[$A, $G]"; check "$(chosen --for code --second)" agent "no second entries at all: the next ordinary entry is the second opinion"
cfg "[$A, $G]"; rv --second > $P/ord.out 2>/dev/null; grep -q '^reviewer: agent (agent sonnet/high) — second opinion, the primary is skill-a$' $P/ord.out; check $? 0 "…an agent entry prints its agent spawn line"
grep -q '^start: agent spawn --role review-agent --cwd <REPO> --model sonnet --effort high --brief <BRIEF>$' $P/ord.out; check $? 0 "…as it does without --second"
cfg "[$S, $A, $G]"
check "$(chosen --for docs --second)" agent "a class the second entry does not serve: it is skipped, the next one is the second opinion"
cfg "[$A, {\"name\": \"argon\", \"kind\": \"skill\", \"skill\": \"x\", \"second\": true, \"until\": \"2000-01-01\"}, $G]"
check "$(chosen --second)" agent "a second entry past its until is skipped"
cfg "[$A, {\"name\": \"argon\", \"kind\": \"skill\", \"skill\": \"x\", \"second\": true, \"check\": \"exit 1\"}, $G]"
check "$(chosen --second)" agent "a second entry whose check fails is skipped"
cfg "[$A, {\"name\": \"ag2\", \"kind\": \"agent\", \"second\": true, \"model\": \"opus\"}]"
check "$(chosen --second)" ag2 "an agent entry can be second-only too"
check "$(chosen)" skill-a "…and a plain walk still chooses the ordinary one"

# ---- --second needs a primary and another: exit 1 says only that there is no second opinion
cfg "[$A, {\"name\": \"argon\", \"kind\": \"skill\", \"skill\": \"x\", \"second\": true, \"check\": \"exit 1\"}]"
rv --second > $P/n.out 2> $P/n.err; check $? 1 "only the primary is available: exit 1"
grep -q 'no second opinion is available (the primary reviewer skill-a stands alone)' $P/n.err; check $? 0 "…and the message says that no second opinion is what it means"
grep -q '^reviewer:' $P/n.out; check $? 1 "…no reviewer is named"
check "$(rv --second --json 2>/dev/null | jf '[d["chosen"], d["primary"], d["second"]]')" "[None, 'skill-a', True]" "…--json: chosen null, primary named, second true"
cfg "[$S]"
rv --second --for code > $P/np.out 2> $P/np.err; check $? 0 "no primary but a second entry is available: it is returned"
grep -q 'the primary is none' $P/np.out; check $? 0 "…and the output says that no primary is available"
check "$(rv --second --for code --json 2>/dev/null | jf '[d["chosen"], d["primary"]]')" "['argon', None]" "…--json: primary null"
cfg "[{\"name\": \"argon\", \"kind\": \"skill\", \"skill\": \"x\", \"second\": true, \"check\": \"exit 1\"}, $A]"
rv --second > /dev/null 2> $P/n2.err; check $? 1 "second entry down, primary up: exit 1"
cfg "[{\"name\": \"a\", \"kind\": \"skill\", \"skill\": \"x\", \"check\": \"exit 1\"}]"
rv --second > /dev/null 2> $P/n3.err; check $? 1 "nothing available at all: exit 1"
grep -q 'no second opinion is available (and no primary reviewer is available either)' $P/n3.err; check $? 0 "…said as such"

# ---- --all and the listing
cfg "[$S, $A, $G]"
rv --for code --second --all > $P/a.out 2>/dev/null
grep -q ' skill-a (skill my-review-skill): available — no check \[primary\]' $P/a.out && grep -q '→ argon (skill delamain:agy-review): available — check exited 0' $P/a.out && grep -q '  agent (agent sonnet/high): available — no check$' $P/a.out; check $? 0 "--second --all: every entry judged, the primary tagged, the second opinion marked"
rv --for code --second --all --json 2>/dev/null > $P/aj.json; check "$(jf 'len(d["entries"])' < $P/aj.json)" 3 "--second --all --json: every entry"

# ---- validation of the field
bad(){ cfg "[{\"name\": \"x\", \"kind\": \"skill\", \"skill\": \"s\", $1}, $A]"; rv > $P/v.out 2> $P/v.err
  check "$(grep -c 'entry 1 (x): `second` must be true or false' $P/v.err)-$(sed -n 's/^reviewer: \([^ ]*\) .*/\1/p' $P/v.out)" "1-skill-a" "second $1: refused, reported, skipped"; }
bad '"second": "yes"'; bad '"second": 1'; bad '"second": null'; bad '"second": ["code"]'
cfg "[{\"name\": \"x\", \"kind\": \"skill\", \"skill\": \"s\", \"second\": false}, $A]"
check "$(chosen)" x "\"second\": false is an ordinary entry"
rv --json 2>/dev/null | jf '"second" in d["entries"][0]' | grep -q False; check $? 0 "…and prints no second field"
cfg "[{\"name\": \"x\", \"kind\": \"skill\", \"skill\": \"s\", \"secnd\": true}, $A]"
rv > $P/u.out 2> $P/u.err; grep -q "entry 1 (x): unknown field 'secnd'" $P/u.err; check $? 0 "a misspelt field is still rejected"
grep -q 'second)' $P/u.err; check $? 0 "…and the known fields it lists include second"
cfg "[{\"name\": \"x\", \"kind\": \"skill\", \"skill\": \"s\", \"second\": true}, $A]"; rm -f $R/config.json
printf '{"AGENT_HUB_REVIEWERS": [{"name": "x", "kind": "skill", "skill": "s", "second": true, "check": "touch %s/ran-repo"}, {"name": "ok", "kind": "agent"}]}\n' $P > $P/repo-cfg.json
mkdir -p $P/repo/.git $P/repo/.agent-hub; cp $P/repo-cfg.json $P/repo/.agent-hub/config.json
(cd $P/repo && $B/hub reviewer --author claude --second > $P/rr.out 2> $P/rr.err); [ -e $P/ran-repo ]; check $? 1 "a repository's second entry with a check: the check is never run"
grep -q '`check` in a repository.s config is never run' $P/rr.err; check $? 0 "…and the entry is reported"

# ---- the usage text
$B/hub --help | grep -q 'hub reviewer .*--all\] \[--second\]'; check $? 0 "hub --help lists --second"
$B/hub reviewer --help | grep -q -- '--second'; check $? 0 "hub reviewer --help describes --second"
exit $fail
