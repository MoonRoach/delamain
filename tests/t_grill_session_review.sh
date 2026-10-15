#!/bin/bash
# Review regressions: portable commands, launch identity, stale cleanup and hub marker lifecycle.
. "$(dirname "$0")/lib.sh"
unset AGENT_ROLE PLUGIN_ROOT CLAUDE_PLUGIN_ROOT AGENT_HUB_STATE_DIR
python3 - "$B" "$HOOKS" <<'PY'
import json, os, pathlib, re, shlex, subprocess, sys, tempfile, time

B, hooks = map(pathlib.Path, sys.argv[1:])
HUB = '11111111-1111-4111-8111-111111111111'
CHILD = '22222222-2222-4222-8222-222222222222'
OTHER = '33333333-3333-4333-8333-333333333333'
failures = []

def check(ok, label, detail=''):
    print(('PASS ' if ok else 'FAIL ') + label + (': ' + str(detail) if not ok else ''), flush=True)
    if not ok:
        failures.append(label)

class Fixture:
    def __init__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='grill review '))
        self.home = self.root / 'hub home'; self.home.mkdir()
        self.cwd = self.root / 'project space'; self.cwd.mkdir()
        self.env = dict(os.environ, AGENT_HUB_HOME=str(self.home),
                        AGENT_HUB_STATE_DIR=str(self.root/'state'),
                        CLAUDE_SESSIONS_DIR=str(self.root/'sessions'),
                        AGENT_HUB_AUTO_HANDOFF='on', AGENT_HUB_GRILL_LINK_WAIT_S='0')
        self.run('roles', '--stage', 'stage-a', 'set', 'hub', HUB, '--kind', 'cli', '--tag', 'hub')
        self.qid = self.run('ask', 'add', '--stage', 'stage-a', '--print-id', 'Ship on Friday?').stdout.strip()

    def run(self, command, *args, sid=HUB, env=None):
        e = dict(self.env, CLAUDE_CODE_SESSION_ID=sid)
        e.pop('CODEX_THREAD_ID', None)
        if env: e.update(env)
        return subprocess.run([str(B/command), *args], cwd=self.cwd, env=e, text=True, capture_output=True)

    def grill(self, *args, **kwargs):
        return self.run('hub', 'grill', *args, '--stage', 'stage-a', **kwargs)

    def open(self, host='desktop', **kwargs):
        p = self.grill('--host', host, **kwargs)
        check(p.returncode == 0, 'launch '+host, p.stderr)
        state = json.loads((self.home/'stage-a/grill.json').read_text())
        return state['pending']['launch'], p

    def role(self):
        p = self.home/'stage-a/roles.json'
        return json.loads(p.read_text())['roles'].get('grill')

    def journal(self):
        return '\n'.join(p.read_text() for p in self.home.glob('stage-a/coordinator/work/journal-*.md'))

    def mark(self, sid=HUB):
        return pathlib.Path(self.env['AGENT_HUB_STATE_DIR'])/'grilling'/f'{sid}.json'

    def prompt(self, sid=HUB, tokens=1000):
        tr = self.root/'usage.jsonl'
        tr.write_text(json.dumps({'type':'assistant','message':{'model':'claude-opus-5-5',
                                      'usage':{'input_tokens':tokens}}})+'\n')
        data = {'hook_event_name':'UserPromptSubmit','session_id':sid,'cwd':str(self.cwd),
                'transcript_path':str(tr),'prompt':'$grilling the release','permission_mode':'acceptEdits'}
        return subprocess.run([sys.executable,str(hooks/'context_budget.py')], input=json.dumps(data),
                              env=self.env, text=True, capture_output=True)

# M1: commands in every launch surface carry the absolute home, including paths with spaces.
for host in ('desktop', 'codex-app', 'manual', 'bg'):
    f = Fixture()
    fake = f.root/'fake claude'
    fake.write_text('#!/usr/bin/env python3\nimport json,sys,time\na=sys.argv[1:]\n'
                    'if a[0]=="agents": print("[]")\n'
                    f'elif a[0]=="--bg": print("backgrounded · {CHILD} · stage-a-grill")\n'
                    'elif a[0]=="logs": print("https://claude.ai/code/session_test")\n')
    fake.chmod(0o755)
    launch, out = f.open(host, env={'CLAUDE_BIN':str(fake)})
    pend = json.loads((f.home/'stage-a/grill.json').read_text())['pending']
    brief = pathlib.Path(pend['brief']).read_text()
    if host in ('desktop','codex-app'):
        key = 'start_session' if host == 'desktop' else 'create_thread'
        prompt = next(json.loads(l)[key]['prompt'] for l in out.stdout.splitlines() if l.startswith('{"'+key+'"'))
    elif host == 'manual':
        prompt = shlex.split(next(l for l in out.stdout.splitlines() if l.startswith('  cd ')))[-1]
    else:
        prompt = out.stdout
    commands = [c for c in re.findall(r'`([^`\n]+)`', brief+'\n'+prompt)
                if re.search(r'(?:^|[ /])(?:hub(?:\x27)? grill|ask(?:\x27)? (?:show|search|close|withdraw|add|decided)|jlog(?:\x27)? --stage)',c)]
    check(len(commands) >= 8, host+': command coverage', commands)
    for c in commands:
        words = shlex.split(c)
        value = words[0].removeprefix('AGENT_HUB_HOME=') if words else ''
        check(bool(words) and words[0].startswith('AGENT_HUB_HOME=') and
              pathlib.Path(value).is_absolute() and pathlib.Path(value).resolve() == f.home.resolve(),
              host+': absolute home in command', c)
    if host == 'desktop':
        # Run the actual generated commands against another valid home; success alone cannot hide misrouting.
        f.grill('bind','--launch',launch,'--session',CHILD)
        wrong = f.root/'other home'; wrong.mkdir()
        foreign = dict(f.env, AGENT_HUB_HOME=str(wrong), CLAUDE_CODE_SESSION_ID=CHILD)
        for needle in (' grill join ', ' close <id> ', ' grill done '):
            command = next(c for c in commands if needle in c)
            command = command.replace('<id>',f.qid)
            command = re.sub(r'<[^>]+>', 'owner answered yes',command)
            p = subprocess.run(command,shell=True,cwd=f.cwd,env=foreign,text=True,capture_output=True)
            check(p.returncode == 0, 'generated '+needle.strip()+' executes from foreign home',p.stderr)
        check('answered' in f.run('ask','show',f.qid).stdout, 'generated ask updated source register')
        check('GRILLED' in f.journal(), 'generated done reported to source journal')
        check(not (wrong/'stage-a').exists(), 'generated commands leave foreign home untouched')

# M2: launcher binding and joining are separate facts; neither fact alone activates a native role.
for order in ('bind-first','join-first'):
    f = Fixture(); launch, _ = f.open()
    if order == 'bind-first':
        p = f.grill('bind','--launch',launch,'--session',CHILD)
        check(p.returncode == 0 and not f.role(), 'bind alone does not activate',p.stderr)
    else:
        p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
        check(p.returncode == 0 and not f.role(), 'join before bind waits successfully',p.stdout+p.stderr)
        check(bool(re.search(r'wait|retry|again',p.stdout+p.stderr,re.I)), 'waiting join instructs retry')
        p = f.grill('bind','--launch',launch,'--session',CHILD)
        check(p.returncode == 0, 'bind after waiting join',p.stderr)
    p = f.grill('join','--launch',launch,'--session','self',sid=OTHER)
    check(p.returncode == 2 and (not f.role() or f.role().get('session') == CHILD), order+': mismatched child cannot activate',p.stderr)
    p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
    check(p.returncode == 0 and (f.role() or {}).get('session') == CHILD, order+': correct child activates',p.stderr)
    p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
    check(p.returncode == 0, order+': correct join is idempotent',p.stderr)

f = Fixture(); launch,_ = f.open('manual')
p = f.grill('join','--launch',launch,'--session',CHILD)
check(p.returncode == 2 and not f.role(), 'explicit other session requires --why',p.stderr)
p = f.grill('join','--launch',launch,'--session',CHILD,'--why','owner repaired launch identity')
check(p.returncode == 0 and (f.role() or {}).get('session') == CHILD, 'admin join with reason',p.stderr)
check('owner repaired launch identity' in f.journal(), 'admin join reason is journaled')

# A manual command still needs a confirmed launcher result; an unrelated caller cannot consume it.
f = Fixture(); launch,_ = f.open('manual')
p = f.grill('join','--launch',launch,'--session','self',sid=OTHER)
state_path = f.home/'stage-a/grill.json'
state = json.loads(state_path.read_text()) if state_path.exists() else {}
check(p.returncode == 0 and not f.role() and state.get('pending',{}).get('launch') == launch,
      'manual: unbound unrelated self waits without consuming launch',p.stdout+p.stderr)
p = f.grill('bind','--launch',launch,'--session',CHILD)
check(p.returncode == 0 and not f.role(), 'manual: bind ignores unrelated early candidate',p.stderr)
p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
check(p.returncode == 0 and (f.role() or {}).get('session') == CHILD,
      'manual: confirmed child activates after unrelated candidate',p.stderr)

# An uncertain background start retains the original hold until confirmed bind + child join.
# The saved marker belongs to one round in one registered hub, never to its successor or a later round.
for order in ('bind-first','join-first'):
    for hold in ('original','new-round','successor'):
        label = 'uncertain '+order+' '+hold
        f = Fixture(); p = f.prompt()
        check(p.returncode == 0 and f.mark().exists(), label+': actual skill prompt marks hub',p.stderr)
        original = json.loads(f.mark().read_text())
        fake = f.root/'fake claude'
        fake.write_text('#!/usr/bin/env python3\nimport sys\na=sys.argv[1:]\n'
                        'if a[0]=="agents": print("[]")\n'
                        'elif a[0]=="--bg": print("launch accepted; identity unavailable")\n')
        fake.chmod(0o755)
        p = f.grill('--host','bg',env={'CLAUDE_BIN':str(fake)})
        state = json.loads((f.home/'stage-a/grill.json').read_text())
        pending = state.get('pending',{}); launch = pending.get('launch','')
        check(p.returncode != 0 and 'printed no session id' in p.stderr and bool(launch) and not f.role(),
              label+': Unsure keeps pending launch',p.stdout+p.stderr)
        check(f.mark().exists() and json.loads(f.mark().read_text()) == original,
              label+': Unsure preserves original marker')
        saved = pending.get('grilling') or {}
        check(all(saved.get(k) == original[k] for k in ('stage','session','since_ts')),
              label+': pending snapshots exact original grilling',saved)
        protected = None
        protected_sid = HUB
        if hold == 'new-round':
            p = f.run('hub','grilling','end','--stage','stage-a','--why','original frontier closed')
            check(p.returncode == 0 and not f.mark().exists(), label+': explicit end clears original',p.stderr)
            p = f.run('hub','grilling','start','--stage','stage-a','--topic','a separate owner decision')
            check(p.returncode == 0 and f.mark().exists(), label+': explicit start creates new round',p.stderr)
            protected = json.loads(f.mark().read_text())
            check(protected['since_ts'] != original['since_ts'], label+': new round has distinct since_ts')
        elif hold == 'successor':
            p = f.run('roles','--stage','stage-a','set','hub',OTHER,'--kind','cli','--tag','hub')
            check(p.returncode == 0, label+': replace registered hub',p.stderr)
            p = f.prompt(OTHER)
            check(p.returncode == 0 and f.mark(OTHER).exists(), label+': skill prompt marks successor',p.stderr)
            protected_sid = OTHER
            protected = json.loads(f.mark(OTHER).read_text())
        if order == 'join-first':
            p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
            state = json.loads((f.home/'stage-a/grill.json').read_text())
            check(p.returncode == 0 and not f.role() and state.get('pending',{}).get('launch') == launch,
                  label+': early join waits without consuming pending',p.stdout+p.stderr)
            check(f.mark(protected_sid).exists(), label+': waiting join preserves hold')
        p = f.grill('bind','--launch',launch,'--session',CHILD,'--why','owner confirmed recovered background identity')
        check(p.returncode == 0, label+': confirmed administrative bind succeeds',p.stderr)
        if order == 'bind-first':
            check(not f.role() and f.mark(protected_sid).exists(), label+': bind alone preserves hold')
            p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
            check(p.returncode == 0, label+': child joins confirmed launch',p.stderr)
        check((f.role() or {}).get('session') == CHILD, label+': correct child is active')
        check('owner confirmed recovered background identity' in f.journal(), label+': recovery reason journaled')
        if hold == 'original':
            check(not f.mark().exists(), label+': activation clears original hub marker')
        else:
            check(f.mark(protected_sid).exists() and json.loads(f.mark(protected_sid).read_text()) == protected,
                  label+': activation preserves protected marker')
        p = f.grill('done','--launch',launch,sid=CHILD)
        check(p.returncode == 0, label+': child reports done',p.stderr)
        if hold == 'original':
            p = f.run('hub','handoff','--stage','stage-a','--n','1','--out',str(f.root/'HANDOFF-recovered.md'))
            check(p.returncode == 0, label+': handoff proceeds after recovery and done',p.stderr)

# Background launch prints a short id; agents supplies the corresponding full sessionId.
f = Fixture(); fake = f.root/'fake claude'; seen = f.root/'started'
fake.write_text('#!/usr/bin/env python3\nimport json,pathlib,sys,time\na=sys.argv[1:]\n'
                f'p=pathlib.Path({str(seen)!r})\n'
                'if a[0]=="agents":\n'
                f' print(json.dumps([{{"kind":"background","id":"bg-1234abcd","sessionId":{CHILD!r},"name":"stage-a-grill","startedAt":int(time.time()*1000)}}] if p.exists() else []))\n'
                'elif a[0]=="--bg": p.touch(); print("backgrounded · bg-1234abcd · stage-a-grill")\n'
                'elif a[0]=="logs": print("https://claude.ai/code/session_test")\n')
fake.chmod(0o755)
launch,_ = f.open('bg',env={'CLAUDE_BIN':str(fake)})
pend = json.loads((f.home/'stage-a/grill.json').read_text())['pending']
check(pend.get('bg_id') == CHILD, 'bg short id resolves to full expected sessionId',pend)
p = f.grill('join','--launch',launch,'--session','self',sid=OTHER)
check(p.returncode == 2 and not f.role(), 'bg wrong identity is rejected',p.stderr)
p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
check(p.returncode == 0 and (f.role() or {}).get('session') == CHILD, 'bg expected full identity joins',p.stderr)

# A native candidate that arrives early cannot capture a launch later bound to another full identity.
f = Fixture(); f.prompt(); launch,_ = f.open()
f.grill('join','--launch',launch,'--session','self',sid=OTHER)
p = f.grill('bind','--launch',launch,'--session',CHILD,sid=OTHER)
check(p.returncode == 2 and not f.role(), 'only launcher binds without administrative reason',p.stderr)
p = f.grill('bind','--launch',launch,'--session',CHILD)
check(p.returncode == 0 and not f.role(), 'binding ignores a different early candidate',p.stderr)
p = f.grill('join','--launch',launch,'--session','self',sid=CHILD)
check(p.returncode == 0 and (f.role() or {}).get('session') == CHILD, 'expected native child wins over early candidate',p.stderr)
p = f.grill('done','--launch',launch,sid=CHILD)
check(p.returncode == 0, 'expected child reports after native binding',p.stderr)
check(not f.mark().exists(), 'hub marker stays cleared after GRILLED')
p = f.run('hub','handoff','--stage','stage-a','--n','1','--out',str(f.root/'HANDOFF-review.md'))
check(p.returncode == 0, 'hub handoff proceeds after GRILLED',p.stderr)

# M3: stale cleanup cannot remove a new pending launch, even with an administrative reason.
for args in ((),('--why','owner stopped'),('--launch','CURRENT'),
             ('--launch','stale','--why','owner stopped')):
    f = Fixture(); launch,_ = f.open()
    args = tuple(launch if arg == 'CURRENT' else arg for arg in args)
    p = f.grill('done',*args)
    state = json.loads((f.home/'stage-a/grill.json').read_text()) if (f.home/'stage-a/grill.json').exists() else {}
    check(p.returncode == 2 and state.get('pending',{}).get('launch') == launch,
          'pending done rejects '+repr(args),p.stdout+p.stderr)
f = Fixture(); launch,_ = f.open()
p = f.grill('done','--launch',launch,'--why','owner stopped')
check(p.returncode == 0 and not (f.home/'stage-a/grill.json').exists(), 'matching pending done with reason succeeds',p.stderr)

# M4: delegation ends the hub's hold only after a successful open; the child is never a hub.
for mode in ('success','dry-run','failure','empty'):
    f = Fixture(); p = f.prompt()
    check(f.mark().exists(), mode+': explicit skill prompt marks registered hub',p.stderr)
    args = ['--host','desktop']
    if mode == 'dry-run': args += ['--dry-run']
    if mode == 'failure':
        f.open(); f.prompt()  # restore a hold before a busy launch fails
    if mode == 'empty': f.run('ask','close',f.qid,'--answer','yes')
    p = f.grill(*args)
    check(p.returncode == {'success':0,'dry-run':0,'failure':2,'empty':1}[mode], mode+': open exit',p.stderr)
    check(f.mark().exists() == (mode != 'success'), mode+': marker lifecycle')
f = Fixture(); launch,_ = f.open(); f.grill('bind','--launch',launch,'--session',CHILD)
f.grill('join','--launch',launch,'--session','self',sid=CHILD)
p = f.prompt(CHILD,tokens=510000)
check(not f.mark(CHILD).exists(), 'child explicit skill prompt creates no hub marker')
check('Autopilot is on' not in p.stdout and 'hub succeed --stage' not in p.stdout,
      'child receives no automatic hub handoff',p.stdout)
sys.exit(bool(failures))
PY
exit $?
