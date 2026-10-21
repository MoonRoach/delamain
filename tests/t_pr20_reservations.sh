#!/usr/bin/env bash
# Review M1/M2 controls: synthetic launcher ownership and journal transitions, no models/app APIs.
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
R1_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
R1_TMP="$(mktemp -d)"
trap 'rm -rf "$R1_TMP"' EXIT
python3 - "$R1_BIN" "$R1_TMP" <<'PY'
import contextlib, inspect, io, json, os, pathlib, sys
bins,tmp=(pathlib.Path(x).resolve() for x in sys.argv[1:])
sys.path.insert(0,str(bins))
import autopilot as ap
import hubcore as hc
case=os.environ.get('PR20_CASE','all')
for key in tuple(os.environ):
    if key.startswith(('AGENT_','HUB_','CODEX_','CLAUDE_','PLUGIN_')):os.environ.pop(key,None)
old='11111111-1111-4111-8111-111111111111'
os.environ.update(AGENT_HUB_HOME=str(tmp/'home'),CODEX_THREAD_ID=old,AGENT_HUB_ENGINE='codex',AGENT_HUB_TZ='UTC')
stage=tmp/'home/stage-a';stage.mkdir(parents=True)
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':{'session':old,'cli_session_id':old,'tag':'hub-1'}}}))
handoff=stage/'HANDOFF.md';handoff.write_text('# Handoff\n## 0. First steps\nTake over\n')
owned={'n':2,'kind':'starting','at':'2020-01-01T00:00:00+00:00','k':1}
def save(pend,chain=1):ap.save_state('stage-a',{'chain':chain,'pending':pend})
def snapshot():return (stage/'auto-handoff.json').read_bytes()
def prepare(dry=False):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        rc=ap.prepare_desktop('stage-a',1,2,handoff,tmp,None,None,{'type':'danger-full-access'},'never',None,dry)
    return rc,out.getvalue()
def journal():
    p=hc.journal_path('stage-a');return p.read_text() if p.exists() else ''
for operation in ('record','release'):
    for other in ('desktop','stamp','count'):
        name=operation+'_'+other
        if case not in ('all',name):continue
        pending=dict(owned,kind='headless')
        if other=='desktop':pending.update(kind='desktop',surface='desktop',request_id='another-request')
        if other=='stamp':pending['at']='2020-01-01T00:01:00+00:00'
        if other=='count':pending['k']=2
        save(pending);before=snapshot()
        if operation=='record':ap._record('stage-a',2,dict(owned,kind='bg',id='late-cli'))
        else:
            args={'at':owned['at']} if 'at' in inspect.signature(ap._release).parameters else {}
            ap._release('stage-a',2,1,**args)
        assert snapshot()==before,(name,'late launcher modified another reservation or its chain')
        print('PASS',name,'leaves another launch and chain untouched')
if case == 'all':
    save(dict(owned));ap._record('stage-a',2,dict(owned,kind='bg',id='own-cli'))
    assert ap.load_state('stage-a')['pending']['id']=='own-cli'
    ap._release('stage-a',2,1,at=owned['at'])
    assert ap.load_state('stage-a')=={'chain':0,'pending':None}
    print('PASS own CLI result publishes and an owned failed launch refunds exactly once')
if case in ('all','prepare_inprogress'):
    for kind in ap.IN_PROGRESS:
        save(dict(owned,kind=kind));before=snapshot()
        try:prepare()
        except hc.Failure:pass
        else:raise AssertionError('Desktop replaced an aged in-progress '+kind+' reservation')
        assert snapshot()==before
    print('PASS Desktop refuses every aged same-number in-progress phase')
if case in ('all','journal_prepare','journal_fail','alarm'):
    save(None,0);rc,output=prepare();pend=ap.load_state('stage-a')['pending']
    if case in ('all','journal_prepare'):
        expected=f"auto-handoff 1/{ap.chain_limit()}: desktop request {pend['request_id']} prepared, handoff {handoff}"
        assert expected in journal(),('prepare journal',journal())
        print('PASS Desktop preparation journals request/chain/handoff')
    if case in ('all','journal_fail'):
        ap.desktop_fail('stage-a',pend['request_id'],'native result uncertain',False)
        text=journal();assert 'native result uncertain' in text and pend['request_id'] in text and str(handoff) in text
        print('PASS Desktop failure journals request, reason and handoff')
    if case in ('all','alarm'):
        assert 'On ALARM tell the owner one line' in output and 'unconfirmed' in output and str(handoff) in output
        alarm=output.split('On ALARM tell the owner one line',1)[1]
        assert 'keep the predecessor active' in alarm and 'retain the request' in alarm and 'awaiting the owner' in alarm
        assert 'then stop' not in alarm
        before=snapshot();predecessor=(stage/'roles.json').read_bytes()
        for _ in range(2):
            pending=ap.load_state('stage-a')['pending']
            with contextlib.redirect_stdout(io.StringIO()) as repeated:
                ap.desktop_report('stage-a',pending)
            assert pend['request_id'] in repeated.getvalue()
            try:ap.fallback('stage-a',1,'native request unconfirmed',2)
            except hc.UsageError as error:assert 'desktop request cannot fall back' in str(error)
            else:raise AssertionError('native ALARM allowed CLI fallback')
            assert snapshot()==before and (stage/'roles.json').read_bytes()==predecessor
            assert not (stage/'agents').exists()
        print('PASS Desktop ALARM retains request/chain and active predecessor; repeated report cannot launch CLI fallback')
if case in ('all','journal_limit'):
    save(None,ap.chain_limit());before=snapshot();rc,output=prepare()
    assert rc==3 and snapshot()==before
    assert 'auto-handoff chain limit' in journal() and str(handoff) in journal()
    print('PASS Desktop chain limit journals the handoff without reserving another successor')
PY
