#!/bin/bash
# agent spawn --mcp / AGENT_HUB_SPAWN_MCP: which MCP servers a Claude agent's runs load — inherit (the default, no
# flag), none (--strict-mcp-config), or only those of MCP config files; resumes keep the choice; a repository may
# choose inherit or none only; Codex refuses the flag.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
spawn(){ $B/agent-spawn --role "$1" --cwd $W --model haiku --brief $W/b.md "${@:2}"; }
meta_mcp(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('mcp'))" $R/stage-a/agents/$1/meta.json; }
RW=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' $W)  # the paths as the tool resolves them (/private/var on macOS)
echo '{"mcpServers": {"gitlab": {"command": "true"}}}' > $W/one.json
echo '{"mcpServers": {"db": {"type": "http", "url": "http://127.0.0.1:9/mcp"}}}' > $W/two.json

# 1. default: today's behaviour, no MCP flag at all
spawn dflt > /dev/null; check $? 0 "default spawn"
tail -1 $W/argv.log | grep -q -- '--strict-mcp-config\|--mcp-config'; check $? 1 "default: no MCP flag, the agent inherits every server"
check "$(meta_mcp dflt)" inherit "default: meta.json records inherit"
wait_dead dflt; $B/agent-stop dflt > /dev/null
# 2. --mcp none: strict, no config files; the journal's start line says so
spawn none1 --mcp none > /dev/null; check $? 0 "spawn --mcp none"
tail -1 $W/argv.log | grep -q -- '--permission-mode bypassPermissions --strict-mcp-config --add-dir\|--permission-mode bypassPermissions --strict-mcp-config -n'
check $? 0 "--mcp none: --strict-mcp-config without --mcp-config"
grep 'started headless agent none1' $(journal stage-a) | grep -q 'MCP none'; check $? 0 "--mcp none: the start line names it"
# 3. a resume keeps the spawn's choice, whatever the setting says now
wait_dead none1
AGENT_HUB_SPAWN_MCP=inherit $B/agent-send none1 "again" > /dev/null; check $? 0 "resume none1"
tail -1 $W/argv.log | grep -q -- "--resume .*--strict-mcp-config"; check $? 0 "resume: the run keeps --strict-mcp-config"
wait_dead none1; $B/agent-stop none1 > /dev/null
# 4. config files: only their servers; a relative --mcp path is the caller's working directory's
(cd $W && spawn files --mcp one.json,$W/two.json > /dev/null); check $? 0 "spawn --mcp FILE,FILE"
tail -1 $W/argv.log | grep -q -- "--strict-mcp-config --mcp-config $RW/one.json $RW/two.json "; check $? 0 "--mcp files: strict plus --mcp-config with absolute paths"
wait_dead files
# 4b. a resume re-checks the files: one deleted since the spawn is refused before the message is queued
mv $W/two.json $W/two.away; N=$(wc -l < $W/argv.log); INBOX=$(cat $R/stage-a/agents/files/inbox.md)
$B/agent-send files "again" > $R/rs.out 2>&1; check $? 2 "negative: resume with a deleted MCP config file"
grep -q "two.json: no such file" $R/rs.out; check $? 0 "…naming the file"
[ "$(wc -l < $W/argv.log)" = "$N" ] && [ "$(cat $R/stage-a/agents/files/inbox.md)" = "$INBOX" ]; check $? 0 "…before a CLI starts or the inbox changes"
mv $W/two.away $W/two.json
$B/agent-send files "again" > /dev/null; check $? 0 "resume once the file is back"
tail -1 $W/argv.log | grep -q -- "--resume .*--mcp-config $RW/one.json $RW/two.json "; check $? 0 "…with the same files"
wait_dead files; $B/agent-stop files > /dev/null
# 5. the setting: the environment and the hub home's config.json, the flag wins over both
AGENT_HUB_SPAWN_MCP=none spawn envn > /dev/null; check $? 0 "spawn with AGENT_HUB_SPAWN_MCP=none"
tail -1 $W/argv.log | grep -q -- '--strict-mcp-config'; check $? 0 "env none: strict"
wait_dead envn; $B/agent-stop envn > /dev/null
echo "{\"AGENT_HUB_SPAWN_MCP\": \"$W/one.json\"}" > $R/config.json
spawn homef > /dev/null; check $? 0 "spawn with a config file in the hub home's config.json"
tail -1 $W/argv.log | grep -q -- "--strict-mcp-config --mcp-config $RW/one.json "; check $? 0 "hub home: its MCP config file reaches the CLI"
wait_dead homef; $B/agent-stop homef > /dev/null
spawn flagw --mcp inherit > /dev/null; check $? 0 "spawn --mcp inherit over the hub home's file"
tail -1 $W/argv.log | grep -q -- '--strict-mcp-config'; check $? 1 "the flag wins over the setting"
wait_dead flagw; $B/agent-stop flagw > /dev/null
echo '{"AGENT_HUB_SPAWN_MCP": "one.json"}' > $R/config.json
spawn homerel > $R/rel.out 2>&1; check $? 2 "negative: a relative file in config.json is a usage error"
grep -q 'must be an absolute path' $R/rel.out; check $? 0 "…saying it must be absolute"
rm $R/config.json
# 6. a repository chooses inherit or none, never a file (its servers are commands the CLI would start unapproved)
P=$R/proj; mkdir -p $P/.agent-hub; git init -q $P; echo "brief" > $P/b.md
echo '{"AGENT_HUB_SPAWN_MCP": "none"}' > $P/.agent-hub/config.json
$B/agent-spawn --role projn --cwd $P --model haiku --brief $P/b.md > /dev/null; check $? 0 "repository config none"
tail -1 $P/argv.log | grep -q -- '--strict-mcp-config'; check $? 0 "repository none: strict"
wait_dead projn; $B/agent-stop projn > /dev/null
echo "{\"AGENT_HUB_SPAWN_MCP\": \"$W/one.json\"}" > $P/.agent-hub/config.json
N=$(wc -l < $P/argv.log)
$B/agent-spawn --role projf --cwd $P --model haiku --brief $P/b.md > $R/pf.out 2>&1; check $? 2 "negative: a repository's MCP config file is refused"
grep -q "outside the repository, the environment or --mcp" $R/pf.out; check $? 0 "…naming where a file may go"
check "$(wc -l < $P/argv.log)" "$N" "…and no CLI was started"
# a hub home inside the repository (AGENT_HUB_HOME "project") is the repository's too
echo '{"AGENT_HUB_HOME": "project"}' > $P/.agent-hub/config.json
mkdir -p $P/.agent-hub/local; echo "{\"AGENT_HUB_SPAWN_MCP\": \"$W/one.json\"}" > $P/.agent-hub/local/config.json
(unset AGENT_HUB_HOME; cd $P && $B/agent-spawn --role projh --cwd $P --model haiku --brief $P/b.md --dry-run) > $R/ph.out 2>&1
check $? 2 "negative: an MCP config file in a project hub home's config.json is refused"
grep -q "in a repository's config.json" $R/ph.out; check $? 0 "…as the repository's setting"
echo '{"AGENT_HUB_SPAWN_MCP": "none"}' > $P/.agent-hub/local/config.json
(unset AGENT_HUB_HOME; cd $P && $B/agent-spawn --role projh --cwd $P --model haiku --brief $P/b.md --dry-run) > $R/ph2.out 2>&1
check $? 0 "…while none there is taken"; grep -q 'MCP none' $R/ph2.out; check $? 0 "…and shown"
# 7. bad values fail before anything starts
N=$(wc -l < $W/argv.log)
spawn bad1 --mcp $W/nope.json > $R/b1.out 2>&1; check $? 2 "negative: a missing file"
echo '{"servers": {}}' > $W/notmcp.json
spawn bad2 --mcp $W/notmcp.json > $R/b2.out 2>&1; check $? 2 "negative: JSON without mcpServers"
grep -q 'not an MCP config' $R/b2.out; check $? 0 "…named as not an MCP config"
spawn bad3 --mcp , > /dev/null 2>&1; check $? 2 "negative: an empty list"
check "$(wc -l < $W/argv.log)" "$N" "no CLI was started for a bad value"
[ ! -e $R/stage-a/agents/bad1 ] && [ ! -e $R/stage-a/agents/bad2 ]; check $? 0 "…and no agent directory was created"
spawn dry --mcp none --dry-run > $R/dry.out 2>&1; check $? 0 "dry run with --mcp none"
grep -q 'MCP none' $R/dry.out; check $? 0 "dry run names the MCP choice"
# 8. Codex: no equivalent switch, the flag is refused (the setting is for Claude agents and does not stop Codex)
CODEX_BIN=$T/fake_codex.py $B/agent spawn --engine codex --role cx --cwd $W --brief $W/b.md --mcp none --dry-run > $R/cx.out 2>&1
check $? 2 "negative: --mcp none on Codex"
grep -q 'only supported by the Claude engine' $R/cx.out; check $? 0 "…named as Claude-only"
CODEX_BIN=$T/fake_codex.py AGENT_HUB_SPAWN_MCP=none $B/agent spawn --engine codex --role cx --cwd $W --brief $W/b.md --dry-run > /dev/null 2>&1
check $? 0 "Codex with AGENT_HUB_SPAWN_MCP=none still starts"
exit $fail
