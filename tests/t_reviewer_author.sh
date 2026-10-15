#!/bin/bash
# hub reviewer --author: the reviewer is chosen from who wrote the change, not from the hub's host. A role of the stage
# (its meta.json) or engine[/model] names the author; every `check` sees AGENT_HUB_REVIEW_AUTHOR_ENGINE / _MODEL; without
# --author the host's engine is assumed and a line says so. Entries here are stand-ins: a `check` that passes only for
# an author of the other engine, as the owner's personal check does.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; export PYTHONDONTWRITEBYTECODE=1
P=$(mktemp -d); mkdir -p $P/out $R/stage-a/agents/sol-role $R/stage-a/agents/cl-role $R/stage-a/agents/old-role
cd $P/out
echo '{"role": "sol-role", "engine": "codex", "model": "gpt-6.1-sol"}' > $R/stage-a/agents/sol-role/meta.json
echo '{"role": "cl-role", "engine": "claude", "model": "sonnet", "resolved_model": "claude-sonnet-5-5"}' > $R/stage-a/agents/cl-role/meta.json
echo '{"role": "old-role", "model": "opus"}' > $R/stage-a/agents/old-role/meta.json          # no engine: Claude
# a check that records what it saw, and passes only when the author's engine is the one named in its argument (the entry reviews that engine's changes)
cat > $P/chk.sh <<'SH'
#!/bin/sh
echo "saw engine=${AGENT_HUB_REVIEW_AUTHOR_ENGINE-unset} model=${AGENT_HUB_REVIEW_AUTHOR_MODEL-unset}"
[ "${AGENT_HUB_REVIEW_AUTHOR_ENGINE-$HOST_ENGINE}" = "$1" ]
SH
cat > $R/config.json <<JSON
{"AGENT_HUB_REVIEWERS": [
 {"name": "claude-for-sol", "kind": "agent", "engine": "claude", "model": "fable", "effort": "high", "check": "sh $P/chk.sh codex"},
 {"name": "codex-for-claude", "kind": "agent", "engine": "codex", "model": "gpt-6-astra", "effort": "high", "check": "sh $P/chk.sh claude"}]}
JSON
chosen(){ $B/hub reviewer "$@" 2>/dev/null | sed -n 's/^reviewer: \([^ ]*\) .*/\1/p'; }
jf(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

# ---- the author decides, whatever the host is
check "$(HOST_ENGINE=claude chosen --author codex/gpt-6.1-sol)" claude-for-sol "Claude host, Codex author -> the Claude reviewer"
check "$(HOST_ENGINE=codex CODEX_THREAD_ID=probe chosen --author codex/gpt-6.1-sol)" claude-for-sol "Codex host, Codex author -> the Claude reviewer"
check "$(HOST_ENGINE=claude chosen --author claude/sonnet)" codex-for-claude "Claude host, Claude author -> the Codex reviewer"
check "$(HOST_ENGINE=codex CODEX_THREAD_ID=probe chosen --author claude/sonnet)" codex-for-claude "Codex host, Claude author -> the Codex reviewer"
check "$(HOST_ENGINE=claude chosen --author codex)" claude-for-sol "an engine alone is an author too"
check "$(chosen --author claude)" codex-for-claude "…claude alone"

# ---- the variable reaches the check: engine and model, and only what --author said
HOST_ENGINE=claude $B/hub reviewer --all --author codex/gpt-6.1-sol > $P/v1.out 2>/dev/null
grep -q 'check output: saw engine=codex model=gpt-6.1-sol' $P/v1.out; check $? 0 "the check sees engine and model of an engine/model author"
HOST_ENGINE=claude $B/hub reviewer --all --author codex > $P/v2.out 2>/dev/null
grep -q 'check output: saw engine=codex model=$' $P/v2.out; check $? 0 "an engine-only author: the model variable is empty"

# ---- a role: engine and model come from the agent's meta.json
HUB_STAGE=stage-a $B/hub reviewer --all --author sol-role > $P/r1.out 2>$P/r1.err; check $? 0 "--author <role>: exit 0"
grep -q 'saw engine=codex model=gpt-6.1-sol' $P/r1.out; check $? 0 "a Codex role: its engine and model reach the check"
grep -q '^author: codex/gpt-6.1-sol (role sol-role)' $P/r1.out; check $? 0 "…and the output names the author and where it came from"
check "$(HUB_STAGE=stage-a HOST_ENGINE=claude chosen --author sol-role)" claude-for-sol "a Codex-authored role in a Claude host -> the Claude reviewer"
check "$(HUB_STAGE=stage-a HOST_ENGINE=codex CODEX_THREAD_ID=probe chosen --author cl-role)" codex-for-claude "a Claude-authored role in a Codex host -> the Codex reviewer"
HUB_STAGE=stage-a $B/hub reviewer --all --author cl-role 2>/dev/null | grep -q 'saw engine=claude model=claude-sonnet-5-5'; check $? 0 "the resolved model wins over the asked one"
HUB_STAGE=stage-a $B/hub reviewer --all --author old-role 2>/dev/null | grep -q 'saw engine=claude model=opus'; check $? 0 "a meta.json without an engine is a Claude agent"
$B/hub reviewer --stage stage-a --author sol-role --json 2>/dev/null > $P/rj.json
check "$(jf 'd["author"]' < $P/rj.json)" "{'engine': 'codex', 'model': 'gpt-6.1-sol', 'source': 'role sol-role'}" "--json: the author"

# ---- negative: a wrong --author is an error, never the host
$B/hub reviewer --stage stage-a --author nobody > $P/n1.out 2> $P/n1.err; check $? 2 "an unknown role: usage error"
grep -q "no agent with that role in stage stage-a" $P/n1.err; check $? 0 "…named"
check "$(grep -c '^reviewer:' $P/n1.out)" 0 "…and no reviewer is chosen"
$B/hub reviewer --author gemini/x > /dev/null 2>$P/n2.err; check $? 2 "an unknown engine before '/': usage error"
$B/hub reviewer --author 'codex/x;rm -rf ~' > /dev/null 2>$P/n3.err; check $? 2 "a model with shell syntax: usage error"
env -u HUB_STAGE $B/hub reviewer --author sol-role > /dev/null 2>$P/n4.err; check $? 2 "a role without a stage: usage error"

# ---- without --author: said once, the check does not see an author, and a stale value in the shell does not leak in
HOST_ENGINE=claude $B/hub reviewer --all > $P/u.out 2> $P/u.err
check "$(grep -c 'author unknown: assuming the host engine (claude)' $P/u.err)" 1 "no --author: one line on stderr says the host engine is assumed"
grep -q '^author: unknown, host engine claude assumed' $P/u.out; check $? 0 "…and stdout carries it too"
grep -q 'saw engine=unset model=unset' $P/u.out; check $? 0 "…the check sees no author variable"
AGENT_HUB_REVIEW_AUTHOR_ENGINE=codex HOST_ENGINE=claude $B/hub reviewer --all > $P/u2.out 2>/dev/null
grep -q 'saw engine=unset' $P/u2.out; check $? 0 "negative: an author variable already in the caller's shell is not passed on without --author"
AGENT_HUB_REVIEW_AUTHOR_ENGINE=codex HOST_ENGINE=claude $B/hub reviewer --all --author claude/opus > $P/u3.out 2>/dev/null
grep -q 'saw engine=claude model=opus' $P/u3.out; check $? 0 "…and --author overrides it"
HOST_ENGINE=claude $B/hub reviewer --json 2>/dev/null > $P/uj.json
check "$(jf '[d["author"], d["assumed_author_engine"]]' < $P/uj.json)" "[None, 'claude']" "--json: author null, the assumed engine named"
$B/hub reviewer --author codex/gpt-6.1-sol 2> $P/k.err > /dev/null; check "$(grep -c 'author unknown' $P/k.err)" 0 "negative: with --author there is no unknown-author line"

# ---- the built-in default: the other engine than the author's
rm $R/config.json
$B/hub reviewer --author codex/gpt-6.1-sol --json 2>/dev/null > $P/d1.json
check "$(jf '[d["chosen"], "--engine claude" in d["start"], "--sandbox" in d["start"]]' < $P/d1.json)" "['agent', True, False]" "built-in default, Codex author -> a Claude reviewer even in a Claude host"
CODEX_THREAD_ID=probe $B/hub reviewer --author codex/gpt-6.1-sol --json 2>/dev/null > $P/d2.json
check "$(jf '"--engine claude" in d["start"]' < $P/d2.json)" True "built-in default, Codex author, Codex host -> still Claude"
mkdir -p $P/bin; printf '#!/bin/sh\nexit 0\n' > $P/bin/codex; chmod +x $P/bin/codex
CODEX_BIN=$P/bin/codex $B/hub reviewer --author claude/opus --json 2>/dev/null > $P/d3.json
check "$(jf '"--engine codex --sandbox read-only --model gpt-6-astra" in d["start"]' < $P/d3.json)" True "built-in default, Claude author, codex installed -> a Codex reviewer"
CODEX_BIN=$P/bin/missing $B/hub reviewer --author claude/opus --json 2>/dev/null > $P/d4.json
check "$(jf '"--engine" in d["start"]' < $P/d4.json)" False "negative: Claude author, no codex CLI -> the Claude default stays"
$B/hub reviewer --json 2>/dev/null > $P/d5.json
check "$(jf '"--engine" in d["start"]' < $P/d5.json)" False "negative: no --author: the default is unchanged (host engine)"
exit $fail
