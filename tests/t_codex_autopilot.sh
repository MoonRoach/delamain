#!/usr/bin/env bash
# Codex successors use a detached fake CLI. No real model requests or owner state.
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
import contextlib, io, json, os, pathlib, subprocess, sys, time
root, tmp = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root / 'bin'))
import autopilot as ap
import hubcore as hc
fake = tmp / 'codex'
fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
with open(os.environ['FAKE_CODEX_LOG'],'a') as f: f.write(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'env':{k:os.environ.get(k) for k in ['CODEX_THREAD_ID','CLAUDE_CODE_SESSION_ID','AGENT_SESSION_ID','CODEX_INTERNAL_ORIGINATOR_OVERRIDE','CODEX_APP_TOOLS_PIPE_PATH']}})+'\\n')
print(json.dumps({'type':'thread.started','thread_id':'22222222-2222-4222-8222-222222222222'}),flush=True)
print(json.dumps({'type':'turn.started'}),flush=True)
time.sleep(60)
''')
fake.chmod(0o755)
for key in tuple(os.environ):
    if key.startswith(('AGENT_HUB_', 'HUB_', 'CODEX_', 'CLAUDE_')) or key in ('AGENT_ROLE', 'AGENT_SESSION_ID'):
        os.environ.pop(key, None)
os.environ.update(CODEX_BIN=str(fake), CLAUDE_BIN=str(tmp/'missing-claude'), CODEX_HOME=str(tmp/'codex-home'),
                  AGENT_HUB_ENGINE='codex', AGENT_HUB_TZ='UTC', FAKE_CODEX_LOG=str(tmp/'calls'),
                  CODEX_THREAD_ID='11111111-1111-4111-8111-111111111111')
(tmp/'codex-home/sessions').mkdir(parents=True)
rollout = tmp/'codex-home/sessions/rollout-test.jsonl'
rollout.write_text(json.dumps({'type':'session_meta','payload':{'id':os.environ['CODEX_THREAD_ID']}})+'\n'+
                   json.dumps({'type':'turn_context','payload':{'model':'fixture-codex-model','effort':'xhigh',
                       'approval_policy':'on-request','sandbox_policy':{'type':'workspace-write','network_access':False,
                       'writable_roots':[str(tmp/'allowed')],'exclude_tmpdir_env_var':True,'exclude_slash_tmp':True}}})+'\n')

def setup(name):
    home = tmp/name
    os.environ['AGENT_HUB_HOME'] = str(home)
    stage = home/'stage-a'
    stage.mkdir(parents=True)
    (stage/'roles.json').write_text(json.dumps({'roles':{'hub':{'session':os.environ['CODEX_THREAD_ID'],
         'cli_session_id':os.environ['CODEX_THREAD_ID'], 'tag':'hub-1', 'kind':'cli'}}}))
    handoff = stage/'HANDOFF.md'; handoff.write_text('# Handoff\n## 0. First steps\nTake over\n')
    cwd = home/'work'; cwd.mkdir()
    return home, handoff, cwd

def state(home): return json.loads((home/'stage-a/auto-handoff.json').read_text())
def calls(): return [json.loads(x) for x in (tmp/'calls').read_text().splitlines()] if (tmp/'calls').exists() else []
def succeed(handoff, cwd, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = ap.succeed('stage-a',1,handoff,None,None,cwd,**kwargs)
    return rc, out.getvalue()
def stop(role="hub-2"):
    subprocess.run([str(root/'bin/agent'),'stop',role,'--stage','stage-a'], stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

home,handoff,cwd = setup('inherit')
# This fixture deliberately chooses CLI from Desktop to verify detached launch and env stripping.
(home/'config.json').write_text(json.dumps({'AGENT_HUB_DESKTOP_CLI_HANDOFF':True}))
os.environ.update(CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',CODEX_APP_TOOLS_PIPE_PATH='/never-connect')
try:
    rc,out=succeed(handoff,cwd,surface='cli')
    assert rc == 0 and 'Codex shell execution harness' in out
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    assert meta['engine']=='codex' and meta['model']=='fixture-codex-model' and meta['sandbox']=='workspace-write'
    assert meta['effort']=='xhigh' and state(home)['pending']['effort']=='xhigh'
    assert meta['session_id']=='22222222-2222-4222-8222-222222222222'
    original_sid=os.environ['CODEX_THREAD_ID']
    os.environ.update(CODEX_THREAD_ID=meta['session_id'],AGENT_ROLE='hub-2',HUB_STAGE='stage-a')
    assert ap.codex_context()['effort']=='xhigh'  # No worker rollout exists: use its actual launch metadata.
    os.environ['CODEX_THREAD_ID']=original_sid
    os.environ.pop('AGENT_ROLE');os.environ.pop('HUB_STAGE')

    argv=calls()[-1]['argv']
    assert 'sandbox_mode="workspace-write"' in argv and 'approval_policy="never"' in argv
    assert 'model_reasoning_effort="xhigh"' in argv
    assert 'sandbox_workspace_write.network_access=false' in argv
    assert 'sandbox_workspace_write.exclude_tmpdir_env_var=true' in argv
    assert 'sandbox_workspace_write.exclude_slash_tmp=true' in argv
    assert meta['sandbox_policy']['writable_roots']==[str(tmp/'allowed')]
    assert '--dangerously-bypass-approvals-and-sandbox' not in argv
    assert calls()[-1]['env']['CODEX_THREAD_ID'] is None
    assert calls()[-1]['env']['CODEX_INTERNAL_ORIGINATOR_OVERRIDE'] is None
    assert calls()[-1]['env']['CODEX_APP_TOOLS_PIPE_PATH'] is None
    brief=(home/'stage-a/coordinator/work/hub-2-takeover-brief.md').read_text()
    assert 'finite queue snapshot' in brief and 'Terminal follow-through' in brief and '--for 9m' not in brief
    for phrase in ('WARN is a soft advisory: acknowledge the owner\nand transfer at the next quiet point, after any already-active atomic merge, lock or message operation finishes.\nThe durable handoff obligation survives owner prompts, chain resets and missing/decreased usage; WARN does not\nclose tools before the first actual BLOCK. BLOCK is the hard barrier for ordinary recognized work; once reached,\nit survives missing/decreased usage until an explicit threshold-policy or registration reset.', 'A checkpoint alone is not completion',
                   'Do not compact to extend the shift', 'only the handoff procedure may continue',
                   'journal the settings refusal and end the shift', 'genuine data/resource/safety gates and human stop'):
        assert phrase in brief, (phrase, brief)
    assert 'available compaction' not in brief and 'Context warnings are advisory' not in brief
    os.environ.pop('CODEX_INTERNAL_ORIGINATOR_OVERRIDE');os.environ.pop('CODEX_APP_TOOLS_PIPE_PATH')
    assert state(home)['pending']['engine']=='codex' and state(home)['chain']==1
    assert 'becomes never' in out and 'Remote Control' not in (home/'stage-a/coordinator/work/hub-2-takeover-brief.md').read_text()
    before=len(calls())
    try: succeed(handoff,cwd)
    except hc.Failure: pass
    else: raise AssertionError('duplicate successor accepted')
    assert len(calls())==before
    ap.on_takeover('stage-a',2,True)
    assert state(home)['chain']==1 and state(home)['pending']['taken_over']
    ap._record('stage-a',2,dict(state(home)['pending'],taken_over='preserved'))
    assert state(home)['pending']['taken_over']!='preserved'
    print('PASS Codex actual detached lifecycle, rollout inheritance, sandbox preservation, identity and idempotence')
finally: stop()

# A dead successor can restart with its recorded policy after rollout discovery is lost.
saved=state(home);saved['pending'].pop('taken_over',None)
(home/'stage-a/auto-handoff.json').write_text(json.dumps(saved))
ap.codex_rollouts.INDEX.records={};ap.codex_rollouts.INDEX.checked=time.monotonic()
try:
    rc,out=succeed(handoff,cwd,again=True)
    assert rc==0 and state(home)['chain']==1
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    assert meta['sandbox']=='workspace-write' and meta['model']=='fixture-codex-model'
    assert meta['effort']=='xhigh' and state(home)['pending']['effort']=='xhigh'
    assert 'model_reasoning_effort="xhigh"' in calls()[-1]['argv']
    assert meta['sandbox_policy']['network_access'] is False
    assert meta['sandbox_policy']['exclude_slash_tmp'] is True
    assert '--dangerously-bypass-approvals-and-sandbox' not in calls()[-1]['argv']
    print('PASS dead successor restart preserves recorded model and restricted sandbox')
finally: stop()

# AGENT_HUB_REASON_POLICY=refuse must not stop the hand-over chain: the successor keeps the hub's model and effort, `hub succeed` says so
home,handoff,cwd = setup('reason')
ap.codex_rollouts.INDEX.records={}; ap.codex_rollouts.INDEX.checked=None  # discover the hub's rollout afresh
os.environ.update(AGENT_HUB_REASON_POLICY='refuse', AGENT_HUB_EFFORT_DEFAULTS='{"*": "low"}')
try:
    rc,out=succeed(handoff,cwd)
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    assert rc==0 and meta['effort']=='xhigh' and 'hub successor' in meta['reason'], (rc,out,meta)
    print('PASS Codex successor above the default effort passes the reason policy')
finally:
    stop(); os.environ.pop('AGENT_HUB_REASON_POLICY'); os.environ.pop('AGENT_HUB_EFFORT_DEFAULTS')
# Restore discovery for dry-run controls.
ap.codex_rollouts.INDEX.checked=None

# --replace of a Codex successor that already took over: the registered hub is that successor (hub-2), which must not
# make the new start refuse after the old one was stopped
home,handoff,cwd=setup('replace')
try:
    rc,out=succeed(handoff,cwd)
    assert rc==0
    first_pid=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())['pid']
    ap.on_takeover('stage-a',2,True)
    (home/'stage-a/roles.json').write_text(json.dumps({'roles':{'hub':{'session':'22222222-2222-4222-8222-222222222222',
         'cli_session_id':'22222222-2222-4222-8222-222222222222','tag':'hub-2','kind':'cli'}}}))
    before=len(calls())
    rc,out=succeed(handoff,cwd,replace=True,force=True,succ=2)
    assert rc==0, out
    assert len(calls())==before+1, 'the replacement was not started'
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    assert meta['pid']!=first_pid and state(home)['pending']['n']==2 and state(home)['chain']==1
    assert not state(home)['pending'].get('taken_over')
    print('PASS Codex --replace stops the successor that took over and starts a new one')
finally: stop()

# `hub succeed --effort` overrides the inherited Codex effort; an unknown one is refused before anything starts.
home,handoff,cwd=setup('effort-override')
try:
    rc,out=succeed(handoff,cwd,effort_arg='medium')
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    assert rc==0 and meta['effort']=='medium' and state(home)['pending']['effort']=='medium'
    assert 'model_reasoning_effort="medium"' in calls()[-1]['argv']
    print('PASS Codex --effort overrides the inherited effort')
finally: stop()
home,handoff,cwd=setup('effort-bad')
before=len(calls())
try: succeed(handoff,cwd,effort_arg='turbo')
except hc.UsageError: pass
else: raise AssertionError('unknown Codex --effort accepted')
assert len(calls())==before and not (home/'stage-a/auto-handoff.json').exists()
print('PASS Codex unknown --effort refused before reservation')

home,handoff,cwd=setup('dry')
rc,out=succeed(handoff,cwd,dry_run=True)
assert rc==0 and 'exec --json' in out and 'sandbox_mode=' in out and 'fixture-codex-model' in out
assert '--engine codex' in out and '--worktree' not in out
assert str(home/'stage-a/coordinator/work/hub-2-takeover-brief.md') in out
assert not (home/'stage-a/auto-handoff.json').exists()
assert not (home/'stage-a/coordinator/work/hub-2-takeover-brief.md').exists()
print('PASS representative dry run writes no reservation or brief')

ap.codex_rollouts.INDEX.records={};ap.codex_rollouts.INDEX.checked=time.monotonic()
home,handoff,cwd=setup('default')
(home/'config.json').write_text(json.dumps({'AGENT_HUB_DESKTOP_CLI_HANDOFF':True}))
os.environ.update(CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop',CODEX_APP_TOOLS_PIPE_PATH='/never-connect')
try:
    before=len(calls())
    try: succeed(handoff,cwd,headless=True)
    except hc.UsageError as e: assert 'model is unknown' in str(e)
    else: raise AssertionError('unknown current settings silently used CLI defaults')
    assert len(calls())==before and not (home/'stage-a/auto-handoff.json').exists()
    print('PASS missing current Codex settings refuse before reservation or launch')
finally:
    os.environ.pop('CODEX_INTERNAL_ORIGINATOR_OVERRIDE');os.environ.pop('CODEX_APP_TOOLS_PIPE_PATH')
    ap.codex_rollouts.INDEX.checked=None

# In Git, successors leave the predecessor's disposable worktree and start from main HEAD in a fresh one.
home,handoff,cwd=setup('worktree')
repo=home/'repo';repo.mkdir()
def git(*args):
    return subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True,text=True)
git('init','-q','-b','main')
(repo/'tracked.txt').write_text('main checkout\n');git('add','tracked.txt')
git('-c','user.email=test@example.invalid','-c','user.name=Test','commit','-qm','init')
predecessor=repo/'.claude/worktrees/previous'
git('worktree','add','-q','-b','predecessor',str(predecessor))
(predecessor/'tracked.txt').write_text('predecessor uncommitted\n')
(repo/'.worktrees/stage-a-hub-2').mkdir(parents=True)
git('branch','stage-a-hub-2-2')
before_calls=len(calls());before_refs=git('show-ref').stdout
rc,dry=succeed(handoff,predecessor,dry_run=True)
assert rc==0 and '--cwd '+str(repo.resolve()) in dry and '--worktree stage-a-hub-2-3' in dry
assert '--engine codex' in dry and str(home/'stage-a/coordinator/work/hub-2-takeover-brief.md') in dry
assert len(calls())==before_calls and git('show-ref').stdout==before_refs
assert not (repo/'.worktrees/stage-a-hub-2-3').exists()
assert not (home/'stage-a/auto-handoff.json').exists()
assert not (home/'stage-a/coordinator/work/hub-2-takeover-brief.md').exists()
print('PASS Codex dry run names actual spawn/root/fresh worktree without creating a branch, brief or process')
try:
    rc,out=succeed(handoff,predecessor)
    assert rc==0
    meta=json.loads((home/'stage-a/agents/hub-2/meta.json').read_text())
    successor=repo/'.worktrees/stage-a-hub-2-3'
    assert pathlib.Path(meta['cwd']).resolve()==successor.resolve()
    assert pathlib.Path(calls()[-1]['cwd']).resolve()==successor.resolve()
    assert state(home)['pending']['cwd']==str(repo.resolve())
    assert state(home)['pending']['worktree']==str(successor.resolve())
    assert (successor/'tracked.txt').read_text()=='main checkout\n'
    assert (predecessor/'tracked.txt').read_text()=='predecessor uncommitted\n'
    assert 'in the new worktree' in out and str(repo.resolve()) in out
    print('PASS Codex successor uses fresh worktree from main HEAD, skips collisions and preserves predecessor')
finally: stop()

# Explicit successor numbering also works for legacy unnumbered hub tags.
home,handoff,cwd=setup('legacy')
roles=json.loads((home/'stage-a/roles.json').read_text());roles['roles']['hub']['tag']='hub'
(home/'stage-a/roles.json').write_text(json.dumps(roles))
try:
    with contextlib.redirect_stdout(io.StringIO()) as out:
        rc=ap.succeed('stage-a',25,handoff,None,None,cwd,engine='codex',succ=26,notes=('legacy numbering',))
    assert rc==0 and state(home)['pending']['n']==26
    assert ap.pending_number('stage-a',handoff)==26
    assert 'Hub stage-a #26' in out.getvalue() and 'legacy numbering' in out.getvalue()
    assert (home/'stage-a/agents/hub-26/meta.json').is_file()
    ap.on_takeover('stage-a',26,True)
    assert state(home)['chain']==1 and state(home)['pending']['taken_over']
    print('PASS Codex preserves legacy hub tag, explicit successor number, numbering note and takeover chain')
finally: stop('hub-26')

home,handoff,cwd=setup('limit')
os.environ['AGENT_HUB_AUTO_HANDOFF_CHAIN']='0'
before=len(calls())
rc,out=succeed(handoff,cwd)
assert rc==3 and len(calls())==before
os.environ.pop('AGENT_HUB_AUTO_HANDOFF_CHAIN')
print('PASS chain limit starts no Codex process')
for bad in ({'sandbox_policy':{'type':'unknown-restricted-policy'}}, {'sandbox_policy':{}}, {'model':'fixture-model'}):
    try: ap.codex_policy(None, bad, cwd)
    except hc.UsageError: pass
    else: raise AssertionError('unknown/missing active sandbox silently widened')
    assert ap.codex_policy('workspace-write',bad,cwd)==('workspace-write','never')
try: ap.codex_policy(None,{},cwd)
except hc.UsageError as e: assert 'unknown' in str(e)
else: raise AssertionError('missing discovery guessed Full Access')
print('PASS unknown or missing active sandbox fails; explicit override remains supported')
assert 'detached Codex successor' in ap.instruction('stage-a', 'opus', 'default', str(cwd), False, '10k')
assert '--engine codex' in ap.instruction('stage-a', 'opus', 'default', str(cwd), False, '10k')
soft = ap.instruction('stage-a', 'opus', 'default', str(cwd), False, '10k')
assert 'Hand over now' in soft and 'already-active atomic operation' in soft
assert 'next quiet point' not in soft and 'not a mandatory STOP' not in soft
assert 'Do not compact' in soft and 'available compaction' not in soft
hard = ap.instruction('stage-a', 'opus', 'default', str(cwd), True, '10k')
assert 'Hand over now' in hard and 'You may continue' not in hard
# Root restores this hook to upstream; CORE_CONTEXT_HOOK permits that exact
# integration source to be checked in an author's independently owned worktree.
hook = pathlib.Path(os.environ.get('CORE_CONTEXT_HOOK', str(root/'hooks/context_budget.py')))
home,handoff,cwd=setup('hard-boundary')
os.environ['AGENT_HUB_AUTO_HANDOFF']='on'
transcript = tmp/'hard-context.jsonl'
def hook_call(tool, tool_input, tokens=550000, auto=True, claude=False):
    transcript.write_text(json.dumps({'type':'assistant','message':{'model':'claude-opus',
        'usage':{'input_tokens':tokens}}})+'\n')
    data = dict(hook_event_name='PreToolUse' if tool else 'PostToolUse', session_id=os.environ['CODEX_THREAD_ID'],
                transcript_path=str(transcript), cwd=str(cwd), tool_name=tool, tool_input=tool_input)
    env = dict(os.environ, PLUGIN_ROOT=str(root), PYTHONPATH=str(root/'hooks'),
               AGENT_HUB_AUTO_HANDOFF='on' if auto else 'off', AGENT_HUB_STATE_DIR=str(tmp/('state-'+str(tokens))))
    if claude:
        env.pop('CODEX_THREAD_ID', None)
        (cwd/'.agent-hub').mkdir(exist_ok=True)
        (cwd/'.agent-hub/config.json').write_text(json.dumps({'AGENT_HUB_ENGINE':'codex'}))
        env.pop('AGENT_HUB_ENGINE', None)
    r = subprocess.run([sys.executable, str(hook)], input=json.dumps(data), env=env, text=True, capture_output=True)
    assert r.returncode == 0, (r.returncode,r.stderr)
    return json.loads(r.stdout)['hookSpecificOutput'] if r.stdout.strip() else None
assert hook_call('Bash', {'command':'git status'})['permissionDecision']=='deny'
for tool, args in (('Bash', {'command':str(root/'bin/hub')+' handoff --stage stage-a'}),
                   ('Bash', {'command':str(root/'bin/hub')+' succeed --stage stage-a --handoff '+str(handoff)}),
                   ('Bash', {'command':str(root/'bin/jlog')+' "BLOCKED saved handoff settings unavailable"'}),
                   ('Write', {'file_path':str(handoff.parent/'HANDOFF-recovery.md')})):
    assert hook_call(tool,args) is None, (tool,args)
# Missing metadata refuses without reserving/spawning, with allowed journal/stop instructions.
original_context=ap.codex_context
ap.codex_context=lambda: {}
before=len(calls())
try: succeed(handoff,cwd)
except hc.UsageError as e:
    assert 'Required recovery' in str(e) and str(handoff) in str(e)
    assert 'journal BLOCKED' in str(e) and 'end this shift' in str(e) and 'Do not compact' in str(e)
else: raise AssertionError('missing rollout became successful transfer')
finally: ap.codex_context=original_context
assert len(calls())==before and not (home/'stage-a/auto-handoff.json').exists()
warning = hook_call(None, {}, tokens=320000, auto=False, claude=True)['additionalContext']
assert 'handoff threshold' in warning and 'write a handoff' in warning
assert 'advisory' not in warning and 'available compaction' not in warning
os.environ.pop('AGENT_HUB_AUTO_HANDOFF')
print('PASS required no-compaction handoff, actual hardgate allowed safe failure exit and Claude 320k/project-Codex warning')

home,handoff,cwd=setup('unknown-nested')
original_context=ap.codex_context
ap.codex_context=lambda: {'model':'fixture-codex-model','effort':'high',
                          'sandbox_policy':{'type':'workspace-write','unknown_exclusions':['/restricted']}}
before=len(calls())
try: succeed(handoff,cwd)
except hc.UsageError as e: assert 'unsupported fields' in str(e)
else: raise AssertionError('unsupported nested restriction accepted')
assert len(calls())==before and not (home/'stage-a/auto-handoff.json').exists()
ap.codex_context=original_context
print('PASS unsupported nested restriction fails before reservation or subprocess')

home,handoff,cwd=setup('unknown-effort')
ap.codex_context=lambda: {'effort':'invalid-effort','sandbox_policy':{'type':'read-only'}}
before=len(calls())
try: succeed(handoff,cwd)
except hc.UsageError as e: assert 'unsupported inherited Codex effort' in str(e)
else: raise AssertionError('invalid effort accepted')
assert len(calls())==before and not (home/'stage-a/auto-handoff.json').exists()
ap.codex_context=original_context
print('PASS unsupported inherited effort fails before reservation or subprocess')

home,handoff,cwd=setup('taken-over')
real=ap.CodexSuccessor
class Changed(real):
    def __init__(self,*a,**kw):
        super().__init__(*a,**kw)
        roles=json.loads((home/'stage-a/roles.json').read_text());roles['roles']['hub']['tag']='hub-9'
        (home/'stage-a/roles.json').write_text(json.dumps(roles))
ap.CodexSuccessor=Changed
before=len(calls())
try: succeed(handoff,cwd)
except hc.Failure as e: assert 'no Codex process started' in str(e)
else: raise AssertionError('stale hub started a successor')
assert len(calls())==before and state(home)['chain']==0
print('PASS completed takeover prevents extra successor and releases reservation')
PY
