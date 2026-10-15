#!/bin/bash
# Registry UUID addressing, promoted detached hubs, positive runtime evidence and silent failures.
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_BIN=$T/fake_codex.py AGENT_HUB_ENGINE=codex HUB_STAGE=stage-a HUB_TAG=hub-test
W=$AGENT_HUB_HOME/repo; mkdir -p "$W"; echo 'wait' > "$W/brief.md"
trap '"$B/agent" stop --stage stage-a old-hub >/dev/null 2>&1; test_cleanup' EXIT
FAKE_CODEX_HOLD=60 "$B/agent" spawn --engine codex --role old-hub --cwd "$W" --brief "$W/brief.md" > "$W/spawn.out" 2>&1
check $? 0 'spawn a fake detached Codex predecessor'
SID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_id"])' "$AGENT_HUB_HOME/stage-a/agents/old-hub/meta.json")
"$B/tell" stage-a --role old-hub --address > "$W/headless-address.out" 2>&1
check $? 0 'Codex headless address'
grep -q 'agent send .* (tell does this itself)' "$W/headless-address.out"; check $? 0 'headless address says tell delivers automatically'
NEW=77777777-7777-4777-8777-777777777777
# hub takeover registers a detached successor as kind cli, without worker PID/token.
"$B/roles" set hub "$SID" --kind cli --tag hub-1 > /dev/null
python3 - "$AGENT_HUB_HOME/stage-a/roles.json" <<'PY'
import json,sys
p=sys.argv[1];data=json.load(open(p));data['roles']['hub']['engine']='codex';open(p,'w').write(json.dumps(data))
PY
"$B/tell" stage-a --address > "$W/address.out" 2>&1
check $? 0 'Codex promoted worker address'
grep -q 'agent send --stage stage-a old-hub' "$W/address.out"; check $? 0 'address resolves original detached role by UUID'
! grep -q '(tell does this itself)' "$W/address.out"; check $? 0 'promoted cli address does not promise automatic inbox delivery'
"$B/hub" takeover --stage stage-a --session "$NEW" > "$W/take.out" 2>&1
check $? 0 'takeover over a detached Codex predecessor'
check "$(grep -c 'ATTENTION: the previous hub' "$W/take.out")" 2 'Codex warning in output and digest'
grep -q 'agent stop --stage stage-a old-hub' "$W/take.out"; check $? 0 'Codex warning names actual worker stop command'
"$B/agent" status old-hub > "$W/status.out"; grep -q ALIVE "$W/status.out"; check $? 0 'warning did not stop the fake worker'
"$B/hub" takeover --stage stage-a --session "$NEW" > "$W/again.out" 2>&1
! grep -q 'previous hub .* still runs' "$W/again.out"; check $? 0 'same-session repeat has no warning'
"$B/agent" stop old-hub > /dev/null 2>&1

python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import importlib.machinery, importlib.util, json, os, subprocess, sys, time
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,sys.argv[1])
import codex_sessions as cs
import hubcore as hc
loader=importlib.machinery.SourceFileLoader('hub_cli',str(Path(sys.argv[1])/'hub'))
spec=importlib.util.spec_from_loader(loader.name,loader); hub=importlib.util.module_from_spec(spec);loader.exec_module(hub)
root=Path(sys.argv[2]);sid='aaaaaaaa-1111-4111-8111-111111111111'
rec={'session':sid,'engine':'codex','kind':'cli','tag':'hub-2'}
# Fake the installed CLI's proxy transport. It validates handshake and rejects mutations.
fake=root/'proxy.py'
fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
assert sys.argv[1:]==['app-server','proxy'],sys.argv
mode=os.environ.get('PROXY_MODE','idle')
if mode=='fail':sys.exit(1)
if mode=='hang':time.sleep(30);sys.exit(1)
assert json.loads(sys.stdin.readline())['method']=='initialize'
if mode=='brokenpipe':
 os.close(0);print(json.dumps({'id':1,'result':{}}),flush=True);time.sleep(1);sys.exit(0)
print(json.dumps({'id':1,'result':{}}),flush=True)
assert json.loads(sys.stdin.readline())['method']=='initialized'
r=json.loads(sys.stdin.readline());assert r['method']=='thread/read' and r['params']['includeTurns'] is False
if mode=='malformed':print('not json',flush=True)
elif mode=='badshape':print(json.dumps({'id':2,'result':[]}),flush=True)
else:print(json.dumps({'id':2,'result':{'thread':{'id':r['params']['threadId'] if mode!='wrongid' else 'other','status':{'type':mode}}}}),flush=True)
sys.stdin.read()
''');fake.chmod(0o755)
os.environ['CODEX_BIN']=str(fake)
# `hub takeover` stops a replaced Claude background hub itself (replaced_hub -> (stopped, warning)); a Codex hub is only named
prev_warning=lambda r,a,b,st:hub.replaced_hub(r,a,b,st,True)[1]
for state in ('idle','active','systemError'):
 os.environ['PROXY_MODE']=state
 assert cs.runtime_status(sid)==state
 warning=prev_warning(rec,'new','new','stage-a')
 assert 'still runs' in warning and 'Codex terminal/app session' in warning
for state in ('notLoaded','wrongid','fail','malformed','badshape','brokenpipe','hang'):
 os.environ['PROXY_MODE']=state
 started=time.monotonic()
 assert prev_warning(rec,'new','new','stage-a')=='',state
 if state=='hang':
  elapsed=time.monotonic()-started
  assert elapsed < 12, f'hanging transport exceeded deadline: {elapsed:.3f}s'
# Detached stale PID/token and process failure: never trust PID existence or recent rollout activity.
meta={'engine':'codex','session_id':sid,'role':'old-hub','pid':1234,'process_token':'expected'}
p=root/'stage-a'/'agents'/'old-hub'/'meta.json';p.write_text(json.dumps(meta))
for table in ({1234:'unrelated-process'}, {}, None):
 with patch.object(cs.subagents,'process_table',return_value=table):
  assert prev_warning(rec,'new','new','stage-a')==''
with patch.object(cs.subagents,'process_table',return_value={1234:'worker expected'}):
 assert 'agent stop --stage stage-a old-hub' in prev_warning(rec,'new','new','stage-a')
 # Legacy detached record lacking engine is detected from metadata too.
 assert 'still runs' in prev_warning({**rec,'engine':'claude'},'new','new','stage-a')
p.unlink()
# Native Codex address uses registry UUID and never asks Claude's session list; writes nothing.
hc.roles_save('stage-a',{'version':1,'roles':{'hub':rec},'retired':[]})
os.environ['CLAUDE_BIN']='/nonexistent/claude'
before={p:p.read_bytes() for p in root.rglob('*') if p.is_file()}
r=subprocess.run([str(Path(sys.argv[1])/'tell'),'stage-a','--address'],capture_output=True,text=True)
assert r.returncode==0,r.stderr
assert f'codex queue --thread {sid} --message' in r.stdout,r.stdout
assert 'name     ' not in r.stdout
assert before=={p:p.read_bytes() for p in root.rglob('*') if p.is_file()}
print('PASS native proxy statuses, timeout, malformed/error replies, identity, stale PID/token and read-only UUID address')
PY
check $? 0 'native Codex addressing and warning controls'
exit $fail
