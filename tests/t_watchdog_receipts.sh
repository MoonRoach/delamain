#!/bin/bash
# UUID receipt regressions: actor replacement and the two local transports.
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_HOME=$(mktemp -d) AGENT_HUB_WATCHDOG=on PYTHONDONTWRITEBYTECODE=1
python3 - "$B" <<'PY'
import json,os,subprocess,sys
from datetime import datetime,timedelta,timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,sys.argv[1])
import codex_rollouts as cr
import hubcore as hc
import watchdog_codex as wc
import watchdog_native as wn
import watchdog_receipts as wr
wd=wr.core();root=hc.root()
a='aaaaaaaa-1111-4111-8111-111111111111';b='bbbbbbbb-2222-4222-8222-222222222222'
caller='cccccccc-3333-4333-8333-333333333333'
now=datetime.now(timezone.utc).replace(second=0,microsecond=0)
os.environ.update(CODEX_THREAD_ID=caller,CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',
                  CODEX_APP_TOOLS_PIPE_PATH='fixture',AGENT_ROLE='',AGENT_HUB_WATCHDOG_NOW=now.isoformat())
code=Path(os.environ['CODEX_HOME'])/'sessions';code.mkdir()
paths={}
for sid in (a,b):
 p=code/('rollout-'+sid+'.jsonl');paths[sid]=p
 p.write_text(json.dumps({'type':'session_meta','timestamp':(now-timedelta(hours=3)).isoformat(),
                          'payload':{'id':sid}})+'\n')
 os.utime(p,((now-timedelta(hours=1)).timestamp(),)*2)
def register(stage,sid,**extra):
 rec={'session':sid,'cli_session_id':sid,'engine':'codex','host':'codex-app','kind':'cli','tag':'hub-1',
      'set_at':(now-timedelta(hours=2)).isoformat(),'cwd':str(root),**extra}
 hc.roles_save(stage,{'roles':{'hub':rec},'retired':[]})
 p=hc.journal_path(stage,now.date());p.parent.mkdir(parents=True,exist_ok=True)
 p.write_text(f'- {now-timedelta(minutes=30):%H:%M} [executor] DONE pending fixture work\n')
 return rec
def candidate(stage):
 cr.INDEX.checked=None
 return wn.candidate(wd,wd.Tick(True,True),stage)
def claim(stage):
 result,why=candidate(stage);assert result,why
 out=result[0]
 return wn.claim(wd,SimpleNamespace(stage=stage,session=out['session'],fingerprint=out['fingerprint']))
def ack(receipt,stage,outcome):
 return wn.ack(wd,SimpleNamespace(stage=stage,session=receipt['session'],fingerprint=receipt['fingerprint'],
                                 attempt=receipt['attempt'],outcome=outcome))
def fresh():wd.save_state({'stages':{}})
def clock(at):os.environ['AGENT_HUB_WATCHDOG_NOW']=at.isoformat()
def progress(sid,at,malformed=False):
 with paths[sid].open('a') as f:
  f.write(json.dumps({'type':'event_msg','timestamp':at.isoformat(),
                     'payload':{'type':'task_started','turn_id':'own-progress','started_at':int(at.timestamp())}})+'\n')
  if malformed:f.write('{broken\n')
 os.utime(paths[sid],(at.timestamp(),)*2);cr.INDEX.checked=None
rec_a=register('origin',a);register('elsewhere',a)
receipt_a=claim('origin')
assert not candidate('elsewhere')[0]
register('origin',b);receipt_b=claim('origin')
saved=wd.load_state();assert saved['stages']['origin']['native_episode']['session']==b
assert saved['uuid_receipts'][a]['attempt']==receipt_a['attempt']
assert saved['uuid_receipts'][b]['attempt']==receipt_b['attempt']
assert not candidate('elsewhere')[0],'A was erased by B claim'
print('PASS A unknown -> B claim retains A UUID hold in another stage')
future=now+timedelta(hours=2);clock(future)
j=hc.journal_path('elsewhere',now.date())
with j.open('a') as f:f.write(f'- {now-timedelta(minutes=20):%H:%M} [executor] DONE changed work\n')
register('elsewhere',a,title='replacement registry for the same UUID')
os.utime(paths[a],((now+timedelta(minutes=1)).timestamp(),)*2)
assert not candidate('elsewhere')[0]
print('PASS expired backoff, changed work, re-registration and file touch do not release A')
queues=[]
def queue(argv,**kwargs):
 assert argv[1:3]==['queue','--thread'],argv
 saved=wd.load_state()['uuid_receipts'][argv[3]]
 assert saved['result']=='unknown','CLI did not persist before queue'
 queues.append(argv)
 return subprocess.CompletedProcess(argv,0,stdout='accepted',stderr='')
def tick(stage):
 with wd.TickLock() as lock:
  assert lock.held
  t=wd.Tick(False,True)
  with patch.object(wc.codex_sessions,'runtime_status',return_value='idle'), \
       patch.object(wc.engines,'codex_bin',return_value='fake-codex'), \
       patch.object(wc.subprocess,'run',side_effect=queue), \
       patch.object(t,'notify'):
   wd.run_stage(t,stage)
  wd.save_state(t.state)
  return t
for stage in ('elsewhere','origin'):
 tick(stage)
assert queues==[]
register('origin',a,title='A returns after B takeover');tick('origin')
assert queues==[] and wd.load_state()['uuid_receipts'][a]['attempt']==receipt_a['attempt']
print('PASS regular rule_hub tick cannot queue native unknown across stages or after actor replacement')
# Observe initially idle, then insert a native receipt before the final queue check.
fresh();clock(now);cached=wd.Tick(False,True)
with wd.TickLock(), patch.object(wc.codex_sessions,'runtime_status',side_effect=lambda *args: (wd.save_state(
      {'stages':{},'uuid_receipts':{a:{'session':a,'result':'unknown','acted_at':now.isoformat()}}}) or 'idle')), \
     patch.object(wc.subprocess,'run',side_effect=queue):
 result=wc.wake('origin',hc.roles_load('origin')['roles']['hub'],'must not queue',False,wd=wd,tick=cached)
 wd.save_state(cached.state)
assert wd.load_state()['uuid_receipts'][a]['result']=='unknown'
assert not result['ok'] and queues==[],result
print('PASS final CLI pre-send guard reads current persisted receipts after runtime observation')
# Restore the receipt for recovery controls.
wd.save_state(saved);clock(future)
original=paths[a].read_text();progress(a,now+timedelta(minutes=1),malformed=True)
assert not candidate('elsewhere')[0],'malformed evidence released an unknown outcome'
paths[a].write_text(original);progress(a,now+timedelta(minutes=1))
rearmed,why=candidate('elsewhere');assert rearmed,('true own-turn progress did not re-arm native candidate',why)
tick('elsewhere');assert len(queues)==1 and queues[-1][3]==a
print('PASS malformed evidence stays fenced; true own-turn progress re-arms native and CLI')
# Legacy stage-only records must be retained when the first upgraded claim switches actor.
paths[a].write_text(original);os.utime(paths[a],((now-timedelta(hours=1)).timestamp(),)*2)
fresh();clock(now);register('origin',a);legacy=claim('origin');saved=wd.load_state();saved.pop('uuid_receipts')
wd.save_state(saved);register('origin',b);claim('origin')
assert a in wd.load_state()['uuid_receipts'] and not candidate('elsewhere')[0]
print('PASS upgrading a stage-only receipt retains prior UUID during actor replacement')
# Explicit rejection cools normally and re-arms after backoff without needing a new turn.
fresh();register('origin',b);clock(now);known=claim('origin');ack(known,'origin','failed')
assert not candidate('origin')[0]
clock(future);assert candidate('origin')[0]
print('PASS explicit failed outcome preserves cooldown then allows a normal retry')
# A lost CLI response blocks native fallback, even after a later tick saves its cached state.
fresh();register('origin',b);clock(now)
with wd.TickLock() as lock:
 assert lock.held
 t=wd.Tick(False,True)
 with patch.object(wc.codex_sessions,'runtime_status',return_value='idle'), \
      patch.object(wc.engines,'codex_bin',return_value='fake-codex'), \
      patch.object(wc.subprocess,'run',side_effect=subprocess.TimeoutExpired('queue',20)):
  result=wc.wake('origin',hc.roles_load('origin')['roles']['hub'],'fixture',False,wd=wd,tick=t)
 assert not result['ok'] and 'unknown' in result['detail']
 t.state['last_tick']=wd.iso(t.now);wd.save_state(t.state)
assert wd.load_state()['uuid_receipts'][b]['result']=='unknown'
clock(future);assert not candidate('origin')[0]
register('other-cli-stage',b);assert not candidate('other-cli-stage')[0]
tick('other-cli-stage');assert len(queues)==1
progress(b,now+timedelta(minutes=2))
assert wr.guard(wd,wd.load_state(),b,future)=='' ,'a guard refusal was treated as a fresh delivery'
progress(b,future+timedelta(minutes=1));clock(future+timedelta(hours=1))
rearmed,why=candidate('other-cli-stage');assert rearmed,why
print('PASS CLI timeout survives cached tick save, blocks both transports across stages, and own progress re-arms')
# A turn before the actual reservation must not release its later unknown receipt.
saved_rollout=paths[b].read_text();saved_mtime=paths[b].stat().st_mtime
actual_claim=now+timedelta(hours=6)
early_tick=actual_claim-timedelta(hours=1);between=actual_claim-timedelta(minutes=30)
for transport in ('cli','native'):
 paths[b].write_text(saved_rollout);os.utime(paths[b],(saved_mtime,)*2)
 fresh();clock(early_tick)
 if transport=='cli':
  with wd.TickLock() as lock:
   assert lock.held
   t=wd.Tick(False,True);assert t.now==early_tick
   progress(b,between);clock(actual_claim)
   with patch.object(wc.codex_sessions,'runtime_status',return_value='idle'), \
        patch.object(wc.engines,'codex_bin',return_value='fake-codex'), \
        patch.object(wc.subprocess,'run',side_effect=subprocess.TimeoutExpired('queue',20)):
    result=wc.wake('origin',hc.roles_load('origin')['roles']['hub'],'timing fixture',False,wd=wd,tick=t)
   assert not result['ok'] and 'unknown' in result['detail']
   wd.save_state(t.state)
 else:
  def before_reserve():
   progress(b,between);clock(actual_claim)
   return SimpleNamespace(hex='native-timing-fixture-token')
  with patch.object(wn,'uuid4',side_effect=before_reserve):
   claim('origin')
 ep=wd.load_state()['uuid_receipts'][b]
 assert ep['acted_at']==wd.iso(actual_claim),ep
 assert ep['next_try_at']==wd.iso(actual_claim+wd.wake_after()),ep
 clock(actual_claim+timedelta(hours=1))
 assert not candidate('origin')[0],'pre-claim recipient turn released later unknown '+transport
 assert wr.guard(wd,wd.load_state(),b,wd.clock()),transport
 progress(b,actual_claim+timedelta(minutes=1))
 rearmed,why=candidate('origin');assert rearmed,(transport,why)
 assert wr.guard(wd,wd.load_state(),b,wd.clock())=='',transport
paths[b].write_text(saved_rollout);os.utime(paths[b],(saved_mtime,)*2)
print('PASS CLI/native claims stamp fresh clock and cooldown; pre-claim turn holds unknown, post-claim turn re-arms')
# CompletedProcess is not delivery proof: signal and generic failure stay fenced.
for exit_code in (-9,7,0):
 fresh();clock(future+timedelta(hours=1))
 delivered=[]
 def process_outcome(argv,**kwargs):
  assert wd.load_state()['uuid_receipts'][b]['result']=='unknown'
  delivered.append(argv)
  return subprocess.CompletedProcess(argv,exit_code,stdout='accepted' if exit_code==0 else '',
                                     stderr='generic process failure' if exit_code else '')
 with wd.TickLock() as lock:
  assert lock.held
  t=wd.Tick(False,True)
  with patch.object(wc.codex_sessions,'runtime_status',return_value='idle'), \
       patch.object(wc.engines,'codex_bin',return_value='fake-codex'), \
       patch.object(wc.subprocess,'run',side_effect=process_outcome):
   result=wc.wake('origin',hc.roles_load('origin')['roles']['hub'],'fixture outcome',False,wd=wd,tick=t)
  wd.save_state(t.state)  # enclosing tick must retain an ambiguous outcome
 assert len(delivered)==1 and result['ok']==(exit_code==0),result
 if exit_code:
  assert wd.load_state()['uuid_receipts'][b]['result']=='unknown'
  clock(future+timedelta(hours=3))
  assert not candidate('origin')[0] and not candidate('other-cli-stage')[0]
  tick('other-cli-stage');assert len(queues)==1
  assert wd.load_state()['uuid_receipts'][b]['result']=='unknown'
 else:
  assert b not in wd.load_state()['uuid_receipts']
  rearmed,why=candidate('origin');assert rearmed,why
print('PASS SIGKILL -9 and generic nonzero preserve unknown across cached save/backoff/transports; accepted exit 0 closes it')
for bad in ([],{a:None},{a:{'session':a,'result':'unexpected'}},{a:{'session':b,'result':'unknown'}}):
 wd.save_state({'stages':{},'uuid_receipts':bad})
 assert not candidate('elsewhere')[0]
 tick('elsewhere');assert len(queues)==1
for raw in ('{broken','[]','{"stages":null}','{"stages":{"origin":5}}'):
 (wd.wd_dir()/'state.json').write_text(raw)
 assert not candidate('elsewhere')[0]
 tick('elsewhere');assert len(queues)==1
 assert not candidate('elsewhere')[0],'tick normalization removed corrupt-state fence'
print('PASS malformed shared ledger/file conservatively denies native and CLI, including after normalization')
fresh();clock(now)
for marker,value in (('do-not-wake.json',{'until':None}),('auto-handoff.json',{'pending':{'id':b}})):
 p=root/'origin'/marker;p.write_text(json.dumps(value))
 assert not candidate('origin')[0];tick('origin');assert len(queues)==1
 p.unlink()
with patch.dict(os.environ,{'AGENT_HUB_WATCHDOG':'off'}):
 assert wn.plan(wd,'origin')['candidates']==[]
 wd.cmd_run(SimpleNamespace(dry_run=False,json=True,stage='origin'))
 assert len(queues)==1
print('PASS disabled, quiet and pending controls unchanged')
PY
check $? 0 'UUID receipt fencing and native/CLI cross-transport regressions'
exit $fail
