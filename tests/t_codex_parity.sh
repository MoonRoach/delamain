#!/usr/bin/env bash
# Runtime, identity and reviewer-budget controls: fake homes/caches, no model or native app calls.
# PARITY_CASE selects identity, wait, runtime, helpers, agents_cell, helpers_whitespace,
# helpers_invalid, helpers_zero_doc, or a host_* control (host runs all host controls).
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
PARITY_ROOT="${BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}"
PARITY_TMP="$(mktemp -d)"
trap 'rm -rf "$PARITY_TMP"' EXIT
python3 - "$PARITY_ROOT" "$PARITY_TMP" <<'PY'
import contextlib, importlib.machinery, importlib.util, io, json, os, pathlib, re, shutil, subprocess, sys
bins, tmp = (pathlib.Path(p).resolve() for p in sys.argv[1:])
sys.path.insert(0, str(bins))
import hubcore as hc
loader = importlib.machinery.SourceFileLoader('parity_hub', str(bins/'hub'))
spec = importlib.util.spec_from_loader(loader.name, loader)
hub = importlib.util.module_from_spec(spec); loader.exec_module(hub)
case = os.environ.get('PARITY_CASE', 'all')
env = {k:v for k,v in os.environ.items() if not k.startswith(('AGENT_', 'HUB_', 'CODEX_', 'CLAUDE_', 'PLUGIN_'))}
env.update(AGENT_HUB_HOME=str(tmp/'home'), AGENT_HUB_STATE_DIR=str(tmp/'state'), HOME=str(tmp/'user'),
           CLAUDE_CONFIG_DIR=str(tmp/'claude'), CODEX_HOME=str(tmp/'codex'), CLAUDE_BIN=str(tmp/'no-cli'),
           AGENT_HUB_TZ='UTC', AGENT_HUB_NO_PROJECT='1', AGENT_HUB_NO_NAMING='1')
os.environ.clear(); os.environ.update(env)
old = '11111111-1111-4111-8111-111111111111'
new = '22222222-2222-4222-8222-222222222222'
stage = tmp/'home/stage-a'; stage.mkdir(parents=True)
record = {'session':old, 'cli_session_id':old, 'tag':'hub-1', 'kind':'cli', 'engine':'codex'}
(stage/'roles.json').write_text(json.dumps({'roles':{'hub':record}}))

def call(b, *args, extra=None, cwd=None):
    return subprocess.run([str(b), *args], env=env | (extra or {}), cwd=cwd or tmp,
                          text=True, capture_output=True, timeout=30)

# Each round-one finding can run before fixes without an earlier stale expectation masking it.
host_cases = {'host_claude_home': ('claude', 'home'), 'host_claude_project': ('claude', 'project'),
              'host_codex_home': ('codex', 'home'), 'host_codex_project': ('codex', 'project'),
              'host_codex_env': ('codex', 'env'), 'host_terminal': ('codex', 'terminal'),
              'host_terminal_claude': ('claude', 'terminal')}
if case in ('all', 'host', *host_cases):
    # A deliberately newer cache proves that cross-engine warnings are excluded, not merely absent.
    cache = tmp/'codex/plugins/cache/market/delamain/999.0.0'
    (cache/'bin').mkdir(parents=True)
    (cache/'.codex-plugin').mkdir()
    (cache/'.codex-plugin/plugin.json').write_text(json.dumps({'version':'999.0.0'}))
    for name, (host, layer) in host_cases.items():
        if case not in ('all', 'host', name):
            continue
        config = tmp/'home/config.json'
        if config.exists(): config.unlink()
        cwd = tmp
        extra = {}
        if layer == 'terminal':
            extra['AGENT_HUB_ENGINE'] = host
        else:
            extra['CODEX_THREAD_ID' if host=='codex' else 'CLAUDE_CODE_SESSION_ID'] = new
            executor = 'claude' if host=='codex' else 'codex'
            if layer == 'env':
                extra['AGENT_HUB_ENGINE'] = executor
            elif layer == 'home':
                config.write_text(json.dumps({'AGENT_HUB_ENGINE':executor}))
            else:
                cwd = tmp/name; cwd.mkdir(); (cwd/'.agent-hub').mkdir()
                subprocess.run(['git','init','-q',str(cwd)],check=True,capture_output=True)
                (cwd/'.agent-hub/config.json').write_text(json.dumps({'AGENT_HUB_ENGINE':executor}))
        r = call(bins/'hub','takeover','--stage','stage-a','--session',new,'--dry-run',extra=extra,cwd=cwd)
        assert r.returncode == 0, (name,r.stdout,r.stderr)
        digest = r.stdout[r.stdout.index('DIGEST'):]
        expected = 'yielded shell session' if host=='codex' else 'Bash `run_in_background: true`'
        assert expected in digest, (f'{name}: takeover digest must follow actual host, not executor default',digest)
        assert ('yielded shell session' in digest) == (host=='codex'), (name,digest)
        if host == 'claude':
            assert 'newer codex plugin' not in r.stdout and '(codex;' not in r.stdout, (name,r.stdout)
        print(f'PASS {name}: actual-host digest waits and runtime-cache selection')
    if (tmp/'home/config.json').exists(): (tmp/'home/config.json').unlink()
    shutil.rmtree(cache)

if case in ('all', 'identity'):
    for identity in ('CODEX_THREAD_ID', 'AGENT_SESSION_ID', 'CLAUDE_CODE_SESSION_ID'):
        os.environ.pop('CODEX_THREAD_ID', None); os.environ.pop('AGENT_SESSION_ID', None)
        os.environ.pop('CLAUDE_CODE_SESSION_ID', None)
        os.environ['AGENT_HUB_ENGINE'] = 'claude' if identity.startswith('CLAUDE') else 'codex'
        os.environ[identity] = old
        rows = hub.hub_sessions('stage-a', 'self', {'cli':new})
        assert rows[0][0] == old and rows[0][1]['tag'] == 'hub-1', rows
    # A worker's own UUID has priority over an inherited Claude identity.
    os.environ.update(AGENT_HUB_ENGINE='codex', CODEX_THREAD_ID=new, AGENT_SESSION_ID=old,
                      CLAUDE_CODE_SESSION_ID=old)
    assert hc.session_id() == new
    for key in ('CODEX_THREAD_ID', 'AGENT_SESSION_ID', 'CLAUDE_CODE_SESSION_ID'):
        os.environ.pop(key, None)
    try: hub.hub_sessions('stage-a', 'self', {'cli':old})
    except hc.UsageError: pass
    else: raise AssertionError('unresolved self borrowed the registered hub identity')
    print('PASS self resolves both hosts and worker identity with registry ownership; missing identity refuses')
if case in ('all', 'wait'):
    for engine, key in (('codex', 'CODEX_THREAD_ID'), ('codex', 'AGENT_SESSION_ID'), ('claude', 'CLAUDE_CODE_SESSION_ID')):
        path=tmp/f'HANDOFF-{engine}-{key}.md'
        r=call(bins/'hub', 'handoff', '--stage','stage-a','--session',old,'--out',str(path),
               extra={'AGENT_HUB_ENGINE':engine, key:old})
        assert r.returncode == 0, (r.stdout, r.stderr)
        text=path.read_text()
        step = next(line for line in text.splitlines() if line.startswith('2. The first `jwait`'))
        assert 'wait procedure' in step and 'takeover digest' in step, step
        assert all(word not in step for word in ('Claude:', 'Codex:', 'run_in_background', 'yielded shell')), (
            'handoff step 2 must defer to the reading host takeover digest', step)
    print('PASS generated handoff step 2 is engine-neutral for Claude, Codex and detached Codex writers')

if case in ('all', 'agents_cell'):
    (stage/'agents').mkdir(exist_ok=True)
    path = tmp/'HANDOFF-agents-cell.md'
    r = call(bins/'hub','handoff','--stage','stage-a','--session',old,'--out',str(path),
             extra={'CLAUDE_CODE_SESSION_ID':old})
    assert r.returncode == 0, (r.stdout,r.stderr)
    cell = next(line for line in path.read_text().splitlines() if line.startswith('| Headless agents |'))
    assert 'no headless agents' in cell, ('agent status capture positive control',cell)
    assert 'Plugin runtime:' not in cell, ('runtime header must not consume the handoff agents cell',cell)
    print('PASS handoff Headless agents cell contains status without the Plugin runtime header')

if case in ('all', 'runtime'):
    runtime=tmp/'runtime'; shutil.copytree(bins, runtime/'bin', ignore=shutil.ignore_patterns('__pycache__'))
    for engine in ('claude', 'codex'):
        manifest=runtime/f'.{engine}-plugin/plugin.json'; manifest.parent.mkdir()
        manifest.write_text(json.dumps({'name':'delamain','version':'0.9.0' if engine=='claude' else '0.8.0'}))
    def cache(engine, folder, version=None):
        path=tmp/engine/'plugins/cache/market/delamain'/folder
        (path/'bin').mkdir(parents=True)
        if version is not None:
            manifest=path/f'.{engine}-plugin/plugin.json'; manifest.parent.mkdir()
            manifest.write_text(json.dumps({'version':version}))
        return path/'bin'
    cache('claude', '0.8.1'); cache('codex', '0.7.1'); cache('codex', 'unknown', 'bad')
    high=cache('claude', '0.10.0'); low=cache('codex', '0.8.0')
    for engine, expected in (('claude','0.9.0'), ('codex','0.8.0')):
        extra={'AGENT_HUB_ENGINE':engine, 'CODEX_THREAD_ID':old} if engine=='codex' else {'AGENT_HUB_ENGINE':engine,'CLAUDE_CODE_SESSION_ID':old}
        r=call(runtime/'bin/agent', 'status','--stage','stage-a', extra=extra)
        assert r.returncode==0, r.stderr
        assert f'delamain {expected} ({engine}; {runtime}/bin)' in r.stdout, r.stdout
        assert ('newer' in r.stdout) == (engine=='claude'), r.stdout
    cache('codex', '0.9.2'); cache('codex', '0.9.1')
    for engine in ('claude','codex'):
        extra={'AGENT_HUB_ENGINE':engine, 'CODEX_THREAD_ID':new} if engine=='codex' else {'AGENT_HUB_ENGINE':engine,'CLAUDE_CODE_SESSION_ID':new}
        r=call(runtime/'bin/hub','takeover','--stage','stage-a','--session','self','--dry-run', extra=extra)
        assert r.returncode==0, (r.stdout,r.stderr)
        assert 'Plugin runtime: delamain' in r.stdout and str(runtime/'bin') in r.stdout, r.stdout
        expected='0.9.2' if engine=='codex' else '0.10.0'
        assert f'newer {engine} plugin {expected}' in r.stdout, r.stdout
        digest=r.stdout[r.stdout.index('DIGEST'):]
        assert len(digest.encode()) <= 3072
        assert ('yielded shell session' in digest) == (engine=='codex')
    # The rename: a newer cache folder under the plugin's name before it is an installed copy too; another name is not.
    for name, counts in (('delamain', True), ('agent-hub', True), ('other-plugin', False)):  # rename:keep
        cfg = tmp/f'rename-{name}'
        (cfg/'plugins/cache/market'/name/'9.9.9/bin').mkdir(parents=True)
        os.environ['CLAUDE_CONFIG_DIR'] = str(cfg)
        line = hc.plugin_runtime_line('claude')
        assert ('ATTENTION: newer claude plugin 9.9.9' in line) == counts, (name, line)
    os.environ['CLAUDE_CONFIG_DIR'] = str(tmp/'claude')
    print('PASS rename: the runtime header sees a newer cache under the current and the former plugin name, not under another')
    # An unreadable runtime version cannot honestly be ordered against the caches.
    (runtime/'.claude-plugin/plugin.json').write_text('{}'); (runtime/'.codex-plugin/plugin.json').write_text('{}')
    r=call(runtime/'bin/agent','status','--stage','stage-a',extra={'AGENT_HUB_ENGINE':'codex'})
    assert r.returncode==0 and 'version unknown' in r.stdout and 'newer' not in r.stdout
    print('PASS actual bin manifests, same-engine fake caches, semantic ordering, unknown versions and bounded takeover digest')

if case in ('all', 'helpers'):
    os.environ.pop('AGENT_HUB_REVIEW_HELPER_LINES', None)
    assert hc.review_helper_lines() == 300
    repo=tmp/'repo'; repo.mkdir(); (repo/'.agent-hub').mkdir()
    subprocess.run(['git','init','-q',str(repo)],check=True,capture_output=True)
    homeconfig=tmp/'home/config.json'; homeconfig.write_text(json.dumps({'AGENT_HUB_REVIEW_HELPER_LINES':180}))
    os.chdir(repo); hc._CONFIG_CACHE.clear()
    assert hc.review_helper_lines() == 180
    (repo/'.agent-hub/config.json').write_text(json.dumps({'AGENT_HUB_REVIEW_HELPER_LINES':90}))
    hc._CONFIG_CACHE.clear()
    assert hc.review_helper_lines() == 90
    os.environ['AGENT_HUB_REVIEW_HELPER_LINES']='0'
    assert hc.review_helper_lines() == 0
    os.environ['AGENT_HUB_REVIEW_HELPER_LINES']='invalid'
    warnings=io.StringIO()
    with contextlib.redirect_stderr(warnings):
        assert hc.review_helper_lines() == 300
    assert 'AGENT_HUB_REVIEW_HELPER_LINES' in warnings.getvalue() and '300' in warnings.getvalue()
    r=call(bins/'hub','reviewer','--for','docs','--json',extra={'AGENT_HUB_REVIEW_HELPER_LINES':'77'})
    assert json.loads(r.stdout)['helper_threshold'] == 77, (r.stdout,r.stderr)
    print('PASS helper threshold defaults/layers/env/zero/invalid controls and reviewer JSON expose the configured cap')

if case in ('all', 'helpers_whitespace'):
    os.environ['AGENT_HUB_REVIEW_HELPER_LINES']=' 200 \t'
    assert hc.review_helper_lines() == 200, 'helper threshold must strip surrounding whitespace'
    print('PASS helper threshold strips whitespace')

if case in ('all', 'helpers_invalid'):
    os.environ['AGENT_HUB_REVIEW_HELPER_LINES']=' invalid '
    warnings=io.StringIO()
    with contextlib.redirect_stderr(warnings):
        assert hc.review_helper_lines() == 300, 'malformed advisory threshold must fall back to 300'
    assert 'AGENT_HUB_REVIEW_HELPER_LINES' in warnings.getvalue() and '300' in warnings.getvalue(), warnings.getvalue()
    valid=call(bins/'hub','reviewer','--for','docs','--json',extra={'AGENT_HUB_REVIEW_HELPER_LINES':'300'})
    malformed=call(bins/'hub','reviewer','--for','docs','--json',extra={'AGENT_HUB_REVIEW_HELPER_LINES':'invalid'})
    assert malformed.returncode == valid.returncode, (valid.returncode,malformed.returncode,malformed.stderr)
    assert json.loads(malformed.stdout)['helper_threshold'] == 300, malformed.stdout
    assert 'AGENT_HUB_REVIEW_HELPER_LINES' in malformed.stderr and '300' in malformed.stderr, malformed.stderr
    print('PASS malformed helper threshold warns, defaults to 300 and preserves reviewer selection')

if case in ('all', 'helpers_zero_doc'):
    text=(bins.parent/'docs/reviewers.md').read_text()
    zero = next((p for p in text.split('\n\n') if re.search(r'`0`|\bzero\b',p,re.I)), '')
    assert zero and re.search(r'always|disabl|regardless|remov|no .*threshold',zero,re.I), (
        'docs/reviewers.md must explain that zero removes the helper size gate', zero)
    print('PASS reviewer documentation states the zero threshold semantics')
PY
