#!/bin/bash
# App-native bridge protocol: local candidates/attempts only, never fake idle or CLI transport.
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_HOME=$(mktemp -d) AGENT_HUB_WATCHDOG=on
python3 - "$B" <<'PY'
import hashlib,json,os,subprocess,sys,tempfile
import time
from datetime import datetime,timedelta,timezone
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import hubcore as hc
root=Path(os.environ['AGENT_HUB_HOME']);sid='aaaaaaaa-1111-4111-8111-111111111111'
caller='cccccccc-3333-4333-8333-333333333333';other='bbbbbbbb-2222-4222-8222-222222222222'
now=datetime.now(timezone.utc).replace(second=0,microsecond=0)
rec={'session':sid,'cli_session_id':sid,'engine':'codex','host':'codex-app','kind':'cli','tag':'hub-1',
     'set_at':(now-timedelta(hours=2)).isoformat(),'cwd':str(root)}
hc.roles_save('native',{'roles':{'hub':rec},'retired':[]})
journal=hc.journal_path('native',now.date());journal.parent.mkdir(parents=True,exist_ok=True)
journal.write_text(f'- {now-timedelta(minutes=30):%H:%M} [executor] DONE fixture report\n')
code=Path(os.environ['CODEX_HOME']);(code/'sessions').mkdir()
rollout=code/'sessions/rollout-native.jsonl'
rollout.write_text(json.dumps({'type':'session_meta','timestamp':rec['set_at'],'payload':{'id':sid,'source':'vscode'}})+'\n')
ago=(now-timedelta(hours=1)).timestamp();os.utime(rollout,(ago,ago))
fake=root/'codex.py';calls=root/'codex-called'
fake.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nPath('+repr(str(calls))+').touch()\nraise SystemExit(9)\n');fake.chmod(0o755)
env={**os.environ,'CODEX_BIN':str(fake),'CODEX_THREAD_ID':caller,'AGENT_ROLE':'',
     'CODEX_INTERNAL_ORIGINATOR_OVERRIDE':'Codex Desktop','CODEX_APP_TOOLS_PIPE_PATH':'fixture',
     'AGENT_HUB_WATCHDOG_NOW':now.isoformat()}
def run(*args,ok=True,extra=None):
 p=subprocess.run([str(Path(sys.argv[1])/'watchdog'),*args],env={**env,**(extra or {})},capture_output=True,text=True)
 assert (p.returncode==0)==ok,(args,p.returncode,p.stdout,p.stderr)
 return json.loads(p.stdout) if p.returncode==0 else p.stderr
def plan():return {'candidates':run('native-plan','--json','--stage','native')}
def snapshot():return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for base in (root,code) for p in base.rglob('*') if p.is_file()}
state=root/'.state/watchdog/state.json';state.parent.mkdir(parents=True)
state.write_text(json.dumps({'stages':{'native':{'hub':{'session':sid,'episode':{'result':'notified',
                 'next_try_at':(now+timedelta(hours=4)).isoformat()}}}}}))
before=snapshot();got=plan();assert snapshot()==before and len(got['candidates'])==1,got
c=got['candidates'][0]
assert c['session']==sid and c['reason']=='R3' and c['count']==1
assert set(c)=={'stage','session','fingerprint','reason','waiting_since','count','message'}
assert 'busy' not in c and not calls.exists()
assert 'fixture report' not in c['message']
hc.roles_save('same-thread',{'roles':{'hub':rec},'retired':[]})
other_journal=hc.journal_path('same-thread',now.date());other_journal.parent.mkdir(parents=True,exist_ok=True)
other_journal.write_text(journal.read_text())
same=run('native-plan','--json','--stage','same-thread')[0]
assert len(run('native-plan','--json'))==1,'cross-stage UUID dedup'
print('PASS native plan is read-only, never probes CLI/infers idle, and ignores standalone notification cooldown')
base=['--stage','native','--session',sid,'--fingerprint',c['fingerprint']]
claim_args=['native-claim',*base]
run(*claim_args,ok=False,extra={'AGENT_ROLE':'detached'})
run(*claim_args,ok=False,extra={'CODEX_APP_TOOLS_PIPE_PATH':''})
attempt=run(*claim_args);assert attempt['outcome']=='unknown' and attempt['attempt']
run('native-claim','--stage','same-thread','--session',sid,'--fingerprint',same['fingerprint'],ok=False)
assert run('native-plan','--json','--stage','same-thread')==[]
assert plan()['candidates']==[]
run(*claim_args,ok=False)
assert run('native-plan','--json','--stage','native',extra={'AGENT_HUB_WATCHDOG_NOW':(now+timedelta(hours=2)).isoformat()})==[]
original_journal=journal.read_text()
with journal.open('a') as f:f.write(f'- {now-timedelta(minutes=20):%H:%M} [executor] DONE another work item\n')
future={'AGENT_HUB_WATCHDOG_NOW':(now+timedelta(hours=2)).isoformat()}
assert run('native-plan','--json','--stage','native',extra=future)==[],'new work alone released unknown delivery'
hc.roles_save('native',{'roles':{'hub':{**rec,'title':'re-registered same UUID'}},'retired':[]})
assert run('native-plan','--json','--stage','native',extra=future)==[],'re-registration released unknown delivery'
hc.roles_save('native',{'roles':{'hub':rec},'retired':[]})
os.utime(rollout,(now.timestamp()+60,now.timestamp()+60))
assert run('native-plan','--json','--stage','native',extra=future)==[],'file touch released unknown delivery'
progress={'type':'event_msg','timestamp':(now+timedelta(minutes=1)).isoformat(),
          'payload':{'type':'task_started','turn_id':'new-own-turn','started_at':int(now.timestamp()+60)}}
original_rollout=rollout.read_text()
with rollout.open('a') as f:f.write(json.dumps(progress)+'\n')
os.utime(rollout,(now.timestamp()+60,now.timestamp()+60))
assert run('native-plan','--json','--stage','native',extra=future),'actual recipient turn progress did not release unknown hold'
rollout.write_text(original_rollout);os.utime(rollout,(ago,ago));journal.write_text(original_journal)
print('PASS UUID-wide unknown hold survives new work, expired backoff, re-registration and file touch; only own-turn progress releases it')
print('PASS app-only claim records unknown BEFORE transport and blocks a duplicate even without ack')
ack_args=['native-ack',*base,'--attempt',attempt['attempt'],'--outcome','sent']
run(*ack_args,ok=False,extra={'CODEX_THREAD_ID':other})
assert run(*ack_args)['outcome']=='sent'
assert run(*ack_args)['already_acknowledged']
run(*ack_args[:-1],'failed',ok=False)
assert plan()['candidates']==[]
print('PASS ack fences consumer/token, is idempotent, and preserves native cooldown')
hc.roles_save('native',{'roles':{'hub':{**rec,'session':other,'cli_session_id':other}},'retired':[]})
run(*ack_args,ok=False)
hc.roles_save('native',{'roles':{},'retired':[rec]});assert plan()['candidates']==[];run(*ack_args,ok=False)
hc.roles_save('native',{'roles':{'hub':rec},'retired':[]})
state.write_text(json.dumps({'stages':{}}))
waiter=subprocess.Popen([str(Path(sys.argv[1])/'jwait'),'--journal','--stage','native','--tag','hub-1',
                         '--match',hc.status_pattern(),'--for','2m','--note','native fixture'],
                        env={**env,'HUB_TAG':'hub-1','CODEX_THREAD_ID':sid},
                        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
 deadline=time.monotonic()+10
 while time.monotonic()<deadline:
  if list((root/'.jwait-state/native').glob('*.armed.json')):break
  time.sleep(.05)
 else:raise AssertionError('positive waiter fixture never armed')
 assert plan()['candidates']==[]
finally:
 waiter.terminate();waiter.wait(timeout=5)
assert len(plan()['candidates'])==1,'dead waiter must not prevent planning'
print('PASS live own waiter blocks native plan; dead waiter is ignored without read-only file cleanup')
for path,value in ((root/'native/do-not-wake.json',{'until':None,'reason':'fixture'}),
                   (root/'native/auto-handoff.json',{'pending':{'id':other}})):
 path.write_text(json.dumps(value));assert plan()['candidates']==[]
 run(*claim_args,ok=False);path.unlink()
hc.roles_save('native',{'roles':{'hub':{**rec,'host':None}},'retired':[]});assert plan()['candidates']==[]
hc.roles_save('native',{'roles':{'hub':rec},'retired':[]})
skip_attempt=run(*claim_args)
skip_ack=['native-ack',*base,'--attempt',skip_attempt['attempt'],'--outcome','completed-skip']
for path,value in ((root/'native/do-not-wake.json',{'until':None,'reason':'fixture'}),
                   (root/'native/auto-handoff.json',{'pending':{'id':other}})):
 path.write_text(json.dumps(value));run(*skip_ack,ok=False);path.unlink()
run(*skip_ack);assert plan()['candidates']==[]
with journal.open('a') as f:f.write(f'- {now-timedelta(minutes=20):%H:%M} [executor] DONE new fixture work\n')
assert plan()['candidates'][0]['fingerprint']!=c['fingerprint']
print('PASS quiet/pending refuse ack; completed-skip suppresses only stale fingerprint and new work re-arms')
journal.write_text('');assert plan()['candidates']==[];run(*claim_args,ok=False)
print('PASS replaced/retired/unknown host, quiet, pending and consumed work never claim or ack stale identity')
# Local R4 evidence is a candidate, never native idle proof.
start=int((now-timedelta(minutes=70)).timestamp())
events=[{'type':'session_meta','timestamp':rec['set_at'],'payload':{'id':sid}},
        {'type':'event_msg','timestamp':(now-timedelta(minutes=70)).isoformat(),
         'payload':{'type':'task_started','turn_id':'fixture','started_at':start}},
        {'type':'event_msg','timestamp':(now-timedelta(hours=1)).isoformat(),
         'payload':{'type':'task_complete','turn_id':'fixture','started_at':start,'completed_at':start+600,
                    'error':{'codex_error_info':'server_overloaded'}}}]
rollout.write_text(''.join(json.dumps(e)+'\n' for e in events));os.utime(rollout,(ago,ago))
assert plan()['candidates'][0]['reason']=='R4'
r4=plan()['candidates'][0]
r4_receipt=run('native-claim','--stage','native','--session',sid,'--fingerprint',r4['fingerprint'])
assert r4_receipt['failed_turn']['turn_id']=='fixture' and r4_receipt['failed_turn']['error']=='server_overloaded'
state.write_text(json.dumps({'stages':{}}))
assert run('native-plan','--json','--stage','native',extra={'AGENT_HUB_WATCHDOG_API_ERROR':'off'})==[]
events[-1]['payload']['error']['codex_error_info']='usage_limit_exceeded'
rollout.write_text(''.join(json.dumps(e)+'\n' for e in events));os.utime(rollout,(ago,ago))
assert plan()['candidates']==[] and not calls.exists()
print('PASS native R4 uses narrow final overload only; quota errors and disabled R4 are excluded')
PY
check $? 0 'app-native watchdog bridge protocol controls'
exit $fail
