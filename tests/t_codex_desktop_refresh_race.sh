#!/usr/bin/env bash
# Native self-refresh races at the real hub/Plan seam; synthetic state, no models or app API.
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
import contextlib, importlib.machinery, importlib.util, io, json, os, pathlib, subprocess, sys
root,tmp=map(pathlib.Path,sys.argv[1:])
repo=tmp/'repo';repo.mkdir()
def run(argv,env,cwd=repo):
    r=subprocess.run(list(map(str,argv)),env=env,cwd=cwd,capture_output=True,text=True)
    assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
    return r
for args in (('init','-q','-b','main'),('-c','user.email=t@t','-c','user.name=T','commit','--allow-empty','-qm','init')):
    subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True)
actual=repo/'.worktrees/native';subprocess.run(['git','-C',str(repo),'worktree','add','-qb','native',str(actual)],check=True,capture_output=True)
old='11111111-1111-4111-8111-111111111111';real='22222222-2222-4222-8222-222222222222';other='44444444-4444-4444-8444-444444444444'
home=tmp/'home';stage=home/'stage-a';stage.mkdir(parents=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('AGENT_','HUB_','CODEX_','CLAUDE_'))}
env.update(AGENT_HUB_HOME=str(home),AGENT_HUB_TZ='UTC',AGENT_HUB_ENGINE='codex',CODEX_THREAD_ID=old,
           CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',CODEX_APP_TOOLS_PIPE_PATH='/never-connect',
           CODEX_HOME=str(tmp/'codex'),CODEX_BIN=str(tmp/'must-not-launch'),CLAUDE_BIN=str(tmp/'must-not-launch'))
rollouts=tmp/'codex/sessions';rollouts.mkdir(parents=True)
for sid in (old,real,other):
    (rollouts/f'rollout-{sid}.jsonl').write_text(json.dumps({'type':'session_meta','payload':{'id':sid}})+'\n'+json.dumps({'type':'turn_context','payload':{'model':'gpt-6.1-sol','effort':'high','approval_policy':'never','sandbox_policy':{'type':'danger-full-access'}}})+'\n')
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':{'session':old,'cli_session_id':old,'tag':'hub-1','kind':'cli'}}}))
(stage/'stage.json').write_text(json.dumps({'goal':'Finish fixture'}))
handoff=stage/'HANDOFF.md';handoff.write_text('# Handoff "Hub fixture #1" → "Hub fixture #2"\n\n## 0. First steps\nTake over\n')
def hub(*args,env=env):return run([root/'bin/hub',*args],env,actual)
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--desktop-worktree')
req=json.loads((stage/'auto-handoff.json').read_text())['pending']['request_id']
hub('desktop-request','--stage','stage-a','--request',req,'--project-id','saved','--project-path',repo)
hub('desktop-bind','--stage','stage-a','--request',req,'--thread-id',real)
env['CODEX_THREAD_ID']=real
hub('takeover','--stage','stage-a','--session','self','--auto-handoff','--handoff',handoff,'--desktop-request',req)
# Only after native takeover: a resource, queue and project callback whose ownership must never change on refresh.
run([root/'bin/lock','rules','add','businessqueue','--about','fixture resource','--dir',actual],env,actual)
run([root/'bin/lock','take','businessqueue','--repo','fixture','--until','+1h','--why','fixture owner'],env,actual)
queue=stage/'night-queue.md';queue.write_text(f'coordinator: {real}\nupdated: native fixture\n')
config=stage/'takeover.sh';trace=stage/'project-calls'
config.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "'+str(trace)+'"\n');config.chmod(0o755)
paths=[home/'board.md',queue,stage/'roles.json',stage/'auto-handoff.json',stage/'stage.json',
       *sorted((stage/'coordinator/work').glob('journal-*.md'))]
def snapshot():return {str(p):p.read_bytes() for p in paths}|{'callbacks':trace.read_bytes() if trace.exists() else b''}
native=snapshot()
original_env=dict(os.environ);os.environ.clear();os.environ.update(env)
os.chdir(actual);sys.path.insert(0,str(root/'bin'))
import autopilot as ap
loader=importlib.machinery.SourceFileLoader('refresh_hub',str(root/'bin/hub'))
spec=importlib.util.spec_from_loader(loader.name,loader);h=importlib.util.module_from_spec(spec);sys.modules[spec.name]=h;loader.exec_module(h)
original_lock=ap.state_lock
argv=['takeover','--stage','stage-a','--session','self','--handoff',str(handoff)]
# Actual concurrent manual takeover runs immediately after the first proof's lock release.
# A correct atomic refresh may linearize before that takeover; either way it cannot touch its new owner's records.
inserted=[]
@contextlib.contextmanager
def race_after_proof(name):
    with original_lock(name):yield
    if not inserted:
        inserted.append(None)
        hub('takeover','--stage','stage-a','--session','self','--n','2','--handoff',handoff,env=dict(env,CODEX_THREAD_ID=other))
        inserted[0]=snapshot()
ap.state_lock=race_after_proof
try:
    with contextlib.redirect_stdout(io.StringIO()):
        try: result=h.main(argv)
        except ap.hc.Failure:result=1
    assert inserted and inserted[0]
    assert snapshot()==inserted[0], ('stale refresh changed concurrent manual owner resources before refusal',result,
                                    [p for p in inserted[0] if snapshot()[p]!=inserted[0][p]])
finally:ap.state_lock=original_lock
print('PASS concurrent manual takeover after native proof retains new owner board/queue/roles/state/callback bytes')
# A refresh scheduled after replacement must reject before generic takeover steps can reassert the old UUID.
before=snapshot()
with contextlib.redirect_stdout(io.StringIO()):
    try:h.main(argv)
    except ap.hc.Failure:pass
    else:raise AssertionError('replaced native identity unexpectedly refreshed')
assert snapshot()==before,'rejected stale native refresh mutated replacement records'
print('PASS stale native request identity rejects before resource/coordinator/project mutation')
# Restore only this synthetic fixture to the verified native boundary for exact positive controls.
for path,data in native.items():
    if path!='callbacks':pathlib.Path(path).write_bytes(data)
if trace.exists():trace.unlink()
original_generic=h._cmd_takeover
def forbidden_generic(a):raise AssertionError('native refresh entered generic takeover/Plan')
h._cmd_takeover=forbidden_generic
for args in (argv,argv+['--dry-run'],['start','--stage','stage-a','--session','self'],
             argv+['--auto-handoff','--desktop-request',req]):
    with contextlib.redirect_stdout(io.StringIO()):assert h.main(args)==0
    assert snapshot()==native,'exact refresh touched resources/coordinator/project/registration/state'
print('PASS exact native takeover/start/dry-run/explicit repeats bypass generic Plan and preserve every fixture byte')
for flag in (['--take-main-merge'],['--skip-lock','businessqueue'],['--main-merge-until','+30d'],
             ['--goal','changed'],['--name','changed'],['--repo',str(repo)],['--no-project'],
             ['--take-main-m'],['--main=+30d'],['--skip-lo=businessqueue'],['--go=changed']):
    with contextlib.redirect_stdout(io.StringIO()):
        try:h.main(argv+flag)
        except ap.hc.UsageError:pass
        else:raise AssertionError(('incompatible refresh instruction accepted',flag))
    assert snapshot()==native
print('PASS explicit resource/metadata/location instructions reject before mutation on pure native refresh')
h._cmd_takeover=original_generic
assert json.loads(hub('desktop-status','--stage','stage-a','--request',req,'--verified').stdout)['verified']

os.environ.clear();os.environ.update(original_env)
PY
