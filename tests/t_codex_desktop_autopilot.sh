#!/usr/bin/env bash
# Desktop contracts at actual hub command seams; no native app calls or model requests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
import contextlib, io, json, os, pathlib, shlex, subprocess, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root/'bin'))
import autopilot as ap
import engines
old = '11111111-1111-4111-8111-111111111111'
real = '22222222-2222-4222-8222-222222222222'
client = 'client-new-thread:33333333-3333-4333-8333-333333333333'
other = '44444444-4444-4444-8444-444444444444'
env = {k:v for k,v in os.environ.items() if not k.startswith(('AGENT_HUB_','HUB_','CODEX_','CLAUDE_','AGENT_'))}
env.update(AGENT_HUB_TZ='UTC', AGENT_HUB_ENGINE='codex', CODEX_THREAD_ID=old,
           CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop', CODEX_APP_TOOLS_PIPE_PATH='/never-connect',
           CODEX_BIN=str(tmp/'must-not-launch'), CLAUDE_BIN=str(tmp/'missing'), CODEX_HOME=str(tmp/'codex-home'))
repo=tmp/'repo'; repo.mkdir()
def git(*args): return subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True,text=True)
git('init','-q','-b','main'); git('-c','user.email=t@t','-c','user.name=T','commit','--allow-empty','-qm','init')
actual=repo/'.worktrees/app'; git('worktree','add','-q','-b','app',str(actual))
link=tmp/'project-link'; link.symlink_to(repo, target_is_directory=True)
rollouts=tmp/'codex-home/sessions'; rollouts.mkdir(parents=True)
def rollout(sid, policy, model='gpt-6.1-sol', effort='high'):
    (rollouts/f'rollout-{sid}.jsonl').write_text(json.dumps({'type':'session_meta','payload':{'id':sid}})+'\n'+
        json.dumps({'type':'turn_context','payload':{'model':model,'effort':effort,'approval_policy':'never','sandbox_policy':policy}})+'\n')
rollout(old, {'type':'danger-full-access'})
def setup(name):
    home=tmp/name; stage=home/'stage-a'; stage.mkdir(parents=True)
    env['AGENT_HUB_HOME']=str(home); env['CODEX_THREAD_ID']=old
    (stage/'roles.json').write_text(json.dumps({'roles':{'hub':{'session':old,'cli_session_id':old,'tag':'hub-1','kind':'cli'}}}))
    (stage/'stage.json').write_text(json.dumps({'goal':'Complete the fixture queue'}))
    handoff=stage/'HANDOFF-hub-test.md'
    handoff.write_text('# Handoff "Hub stage-a #1" → "Hub stage-a #2" — stage-a\n\n## 0. First steps\nTake over\n## 2. Queue\nWrite DONE and finish. No external work remains.\n')
    return home,stage,handoff

def hub(*args, cwd=repo, ok=True):
    r=subprocess.run([str(root/'bin/hub'),*map(str,args)],env=env,cwd=cwd,capture_output=True,text=True)
    if ok: assert r.returncode==0, (r.returncode,r.stdout,r.stderr)
    else: assert r.returncode!=0, r.stdout
    return r

def state(stage): return json.loads((stage/'auto-handoff.json').read_text())
def roles(stage): return json.loads((stage/'roles.json').read_text())['roles']['hub']
def prepare(handoff, *args): return hub('succeed','--stage','stage-a','--handoff',handoff,'--force',*args)
def request(req, path=link, pid='saved-project', ok=True):
    return hub('desktop-request','--stage','stage-a','--request',req,'--project-id',pid,'--project-path',path,ok=ok)
def bind(req, *args, ok=True): return hub('desktop-bind','--stage','stage-a','--request',req,*args,ok=ok)
def takeover(handoff, req, ok=True, **kwargs):
    args=('takeover','--stage','stage-a','--session','self','--auto-handoff','--handoff',handoff,
          '--desktop-request',req)
    r=hub(*args,ok=False,**kwargs) if ok and kwargs.get('cwd')==repo else hub(*args,ok=ok,**kwargs)
    if ok and r.returncode==4:
        assert not state(handoff.parent)['pending'].get('taken_over') or roles(handoff.parent)['session']==real
        move=pathlib.Path(next(line[5:] for line in r.stdout.splitlines() if line.startswith('MOVE ')))
        kwargs['cwd']=move
        r=hub(*args,ok=True,**kwargs)
    elif ok:
        assert r.returncode==0, (r.returncode,r.stdout,r.stderr)
    return r

# A containing Desktop workspace is not the recorded stage repository. Exercise the real
# succeed seam from the valid predecessor worktree with an explicitly incorrect --cwd.
unrelated=tmp/'other-repo'; unrelated.mkdir()
subprocess.run(['git','-C',str(unrelated),'init','-q'],check=True,capture_output=True)
for name, recorded, target in (
    ('parent', str(repo), tmp),
    ('other-repo', str(repo), unrelated),
    ('missing-repo', str(tmp/'deleted-repo'), actual),
    ('invalid-repo', {'path':str(repo)}, actual),
    ('empty-repo', '', actual),
):
    home,stage,handoff=setup('project-root-'+name)
    (stage/'stage.json').write_text(json.dumps({'goal':'Complete the fixture queue','repo':recorded}))
    (stage/'roles.json').write_text(json.dumps({'roles':{'hub':{
        'session':old,'cli_session_id':old,'tag':'hub-1','kind':'cli','cwd':str(actual)}}}))
    before={str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
    r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop',
          '--cwd',target,cwd=actual,ok=False)
    assert 'no desktop request prepared' in r.stderr, (name,r.stdout,r.stderr)
    assert {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}==before, name
    assert not (stage/'auto-handoff.json').exists() and not (stage/'work').exists(), name

for name, content in (('malformed-json','{"repo":'), ('non-object','["not a stage record"]')):
    home,stage,handoff=setup('project-record-'+name)
    (stage/'stage.json').write_text(content)
    before={str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
    r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop',
          '--cwd',actual,cwd=actual,ok=False)
    assert 'no desktop request prepared' in r.stderr, (name,r.stdout,r.stderr)
    assert {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}==before, name

# An existing unreadable record must not masquerade as a legacy absent record.
home,stage,handoff=setup('project-record-unreadable')
(stage/'stage.json').unlink(); (stage/'stage.json').mkdir()
before={str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop',
      '--cwd',actual,cwd=actual,ok=False)
assert 'no desktop request prepared' in r.stderr, (r.stdout,r.stderr)
assert {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}==before

home,stage,handoff=setup('project-record-absent')
(stage/'stage.json').unlink()
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--cwd',tmp,cwd=tmp)
assert state(stage)['pending']['project_root']==str(tmp.resolve()) and state(stage)['chain']==1

home,stage,handoff=setup('project-record-broken-symlink')
metadata=stage/'stage.json'; metadata.unlink(); metadata.symlink_to(stage/'missing-stage.json')
before={str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop',
      '--cwd',tmp,cwd=actual,ok=False)
assert 'no desktop request prepared' in r.stderr, (r.stdout,r.stderr)
assert {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}==before
assert metadata.is_symlink() and os.readlink(metadata)==str(stage/'missing-stage.json')

home,stage,handoff=setup('project-root-worktree')
(stage/'stage.json').write_text(json.dumps({'goal':'Complete the fixture queue','repo':str(repo)}))
prepare_result=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--cwd',actual,cwd=actual)
assert state(stage)['pending']['project_root']==str(repo.resolve())
assert state(stage)['pending']['predecessor_cwd']==str(actual.resolve())
saved=state(stage)
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again','--cwd',tmp,cwd=actual)
assert state(stage)==saved, 'replay must retain the original reservation without validating a new target'

home,stage,handoff=setup('project-root-none')
(stage/'stage.json').write_text(json.dumps({'goal':'Complete the fixture queue','no_project':True}))
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--cwd',tmp,cwd=tmp)
assert state(stage)['pending']['project_root']==str(tmp.resolve()) and state(stage)['chain']==1
print('PASS stage repository identity rejects invalid targets before any files change; linked worktrees, projectless stages and replay retain their contracts')

# Drive the original incident argv and its default-auto alternative through hub's parser and succeed.
# Only the final detached launcher is replaced; discovery, selection, reservation and reporting stay real.
launcher=tmp/'surface-seam.py'
launcher.write_text('''import json, os, pathlib, runpy, sys
root=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(root/'bin'))
import autopilot as ap
trace=pathlib.Path(os.environ['AGENT_HUB_HOME'])/'surface-trace.json'
trace.write_text(json.dumps({'argv':sys.argv[2:]}))
def launch(self, why):
    data=json.loads(trace.read_text()); data['launch_argv']=self.dry_spawn_argv()
    trace.write_text(json.dumps(data))
    return {'role':f'hub-{self.succ}', 'brief':str(self.handoff)}
ap.CodexSuccessor.start_headless=launch
main=runpy.run_path(str(root/'bin/hub'))['main']
raise SystemExit(ap.hc.run_main(main,sys.argv[2:]))
''')
sentinel=tmp/'must-not-launch'
sentinel.write_text('#!/bin/sh\nexit 99\n'); sentinel.chmod(0o755)
opt_in='AGENT_HUB_DESKTOP_CLI_HANDOFF'
def surface_case(name, flags, *, permitted=False, native=False, owner=None, project=False, env_opt=False, host='app'):
    home,stage,handoff=setup('surface-'+name)
    if owner is not None: (home/'config.json').write_text(json.dumps({opt_in:owner}))
    config=repo/'.agent-hub/config.json'; config.parent.mkdir(exist_ok=True)
    config.write_text(json.dumps({opt_in:True}) if project else '{}')
    case_env=dict(env)
    if env_opt: case_env[opt_in]='true'
    if host=='terminal':
        for key in engines.CODEX_APP_ENV: case_env.pop(key,None)
    elif host=='detached': case_env['AGENT_ROLE']='hub-1'
    argv=['succeed','--stage','stage-a','--handoff',str(handoff),'--force','--engine','codex',
          '--permission-mode','bypassPermissions','--cwd',str(repo),*flags]
    r=subprocess.run([sys.executable,str(launcher),str(root),*argv],env=case_env,cwd=repo,capture_output=True,text=True)
    trace=json.loads((home/'surface-trace.json').read_text())
    assert trace['argv']==argv, 'surface discovery lost the original caller argv'
    if native:
        assert r.returncode==0 and 'launch_argv' not in trace, (name,r.returncode,r.stdout,r.stderr)
        assert state(stage)['pending']['surface']=='desktop' and state(stage)['chain']==1
        req=state(stage)['pending']['request_id']; before=(stage/'auto-handoff.json').read_bytes()
        r=subprocess.run([sys.executable,str(launcher),str(root),*argv,'--again'],env=case_env,cwd=repo,capture_output=True,text=True)
        assert r.returncode==0 and state(stage)['pending']['request_id']==req
        assert (stage/'auto-handoff.json').read_bytes()==before and 'launch_argv' not in json.loads((home/'surface-trace.json').read_text())
    elif permitted:
        assert r.returncode==0 and 'launch_argv' in trace, (name,r.returncode,r.stdout,r.stderr)
        assert '--engine' in trace['launch_argv'] and 'codex' in trace['launch_argv']
        assert state(stage)['pending']['kind']=='headless' and state(stage)['chain']==1
    else:
        assert r.returncode!=0 and 'launch_argv' not in trace, ('Desktop CLI override reached launcher',name,r.returncode,trace)
        assert opt_in in r.stderr and 'owner' in r.stderr, r.stderr
        assert not (stage/'auto-handoff.json').exists(), 'refusal changed reservation/chain'
    assert roles(stage)['session']==old and not (stage/'agents').exists()
    config.unlink()
    return home,stage,handoff

# Retry flags change the one prepared request; dispatch locks its settings even
# when native creation is uncertain. Only explicit no-created evidence unlocks it.
home,stage,handoff=setup('retry-settings')
prepare(handoff)
initial=state(stage)['pending']; req=initial['request_id']
prepare(handoff,'--again','--model','gpt-6-sol','--effort','medium')
p=state(stage)['pending']
assert p['request_id']==req and state(stage)['chain']==1
assert p['requested']['model']=='gpt-6-sol' and p['requested']['effort']=='medium'
assert p['create_args']['model']=='gpt-6-sol' and p['create_args']['thinking']=='medium'
assert pathlib.Path(p['brief']).read_text()==p['create_args']['prompt']
assert 'human authority source/reference and scope' in p['create_args']['prompt']
assert '"model": "gpt-6-sol"' in p['create_args']['prompt']
saved=(stage/'auto-handoff.json').read_bytes()
prepare(handoff,'--again','--model','gpt-6.1-sol','--effort','high','--dry-run')
assert (stage/'auto-handoff.json').read_bytes()==saved
args=json.loads(request(req).stdout)['create_thread']
assert args['model']=='gpt-6-sol' and args['thinking']=='medium'
saved=(stage/'auto-handoff.json').read_bytes()
prepare(handoff,'--again','--model','gpt-6-sol','--effort','medium')
assert (stage/'auto-handoff.json').read_bytes()==saved
r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again',
      '--model','gpt-6.1-sol','--effort','high',ok=False)
assert 'already dispatched' in r.stderr and '--no-thread-created' in r.stderr
assert (stage/'auto-handoff.json').read_bytes()==saved
hub('desktop-fail','--stage','stage-a','--request',req,'--why','native outcome unknown')
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again','--effort','high',ok=False)
hub('desktop-fail','--stage','stage-a','--request',req,'--why','verified no created thread','--no-thread-created')
prepare(handoff,'--again','--model','gpt-6.1-sol','--effort','high')
assert state(stage)['pending']['request_id']==req and state(stage)['chain']==1
assert state(stage)['pending']['requested']['effort']=='high'
request(req); bind(req,'--thread-id',real)
saved=(stage/'auto-handoff.json').read_bytes()
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again','--effort','medium',ok=False)
assert (stage/'auto-handoff.json').read_bytes()==saved
print('PASS retry flags update prepared settings/brief/create args; dispatch/uncertain/bound settings immutable; no duplicate reservation')

# A current turn context far before the last 4 MiB still supplies exact settings.
home,stage,handoff=setup('large-parent-rollout')
rollout(old,{'type':'workspace-write','writable_roots':[str(repo)],'network_access':False},effort='medium')
with (rollouts/f'rollout-{old}.jsonl').open('a') as f:
    f.write(json.dumps({'type':'response_item','payload':{'type':'function_call_output','output':'x'*(9<<20)}})+'\n')
prepare(handoff)
p=state(stage)['pending']
assert p['requested']=={'model':'gpt-6.1-sol','effort':'medium','approval_policy':'never',
    'sandbox_policy':{'type':'workspace-write','writable_roots':[str(repo)],'network_access':False}}
# Missing and unsupported settings produce an actionable failure, not a handoff
# loop at the hard context boundary; valid observations recover without widening.
for name, settings, args, reason in (
    ('missing-rollout', None, (), 'model is unknown'),
    ('missing-model', {'effort':'high','sandbox_policy':{'type':'danger-full-access'},'approval_policy':'never'}, (), 'model is unknown'),
    ('missing-effort', {'model':'gpt-6.1-sol','sandbox_policy':{'type':'danger-full-access'},'approval_policy':'never'}, (), 'effort is unknown'),
    ('bad-effort', {'model':'gpt-6.1-sol','effort':'invented','sandbox_policy':{'type':'danger-full-access'},'approval_policy':'never'}, (), 'unsupported inherited Codex effort'),
    ('missing-sandbox', {'model':'gpt-6.1-sol','effort':'high','approval_policy':'never'}, (), 'sandbox'),
    ('missing-approval', {'model':'gpt-6.1-sol','effort':'high','sandbox_policy':{'type':'danger-full-access'}}, (), 'approval policy'),
    ('bad-approval', {'model':'gpt-6.1-sol','effort':'high','sandbox_policy':{'type':'danger-full-access'},'approval_policy':'invented'}, (), 'approval policy'),
    ('explicit-without-approval', None, ('--model','gpt-6.1-sol','--effort','high','--permission-mode','bypassPermissions'), 'approval policy'),
):
    home,stage,handoff=setup(name)
    log = rollouts/f'rollout-{old}.jsonl'
    if settings is None:
        log.unlink(missing_ok=True)
    else:
        log.write_text(json.dumps({'type':'session_meta','payload':{'id':old}})+'\n'+
                       json.dumps({'type':'turn_context','payload':settings})+'\n')
    env['AGENT_HUB_CODEX_DEFAULT_MODEL']='gpt-6-sol'
    roles_before = (stage/'roles.json').read_bytes()
    r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force',*args,ok=False)
    assert r.returncode == 2 and reason in r.stderr, (r.returncode,r.stderr)
    assert 'No successor was launched by this attempt' in r.stderr, r.stderr
    assert 'Required recovery' in r.stderr and str(handoff.resolve()) in r.stderr, r.stderr
    assert 'journal BLOCKED' in r.stderr and 'end this shift' in r.stderr and 'Do not compact' in r.stderr
    assert not (stage/'auto-handoff.json').exists() and not (stage/'agents').exists()
    assert (stage/'roles.json').read_bytes() == roles_before and handoff.is_file()
    # Same predecessor, finite queue and authority; only actual observed settings change.
    rollout(old, {'type':'workspace-write','writable_roots':[str(repo)],'network_access':False}, effort='medium')
    prepare(handoff)
    recovered=state(stage)['pending']['requested']
    assert recovered['model']=='gpt-6.1-sol' and recovered['effort']=='medium'
    assert recovered['sandbox_policy']['type']=='workspace-write' and recovered['approval_policy']=='never'
    assert roles(stage)['session']==old and state(stage)['chain']==1
    env.pop('AGENT_HUB_CODEX_DEFAULT_MODEL')
rollout(old, {'type':'danger-full-access'})
print('PASS observed >9 MiB settings, missing/unknown settings nonzero saved-handoff recovery and actual restricted-setting retry without model default/launch')

surface_case('default-auto',[],native=True)
surface_case('explicit-auto',['--surface','auto'],native=True)
surface_case('explicit-desktop',['--surface','desktop'],native=True)
surface_case('owner-auto-remains-native',[],owner=True,native=True)
for name,flags in (('cli',['--surface','cli']),('headless',['--headless']),
                   ('auto-headless',['--surface','auto','--headless']),
                   ('engine-change',['--engine','claude','--surface','cli'])):
    surface_case(name,flags)
surface_case('repo-cannot-authorize',['--surface','cli'],project=True)
surface_case('env-cannot-authorize',['--surface','cli'],env_opt=True)
surface_case('home-false-wins',['--surface','cli'],owner=False,env_opt=True,project=True)
for name,flags in (('owner-cli',['--surface','cli']),('owner-headless',['--headless'])):
    surface_case(name,flags,owner=True,permitted=True)
for host in ('terminal','detached'):
    for surface in ('auto','cli'):
        surface_case(host+'-'+surface,['--surface',surface],host=host,permitted=True)
    surface_case(host+'-headless',['--headless'],host=host,permitted=True)
home,stage,handoff=surface_case('revoked-owner',['--surface','cli'],owner=True,permitted=True)
(home/'config.json').write_text(json.dumps({opt_in:False}))
before=(stage/'auto-handoff.json').read_bytes()
for flag in ('--replace','--fallback'):
    r=hub('succeed','--stage','stage-a','--force','--handoff',handoff,flag,ok=False)
    assert opt_in in r.stderr and (stage/'auto-handoff.json').read_bytes()==before
    assert roles(stage)['session']==old and not (stage/'agents').exists()
print('PASS actual succeed seam captures original argv; Desktop CLI/headless require home owner opt-in; repository/env cannot grant it; terminal/detached remain CLI')

# Authority is evaluated by the app agent, not fabricated from --force/config by the CLI.
# Exercise the actual emitted preparation and create prompt with inherited, absent and revoked sources.
for authority_case, authority in (
    ('inherited', 'Explicit human instruction fixture-owner-chat, D-FIXTURE-001: one automatic same-stage context successor until revoked.'),
    ('absent', 'No human native creation instruction is recorded.'),
    ('revoked', 'D-FIXTURE-002 revokes D-FIXTURE-001; retain the predecessor and ask once.'),
):
    home,stage,handoff=setup('authority-'+authority_case)
    rules=home/'hub-rules.md'; rules.write_text(authority+'\n')
    handoff.write_text(handoff.read_text()+'\n## Authority\nSource: '+str(rules)+'; '+authority+'\n')
    prep=prepare(handoff)
    req=state(stage)['pending']['request_id']
    emitted=json.loads(request(req).stdout)
    prompt=emitted['create_thread']['prompt']
    # Actual source pointers must survive both dispatch instructions and successor prompt.
    assert str(rules) in prep.stdout, 'native preparation hides the standing human authority source'
    assert str(rules) in prompt and str(handoff.resolve()) in prompt, 'takeover loses authority source pointers'
    for text in (prep.stdout,prompt):
        assert 'standing' in text.lower() and 'scope' in text.lower() and 'revok' in text.lower(), text
    assert 'without' in prep.stdout and 'per-transfer' in prep.stdout, 'inherited grant still needs a fresh transfer approval'
    assert 'ask once' in prep.stdout and 'unrelated' in prep.stdout, 'missing/revoked/new scope has no owner-request boundary'
    assert authority not in prompt, 'CLI copied source contents instead of passing pointers for app evaluation'
    assert not emitted['already_dispatched'] and state(stage)['chain']==1
    assert roles(stage)['session']==old and not (stage/'agents').exists()
    assert json.loads(request(req).stdout)['already_dispatched'], 'authority wording allowed duplicate dispatch'
print('PASS emitted native prep/prompt carry authority sources without inferring a grant; inherited/absent/revoked fixtures preserve one request and predecessor')

# A worktree-local revocation overrides a different main-checkout rule.
home,stage,handoff=setup('authority-worktree')
main_rules=repo/'.agent-hub/hub-rules.md'; main_rules.parent.mkdir(exist_ok=True)
main_rules.write_text('Main-checkout grant remains active.\n')
worktree_rules=actual/'.agent-hub/hub-rules.md'; worktree_rules.parent.mkdir(exist_ok=True)
worktree_rules.write_text('Worktree owner revokes the home grant.\n')
(home/'hub-rules.md').write_text('Home owner grants automatic context handoff.\n')
prep=hub('succeed','--stage','stage-a','--handoff',handoff,'--force',cwd=actual)
assert str(worktree_rules.resolve()) in prep.stdout and str(main_rules.resolve()) not in prep.stdout, 'native prep misses predecessor worktree revocation layer'
req=state(stage)['pending']['request_id']; saved=state(stage)
replay=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again',cwd=repo)
assert str(worktree_rules.resolve()) in replay.stdout and str(main_rules.resolve()) not in replay.stdout, 'replay resolves authority from caller instead of predecessor'
assert state(stage)==saved and roles(stage)['session']==old
payload=json.loads(request(req).stdout)
assert str(worktree_rules.resolve()) in payload['create_thread']['prompt'] and str(main_rules.resolve()) not in payload['create_thread']['prompt']
assert json.loads(request(req).stdout)['already_dispatched'] and state(stage)['chain']==1
# Legacy reservations lack provenance: never present main/current cwd as the predecessor's rule source.
home,stage,handoff=setup('authority-legacy')
prepare(handoff); legacy=state(stage); req=legacy['pending']['request_id']
legacy['pending'].pop('predecessor_cwd',None)
(stage/'auto-handoff.json').write_text(json.dumps(legacy))
saved=state(stage)
replay=hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--again',cwd=actual)
assert 'predecessor cwd' in replay.stdout and 'unknown' in replay.stdout and 'retain' in replay.stdout
assert str(main_rules.resolve()) not in replay.stdout and str(worktree_rules.resolve()) not in replay.stdout
assert state(stage)==saved and roles(stage)['session']==old
payload=json.loads(request(req).stdout)
assert 'predecessor cwd' in payload['create_thread']['prompt'] and 'unknown' in payload['create_thread']['prompt']
assert json.loads(request(req).stdout)['already_dispatched'] and state(stage)['chain']==1
worktree_rules.unlink(); worktree_rules.parent.rmdir(); main_rules.unlink()
print('PASS worktree authority layer survives replay from main; legacy unknown provenance preserves request/predecessor and dispatch guard')

home,stage,handoff=setup('desktop')
filled=handoff.read_text(); handoff.write_text(filled.replace('Take over','TODO take over'))
r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force',ok=False)
assert 'TODO' in r.stderr and not (stage/'auto-handoff.json').exists()
handoff.write_text(filled)
r=prepare(handoff)
p=state(stage)['pending']; req=p['request_id']
assert p['surface']=='desktop' and p['kind']=='desktop' and p['phase']=='prepared' and not p.get('id')
assert state(stage)['chain']==1 and not (stage/'agents').exists()
assert 'prepared' in r.stdout and 'Full Access' in r.stdout and 'list_projects' in r.stdout
assert roles(stage)['session']==old
# Execute the printed waiter, including its since format, against the actual journal seam.
waiter=next(line.strip() for line in r.stdout.splitlines() if line.strip().startswith(shlex.quote(str(root/'bin/jwait'))))
assert '--since '+p['at'][:16] in waiter
subprocess.run([str(root/'bin/jlog'),'--stage','stage-a','--tag','hub-2','start: waiter-control'],env=env,check=True,capture_output=True)
w=subprocess.run(shlex.split(waiter),env=env,cwd=repo,capture_output=True,text=True,timeout=5)
assert w.returncode==0 and 'start: waiter-control' in w.stdout,(w.returncode,w.stdout,w.stderr)
hub('desktop-status' ,'--stage','stage-a','--request',req,'--verified',ok=False)
print('PASS app markers prepare a desktop request without launching a CLI or changing hub identity')
prepare(handoff, '--again'); assert state(stage)['pending']['request_id']==req and state(stage)['chain']==1
hub('succeed','--stage','stage-a','--handoff',handoff,'--force',ok=False)
assert state(stage)['chain']==1
# Changing the named successor/handoff or surface cannot replace an unfinished desktop reservation.
alternate=stage/'HANDOFF-hub-alternate.md'
alternate.write_text('# Handoff "Hub stage-a #1" → "Hub stage-a #7" — stage-a\n')
saved=state(stage)
for extra in ([], ['--again'], ['--surface','cli']):
    hub('succeed','--stage','stage-a','--handoff',alternate,'--force',*extra,ok=False)
    assert state(stage)==saved and not (stage/'agents').exists()
unrelated=tmp/'unrelated-workspace'; unrelated.mkdir()
request(req,path=unrelated,ok=False); assert state(stage)['pending']['phase']=='prepared'
payload=json.loads(request(req).stdout)
args=payload['create_thread']
assert not payload['already_dispatched']
assert args['target']=={'type':'project','projectId':'saved-project','environment':{'type':'local'}}
assert args['model']=='gpt-6.1-sol' and args['thinking']=='high'
assert args['title']=='Hub stage-a #2 — Complete the fixture queue'
assert '--desktop-request '+req in args['prompt'] and 'finite' in args['prompt'] and '--for 9m' not in args['prompt']
prompt = args['prompt']
for phrase in ('Terminal follow-through', 'remaining approved Business DoD', 'resource ownership',
               'next independent authorized ready work', 'expected event',
               "executor's artifact/call-budget STOP ends its brief", 'explicit owner stop', 'source/scope',
               'prepare the required handoff', 'next quiet point',
               'Do not compact to extend the shift', 'only the handoff procedure may continue',
               'journal the settings refusal and end the shift', 'genuine data/resource/safety gates and human stop'):
    assert phrase in prompt, (phrase, prompt)
assert 'When nothing remains' not in prompt

assert '[agent-hub auto-handoff 1/' in args['prompt'] and '[delamain auto-handoff' not in args['prompt']  # rename:keep  (the former name for one release: an older hub's hook reads only it)
assert 'sandbox' not in args and 'approval' not in args
assert json.loads(request(req).stdout)['already_dispatched']
assert state(stage)['chain']==1
print('PASS same normalized main project, default local surface, actual model/thinking fields and dispatch retry guard')

# Preserve the already installed containing-workspace adapter without widening
# the exact repository binding or allowing native worktrees from a parent folder.
home,container_stage,container_handoff=setup('containing-workspace')
hub('succeed','--stage','stage-a','--handoff',container_handoff,'--force','--cwd',actual,cwd=actual)
container=state(container_stage)['pending']; container_req=container['request_id']
request(container_req,path=unrelated,ok=False)
escape=tmp/'workspace-escape'; escape.symlink_to(unrelated, target_is_directory=True)
saved=state(container_stage)
request(container_req,path=escape,ok=False)
assert state(container_stage)==saved and saved['pending']['phase']=='prepared'
payload=json.loads(request(container_req,path=tmp).stdout)
assert not payload['already_dispatched']
assert payload['create_thread']['target']['environment']=={'type':'local'}
assert f'containing workspace `{tmp.resolve()}`' in payload['create_thread']['prompt']
assert f'existing checkout `{actual.resolve()}`' in payload['create_thread']['prompt']
assert state(container_stage)['pending']['project_root']==str(repo.resolve())
assert state(container_stage)['pending']['predecessor_cwd']==str(actual.resolve())
# The serialized prompt uses canonical paths for a saved workspace alias too.
workspace_alias=tmp/'workspace-alias'; workspace_alias.symlink_to(tmp, target_is_directory=True)
home,alias_stage,alias_handoff=setup('symlink-workspace-positive')
hub('succeed','--stage','stage-a','--handoff',alias_handoff,'--force','--cwd',actual,cwd=actual)
alias_req=state(alias_stage)['pending']['request_id']
alias_prompt=json.loads(request(alias_req,path=workspace_alias).stdout)['create_thread']['prompt']
assert f'containing workspace `{workspace_alias.resolve()}`' in alias_prompt
assert f'containing workspace `{workspace_alias}`' not in alias_prompt
assert f'existing checkout `{actual.resolve()}`' in alias_prompt
# A same-shaped alias pointing outside this repository must remain a negative control.
home,negative_stage,negative_handoff=setup('symlink-workspace-negative')
prepare(negative_handoff); negative_req=state(negative_stage)['pending']['request_id']
request(negative_req,path=escape,ok=False)
assert state(negative_stage)['pending']['phase']=='prepared'
env['AGENT_HUB_HOME']=str(container_stage.parent)
assert json.loads(request(container_req,path=tmp).stdout)['already_dispatched']
home,bad_stage,bad_handoff=setup('parent-worktree-refused')
prepare(bad_handoff,'--desktop-worktree'); bad_req=state(bad_stage)['pending']['request_id']
request(bad_req,path=tmp,ok=False)
assert state(bad_stage)['pending']['phase']=='prepared'
home,bad_stage,bad_handoff=setup('parent-provenance-refused')
prepare(bad_handoff); bad=state(bad_stage); bad_req=bad['pending']['request_id']
bad['pending'].pop('predecessor_cwd'); (bad_stage/'auto-handoff.json').write_text(json.dumps(bad))
request(bad_req,path=tmp,ok=False)
assert state(bad_stage)['pending']['phase']=='prepared'
print('PASS containing local workspace adapter retains exact repo/cwd and single dispatch; unrelated/symlink-escape/worktree/unknown-provenance parents refused')
# Restore the original desktop fixture for its subsequent bind/takeover checks.
env['AGENT_HUB_HOME']=str(stage.parent)
bind(req,'--client-thread-id',client,'--project-id','saved-project')
assert state(stage)['pending']['client_thread_id']==client and not state(stage)['pending'].get('id')
bind(req,'--thread-id',client,ok=False)
env['CODEX_THREAD_ID']=client; rollout(client,{'type':'danger-full-access'})
takeover(handoff,req,ok=False,cwd=repo); assert roles(stage)['session']==old
env['CODEX_THREAD_ID']=old
bind(req,'--thread-id',real,'--project-id','saved-project'); bind(req,'--thread-id',real)
bind(req,'--thread-id',other,ok=False); bind('stale-token','--thread-id',real,ok=False)
saved=state(stage)
hub('succeed','--stage','stage-a','--fallback','--force',ok=False)
assert state(stage)==saved
assert state(stage)['chain']==1 and not state(stage)['pending'].get('taken_over')
hub('desktop-fail','--stage','stage-a','--request',req,'--why','cannot claim failure','--no-thread-created',ok=False)
print('PASS client IDs never become sessions; bind is repeatable and rejects stale/conflicting identity')
env['CODEX_THREAD_ID']=real
hub('takeover','--stage','stage-a','--session','self','--auto-handoff','--handoff',handoff,'--desktop-request',req,'--n','9',ok=False,cwd=repo)
assert roles(stage)['session']==old
rollout(real,{'type':'workspace-write','writable_roots':[str(actual)],'network_access':False})
takeover(handoff,req,ok=False,cwd=repo)
assert roles(stage)['session']==old and not state(stage)['pending'].get('taken_over')
rollout(real,{'type':'danger-full-access'},model='observed-model',effort='medium')
takeover(handoff,req,cwd=repo); p=state(stage)['pending']
assert roles(stage)['session']==real and roles(stage)['surface']=='desktop'
assert p['id']==real and pathlib.Path(p['cwd']).parent==repo.resolve()/'.claude/worktrees' and p['project_id']=='saved-project'
assert p['observed']['model']=='observed-model' and p['observed']['effort']=='medium'
assert p['requested']['model']=='gpt-6.1-sol' and p['requested']['sandbox_policy']['type']=='danger-full-access'
assert p['observed']['sandbox_policy']['type']=='danger-full-access' and p['taken_over'] and state(stage)['chain']==1
assert json.loads(hub('desktop-status','--stage','stage-a','--request',req,'--verified').stdout)['verified']
bind(req,'--thread-id',real); takeover(handoff,req,cwd=pathlib.Path(p['cwd']))
assert state(stage)['chain']==1
print('PASS restricted home access leaves predecessor active; actual takeover reconciles identity/cwd and records observed settings separately')

# Exact same-shift host refresh must retain the native request and registration boundary.
saved=state(stage); registered=roles(stage)
for _ in range(2):
    hub('takeover','--stage','stage-a','--session','self','--handoff',handoff,cwd=saved['pending']['cwd'])
    refreshed=state(stage)
    assert refreshed==saved, ('same-shift refresh corrupted native request', saved['pending']['id'],
                             refreshed['pending'].get('id'), refreshed['pending'].get('kind'))
    assert roles(stage)==registered, ('same-shift registration changed', registered, roles(stage))
    assert json.loads(hub('desktop-status','--stage','stage-a','--request',req,'--verified').stdout)['verified']
hub('start','--stage','stage-a','--session','self',cwd=saved['pending']['cwd'])
assert state(stage)==saved and roles(stage)==registered
print('PASS exact same UUID takeover/start refresh retains native request, chain, roles and takeover boundary')

# Replay the frozen pre-fix on_takeover at the real hub seam, with the legacy state schema.
# Keep this fixture self-contained: CI shallow checkouts need no historical commit or model call.
LEGACY_TAKEOVER = r'''def on_takeover(stage: str, n: int, auto: bool = False, session: str = "", locked: bool = False) -> None:
    """Called by `hub takeover` once it is done: the pending automatic successor (its takeover carries
    --auto-handoff, which only `hub succeed` writes) keeps the chain; so does a takeover of the shift that successor
    already took over (a replacement of it, by hand or by `hub succeed --replace`): the record stays and only its
    session id is rewritten. Any other takeover resets the chain — a takeover by hand means the owner is involved,
    even when it gets the number of a successor that has not taken over yet."""
    with contextlib.nullcontext() if locked else state_lock(stage):
        data = load_state(stage)
        pend = data.get("pending") or {}
        if pend.get("n") == n and (auto or pend.get("taken_over")):
            changed = False
            if not pend.get("taken_over"):
                pend["taken_over"] = hc.now().isoformat(timespec="seconds")
                changed = True
            if not auto and session and (pend.get("id") != session[:8] or pend.get("kind") != "manual"):
                # a session started by hand holds the shift now: the launch the record described (a background
                # session, a headless role) is gone, and `--replace` must not act on it
                pend["id"], pend["kind"], changed = session[:8], "manual", True
                for key in ("role", "link", "worktree", "bg_id", "why"):
                    pend.pop(key, None)
            if changed:
                save_state(stage, data)
            return
        if not data["chain"] and not pend:
            return
        was = data["chain"]
        data["chain"], data["pending"] = 0, None
        save_state(stage, data)
    if was:
        hc.journal_append(stage, f"hub-{n}", f"auto-handoff chain reset ({was} → 0): a takeover by hand")

'''
def legacy_hub(*args, cwd=repo, freeze='2026-01-01T12:00:00+00:00'):
    code="import runpy,sys; sys.path.insert(0,sys.argv[1]); import hubcore as hc; import autopilot as ap; "
    code+=f"hc.now=lambda: hc.dt.datetime.fromisoformat({freeze!r}); "
    code+=f"exec({LEGACY_TAKEOVER!r},ap.__dict__); "
    # Saving through the real seam emits the old schema; only the newly added proof fields are omitted.
    code+="exec(\"original_save=ap.save_state\\ndef legacy_save(stage,data):\\n    p=data.get('pending') or {}\\n    p.pop('actual_thread_id',None); p.pop('registration',None)\\n    original_save(stage,data)\\nap.save_state=legacy_save\"); "
    code+="ap.desktop_identity_proof=lambda stage,request,session,**kw: (ap.load_state(stage),ap.load_state(stage)['pending'],hc.roles_load(stage)['roles']['hub']); "
    code+="sys.argv=sys.argv[2:]; g=runpy.run_path(sys.argv[0],run_name='legacy'); "
    code+="g['main'].__globals__['native_self_refresh']=lambda a,stage,session,request: ap.on_takeover(stage,ap.load_state(stage)['pending']['n'],session=session,locked=True) or 0; "
    code+="sys.exit(g['main'](sys.argv[1:]))"
    r=subprocess.run([sys.executable,'-c',code,str(root/'bin'),str(root/'bin/hub'),*map(str,args)],
                     cwd=cwd,env=env,capture_output=True,text=True)
    assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
    return r
home,stage,handoff=setup('legacy-recovery')
legacy_hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--desktop-worktree')
req=state(stage)['pending']['request_id']
legacy_hub('desktop-request','--stage','stage-a','--request',req,'--project-id','saved-project','--project-path',repo)
legacy_hub('desktop-bind','--stage','stage-a','--request',req,'--thread-id',real)
env['CODEX_THREAD_ID']=real
rollout(real,{'type':'danger-full-access'},model='observed-model',effort='medium')
legacy_hub('takeover','--stage','stage-a','--session','self','--auto-handoff','--handoff',handoff,
           '--desktop-request',req,cwd=actual)
original=state(stage); registered=roles(stage)
assert 'registration' not in original['pending'] and 'actual_thread_id' not in original['pending']
legacy_hub('takeover','--stage','stage-a','--session','self','--handoff',handoff,cwd=actual,freeze=registered['set_at'])
corrupted=state(stage); refreshed=roles(stage)
assert corrupted['pending']['id']==real[:8] and corrupted['pending']['kind']=='manual'
assert refreshed==registered, ('legacy role boundary unexpectedly changed',registered,refreshed)
r=hub('desktop-status','--stage','stage-a','--request',req,'--verified',ok=False)
assert 'later hub' in r.stdout+r.stderr, (r.stdout,r.stderr)

def recover(ok=True, token=None, cwd=actual):
    before=((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes())
    r=hub('desktop-recover','--stage','stage-a','--request',token or req,cwd=cwd,ok=ok)
    if not ok:
        assert ((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes())==before
    return r
# Every negative checks byte-exact state and registration before/after the command.
recover(ok=False,token='stale-token')
recover(ok=False,cwd=repo)
rollout(real,{'type':'workspace-write','writable_roots':[str(actual)]},model='observed-model',effort='medium')
recover(ok=False)
rollout(real,{'type':'danger-full-access'},model='observed-model',effort='medium')
same_prefix='22222222-9999-4999-8999-999999999999'
rollout(same_prefix,{'type':'danger-full-access'},model='observed-model',effort='medium')
for updates in ({'session':same_prefix,'cli_session_id':same_prefix}, {'tag':'hub-9'},
                {'set_at':'2001-01-01T00:00:00+00:00'}, {'host':'term'}, {'engine':'claude'}):
    (stage/'roles.json').write_text(json.dumps({'roles':{'hub':dict(refreshed,**updates)}}))
    env['CODEX_THREAD_ID']=updates.get('session',real)
    recover(ok=False)
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':refreshed}}))
env['CODEX_THREAD_ID']=real
# Missing original journal proof cannot be replaced by same-prefix discovery.
journal=next((stage/'coordinator/work').glob('journal-*.md')); saved_journal=journal.read_bytes()
journal.write_text('\n'.join(line for line in saved_journal.decode().splitlines() if 'desktop request '+req+' prepared' not in line)+'\n')
recover(ok=False)
journal.write_text('')
recover(ok=False)
journal.write_bytes(saved_journal+b'\n- 00:00 [hub-2] start: "Other" (22222222-9999-4999-8999-999999999999, sid 22222222) replaced; locks: none; roles updated\n')
recover(ok=False)
journal.write_bytes(saved_journal)
markers={key:env.pop(key) for key in engines.CODEX_APP_ENV if key in env}
recover(ok=False)
env.update(markers)
recover()
repaired=state(stage); restored=roles(stage)
for key in ('request_id','n','at','taken_over','k','client_thread_id','requested','observed','project_id','cwd'):
    assert repaired['pending'].get(key)==original['pending'].get(key),key
assert repaired['chain']==original['chain'] and repaired['pending']['id']==real and repaired['pending']['kind']=='desktop'
assert restored['session']==real and restored['tag']==registered['tag'] and restored['set_at']==registered['set_at']
assert json.loads(hub('desktop-status','--stage','stage-a','--request',req,'--verified').stdout)['verified']
recover(); assert state(stage)==repaired and roles(stage)==restored
hub('takeover','--stage','stage-a','--session','self','--handoff',handoff,cwd=actual)
assert state(stage)==repaired and roles(stage)==restored
print('PASS frozen legacy takeover corruption recovers once from exact full registration proof; stale/prefix/shift/policy/cwd/host conflicts reject without mutation')

# Retained native binding is authoritative even if the current record is changed to a prefix collision.
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':dict(restored,session=same_prefix,cli_session_id=same_prefix)}}))
env['CODEX_THREAD_ID']=same_prefix
recover(ok=False)
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':restored}}))
env['CODEX_THREAD_ID']=real
rollout(real,{'type':'workspace-write','writable_roots':[str(actual)]},model='observed-model',effort='medium')
before=((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes())
hub('takeover','--stage','stage-a','--session','self','--handoff',handoff,cwd=actual,ok=False)
assert ((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes())==before
rollout(real,{'type':'danger-full-access'},model='observed-model',effort='medium')
print('PASS original binding rejects UUID collision and refresh policy mismatch before state/role mutation')

home,stage,handoff=setup('takeover-first'); prepare(handoff,'--desktop-worktree'); req=state(stage)['pending']['request_id']; request(req)
env['CODEX_THREAD_ID']=real; takeover(handoff,req,cwd=actual)
env['CODEX_THREAD_ID']=old; bind(req,'--thread-id',real)
assert state(stage)['pending']['taken_over'] and state(stage)['chain']==1
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':{'session':other,'cli_session_id':other,'tag':'hub-9','kind':'cli'}}}))
bind(req,'--thread-id',real,ok=False); env['CODEX_THREAD_ID']=real; takeover(handoff,req,ok=False,cwd=actual)
assert roles(stage)['session']==other
print('PASS takeover-before-bind race, late confirmation and repeats preserve chain; later hubs cannot be overwritten')

# Parallel prepares reserve one request. Parallel late bind and takeover converge on the same actual UUID.
home,stage,handoff=setup('parallel')
cmd=[str(root/'bin/hub'),'succeed','--stage','stage-a','--handoff',str(handoff),'--force','--desktop-worktree']
procs=[subprocess.Popen(cmd,env=env,cwd=repo,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)]
for proc in procs: proc.communicate(timeout=10)
assert sorted(p.returncode for p in procs)==[0,1] and state(stage)['chain']==1
req=state(stage)['pending']['request_id']; request(req)
successor_env=dict(env,CODEX_THREAD_ID=real)
commands=[([str(root/'bin/hub'),'desktop-bind','--stage','stage-a','--request',req,'--thread-id',real],env,repo),
          ([str(root/'bin/hub'),'takeover','--stage','stage-a','--session','self','--auto-handoff','--handoff',str(handoff),'--desktop-request',req],successor_env,actual)]
procs=[subprocess.Popen(cmd,env=e,cwd=c,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for cmd,e,c in commands]
for proc in procs:
    out,err=proc.communicate(timeout=10)
    assert proc.returncode==0,(out,err)
assert state(stage)['chain']==1 and state(stage)['pending']['taken_over'] and roles(stage)['session']==real
print('PASS concurrent prepares and bind/takeover reserve/migrate once under the state lock')

# Force the TOCTOU seam: CLI sees no pending request, then desktop reserves another number before CLI locks.
home,stage,handoff=setup('cli-desktop-race')
(home/'config.json').write_text(json.dumps({opt_in:True}))  # Test the later reservation fence after valid owner opt-in.
cli_handoff=stage/'HANDOFF-hub-cli.md'
cli_handoff.write_text('# Handoff "Hub stage-a #1" → "Hub stage-a #7" — stage-a\n')
original_env=dict(os.environ); os.environ.clear(); os.environ.update(env)
original_lock,original_load,original_successor=ap.state_lock,ap.load_state,ap.CodexSuccessor
empty_reads=[]; inserted=[]; launch_attempts=[]
def observed_load(name):
    data=original_load(name)
    if not inserted:
        assert data['pending'] is None
        empty_reads.append(name)
    return data
@contextlib.contextmanager
def racing_lock(name):
    if not inserted:
        assert empty_reads, 'CLI did not execute the earlier empty precheck'
        prepare(handoff)  # Actual desktop prepare command uses its own process and the real state mutex.
        desktop=state(stage)['pending']
        request(desktop['request_id'])
        inserted.append((stage/'auto-handoff.json').read_bytes())
        assert state(stage)['pending']['n']==2 and state(stage)['chain']==1
    with original_lock(name):
        yield
class ForbiddenSuccessor:
    def __init__(self,*args,**kwargs):
        launch_attempts.append('CLI successor constructed')
        raise ap.hc.Failure('CLI launcher reached after desktop insertion')
ap.load_state,ap.state_lock,ap.CodexSuccessor=observed_load,racing_lock,ForbiddenSuccessor
try:
    with contextlib.redirect_stdout(io.StringIO()):
        try: ap.succeed('stage-a',1,cli_handoff,None,None,repo,engine='codex',surface='cli',succ=7)
        except ap.hc.Failure: pass
        else: raise AssertionError('concurrent desktop request did not block CLI successor')
    assert empty_reads and inserted
    assert (stage/'auto-handoff.json').read_bytes()==inserted[0], 'CLI changed reserved desktop state/chain'
    assert state(stage)['chain']==1 and not launch_attempts and not (stage/'agents').exists()
finally:
    ap.load_state,ap.state_lock,ap.CodexSuccessor=original_load,original_lock,original_successor
    os.environ.clear();os.environ.update(original_env)
print('PASS CLI empty precheck then different-number Desktop insertion retains exact state/chain and never launches')

# A completed desktop takeover or a later manual owner also wins after CLI's earlier caller/precheck.
for owner_change in ('desktop-taken-over','manual-later-hub'):
    home,stage,handoff=setup(owner_change)
    (home/'config.json').write_text(json.dumps({opt_in:True}))
    cli_handoff=stage/'HANDOFF-hub-cli.md'
    cli_handoff.write_text('# Handoff "Hub stage-a #1" → "Hub stage-a #7" — stage-a\n')
    original_env=dict(os.environ);os.environ.clear();os.environ.update(env)
    original_lock,original_load,original_successor=ap.state_lock,ap.load_state,ap.CodexSuccessor
    empty_reads=[];inserted=[];launch_attempts=[]
    @contextlib.contextmanager
    def owner_changed_lock(name):
        if not inserted:
            assert empty_reads, 'CLI did not execute the earlier empty precheck'
            prepare(handoff); req=state(stage)['pending']['request_id']; request(req)
            env['CODEX_THREAD_ID']=real
            rollout(real,{'type':'danger-full-access'})
            takeover(handoff,req,cwd=repo)
            assert state(stage)['pending']['taken_over'] and roles(stage)['session']==real
            if owner_change=='manual-later-hub':
                env['CODEX_THREAD_ID']=other
                hub('takeover','--stage','stage-a','--session','self','--n','9','--handoff',handoff,cwd=actual)
                assert roles(stage)['session']==other and state(stage)['pending'] is None
            inserted.append(((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes()))
        with original_lock(name):
            yield
    ap.load_state,ap.state_lock,ap.CodexSuccessor=observed_load,owner_changed_lock,ForbiddenSuccessor
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            try: ap.succeed('stage-a',1,cli_handoff,None,None,repo,engine='codex',surface='cli',succ=7)
            except ap.hc.Failure: pass
            else: raise AssertionError('later registered owner did not block stale CLI successor')
        assert ((stage/'auto-handoff.json').read_bytes(),(stage/'roles.json').read_bytes())==inserted[0]
        assert not launch_attempts and not (stage/'agents').exists()
    finally:
        ap.load_state,ap.state_lock,ap.CodexSuccessor=original_load,original_lock,original_successor
        os.environ.clear();os.environ.update(original_env)
print('PASS completed Desktop proof and later manual owner survive stale CLI reservation without mutation/spawn')

home,stage,handoff=setup('observed-restricted'); prepare(handoff,'--desktop-worktree'); req=state(stage)['pending']['request_id']; request(req)
env['CODEX_THREAD_ID']=real
rollout(real,{'type':'workspace-write','writable_roots':[str(home)],'network_access':False})
takeover(handoff,req,cwd=actual)
p=state(stage)['pending']
assert p['requested']['sandbox_policy']['type']=='danger-full-access'
assert p['observed']['sandbox_policy']['type']=='workspace-write'
assert json.loads(hub('desktop-status','--stage','stage-a','--request',req,'--verified').stdout)['verified']
rollout(real,{'type':'danger-full-access'},model='observed-model',effort='medium')
print('PASS explicit writable stage root permits actual workspace policy without claiming requested Full Access')

home,stage,handoff=setup('retry'); prepare(handoff); req=state(stage)['pending']['request_id']; request(req)
(home/'config.json').write_text(json.dumps({opt_in:True}))  # Opt-in cannot convert an already reserved native request.
hub('desktop-fail','--stage','stage-a','--request',req,'--why','unknown result')
prepare(handoff,'--again'); assert state(stage)['pending']['phase']=='uncertain'
before=(stage/'auto-handoff.json').read_bytes()
for flag in ('--fallback','--surface cli','--headless'):
    r=hub('succeed','--stage','stage-a','--handoff',handoff,'--force',*shlex.split(flag),ok=False)
    assert (stage/'auto-handoff.json').read_bytes()==before and roles(stage)['session']==old
assert not (stage/'agents').exists()
assert json.loads(request(req).stdout)['already_dispatched']
hub('desktop-fail','--stage','stage-a','--request',req,'--why','create API rejected before creating','--no-thread-created')
prepare(handoff,'--again'); assert state(stage)['pending']['phase']=='prepared'
assert roles(stage)['session']==old and not (stage/'agents').exists()
before=(stage/'auto-handoff.json').read_bytes()
for flags in (['--fallback'],['--surface','cli']):
    hub('succeed','--stage','stage-a','--handoff',handoff,'--force',*flags,ok=False)
    assert (stage/'auto-handoff.json').read_bytes()==before and roles(stage)['session']==old
assert state(stage)['pending']['request_id']==req and state(stage)['chain']==1
assert not json.loads(request(req).stdout)['already_dispatched']
print('PASS uncertain launch never duplicates; confirmed no-create failure retries same reservation and chain')

home,stage,handoff=setup('explicit-worktree'); prepare(handoff,'--desktop-worktree')
req=state(stage)['pending']['request_id']
assert json.loads(request(req).stdout)['create_thread']['target']['environment']=={'type':'worktree'}
print('PASS explicitly requested desktop worktree omits startingState and uses project default branch')

home,stage,handoff=setup('branch'); prepare(handoff,'--surface','desktop','--branch','main')
req=state(stage)['pending']['request_id']
assert json.loads(request(req).stdout)['create_thread']['target']['environment']['startingState']=={'type':'branch','branchName':'main'}
home,stage,handoff=setup('missing-branch'); hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop','--branch','missing',ok=False)
assert not (stage/'auto-handoff.json').exists()
home,stage,handoff=setup('dry'); prepare(handoff,'--dry-run')
assert not (stage/'auto-handoff.json').exists() and not (stage/'coordinator/work/hub-2-takeover-brief.md').exists()
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--surface','desktop','--headless',ok=False)
hub('succeed','--stage','stage-a','--handoff',handoff,'--force','--engine','claude','--surface','desktop',ok=False)
print('PASS explicit existing branch validated; missing branch and dry run create no reservation')

# Detection and child-env controls exercise both direct worker spawn and autopilot stripping.
saved=dict(os.environ); os.environ.clear(); os.environ.update(env)
assert engines.codex_desktop()
os.environ['AGENT_ROLE']='worker'; assert not engines.codex_desktop(); os.environ.pop('AGENT_ROLE')
os.environ.pop('CODEX_APP_TOOLS_PIPE_PATH'); os.environ.pop('CODEX_INTERNAL_ORIGINATOR_OVERRIDE')
assert not engines.codex_desktop()  # CODEX_THREAD_ID alone is a real console control.
os.environ.update(CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',CODEX_APP_TOOLS_PIPE_PATH='/never-connect')
assert not any(k in ap.child_env() for k in engines.CODEX_APP_ENV)
ag=ap._agent_module(); assert not any(k in ag.child_env('stage-a','worker') for k in engines.CODEX_APP_ENV)
os.environ.clear(); os.environ.update(saved)
print('PASS console/thread-id-only and inherited-worker controls; detached child environments strip app markers')
PY
