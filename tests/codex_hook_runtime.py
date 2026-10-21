#!/usr/bin/env python3
"""Real CLI hook dispatch with a deterministic localhost Responses provider.

No authentication or model usage. All homes, roles, commands and hook captures are
throwaway fixtures. This tests the declared manifest, not an imitation matcher.
"""
import copy
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import threading
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
from engines import toml_value

ROOT = Path(__file__).resolve().parent.parent


def main():
    cli = shutil.which('codex')
    if not cli:
        print('SKIP runtime hook dispatch: Codex CLI unavailable')
        return
    with tempfile.TemporaryDirectory(prefix='delamain-hook-runtime-') as temporary:
        directory = Path(temporary)
        home = directory / 'home'
        home.mkdir()
        repo = directory / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True, capture_output=True)
        hub = directory / 'hub'
        hub.mkdir()
        roles = repo / '.codex/agents'
        roles.mkdir(parents=True)
        for source in (ROOT / 'skills/setup/resources/codex-agents').glob('worker-*.toml'):
            shutil.copy(source, roles / source.name)
        (hub / 'config.json').write_text(json.dumps({
            'AGENT_HUB_DELEGATION': True, 'AGENT_HUB_DELEGATION_DEFAULT': 0,
            'AGENT_HUB_HANDOFF_MAX_BYTES': 20, 'AGENT_HUB_SCOPE_DIRS': str(repo)}))
        capture = directory / 'hooks.jsonl'
        recorder = directory / 'record.py'
        recorder.write_text('import json,sys\nfrom pathlib import Path\n'
                            f'p=Path({str(capture)!r})\n'
                            'with p.open("a") as f: f.write(json.dumps(json.load(sys.stdin))+"\\n")\n')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('CODEX_', 'AGENT_', 'HUB_', 'CLAUDE_', 'PLUGIN_'))}
        env.update(HOME=str(directory), CODEX_HOME=str(home), AGENT_HUB_HOME=str(hub),
                   PLUGIN_ROOT=str(ROOT), AGENT_HUB_ENGINE='codex', AGENT_HUB_TZ='UTC')
        lock = subprocess.run([str(ROOT / 'bin/lock'), 'take', 'main-merge', '--repo', '*',
                               '--until', '2099-01-01T00:00', '--owner', 'Fixture', '--why', 'runtime control'],
                              env={**env, 'CODEX_THREAD_ID': 'fixture-lock-holder'},
                              capture_output=True, text=True, timeout=10)
        assert lock.returncode == 0, lock.stderr
        scripts = [
            'text(await tools.exec_command({cmd: "git push origin HEAD:main"}));',
            'text(await tools.exec_command({cmd: "printf SHELL_ALLOWED"}));',
            'text(await tools.exec_command({cmd: "sleep 120"}));',
            'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: HANDOFF-large.md\\n+' + 'x' * 30 + '\\n*** End Patch"));',
            'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: small.txt\\n+PATCH_ALLOWED\\n*** End Patch"));',
        ]
        calls = [{'type': 'custom_tool_call', 'name': 'exec', 'namespace': 'functions',
                  'input': script} for script in scripts]
        # Invalid fixture targets ensure a mistakenly allowed call cannot reach a real
        # agent; denial must still come from the hook, before target resolution.
        for name, args in [('spawn_agent', {'task_name': 'fixture', 'message': 'fixture'}),
                           ('followup_task', {'target': 'fixture_absent_agent', 'message': 'fixture'}),
                           ('send_message', {'target': 'fixture_absent_agent', 'message': 'fixture'})]:
            calls.append({'type': 'function_call', 'name': name, 'namespace': 'collaboration',
                          'arguments': json.dumps(args)})
        calls.append({'type': 'function_call', 'name': 'send_message', 'namespace': 'collaboration',
                      'arguments': json.dumps({'target': 'fixture_absent_agent', 'message': 'fixture'}),
                      'policy': {'AGENT_HUB_DELEGATION': True, 'AGENT_HUB_DELEGATION_DEFAULT': 3,
                                 'AGENT_HUB_DELEGATION_RULES': [{'when': {'tool': 'SendMessage'},
                                    'decision': 'deny', 'reason': 'fixture send denied'}]}})
        for effort in ('medium', 'high'):
            calls.append({'type': 'function_call', 'name': 'spawn_agent', 'namespace': 'collaboration',
                          'arguments': json.dumps({'task_name': 'fixture_' + effort, 'message': 'fixture child',
                             'fork_turns': 'none', 'agent_type': 'worker-' + effort, 'model': 'gpt-6.1-sol', 'reasoning_effort': 'high'}),
                          'policy': {'AGENT_HUB_DELEGATION': True, 'AGENT_HUB_DELEGATION_DEFAULT': 3,
                                     'AGENT_HUB_EFFORT_RULES': {'gpt-*': 'high'}}})
        calls.extend([
            {'type': 'function_call', 'name': 'wait_agent', 'namespace': 'collaboration',
             'arguments': json.dumps({'timeout_ms': 10000})},
            {'type': 'function_call', 'name': 'followup_task', 'namespace': 'collaboration',
             'arguments': json.dumps({'target': 'fixture_high', 'message': 'fixture child followup'})},
            {'type': 'function_call', 'name': 'wait_agent', 'namespace': 'collaboration',
             'arguments': json.dumps({'timeout_ms': 10000})},
        ])
        calls.append({'type': 'custom_tool_call', 'name': 'exec', 'namespace': 'functions',
                      'input': 'text(await tools.exec_command({cmd: "cat", tty: true, yield_time_ms: 1000}));'})
        # The session id for the cat command is extracted from the returned request.
        calls.append({'stdin_control': True})
        requests = []
        child_requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                child = bool(data.get('client_metadata', {}).get('x-openai-subagent'))
                if child:
                    child_requests.append(data)
                index = len(requests)
                if not child:
                    requests.append(data)
                if not child and index < len(calls):
                    item = copy.deepcopy(calls[index])
                    policy = item.pop('policy', None)
                    if policy is not None:
                        (hub / 'config.json').write_text(json.dumps(policy))
                    if item.pop('stdin_control', False):
                        outputs = [i for i in data['input'] if i.get('type') == 'custom_tool_call_output']
                        output = outputs[-1]['output']
                        # functions.exec encodes its text items as content blocks.
                        serialized = '\n'.join(block['text'] for block in output)
                        import re
                        match = re.search(r'session_id\\?"\s*:\s*(\d+)', serialized)
                        assert match, serialized
                        sid = int(match[1])
                        item = {'type': 'custom_tool_call', 'name': 'exec', 'namespace': 'functions',
                                'input': f'text(await tools.write_stdin({{session_id: {sid}, chars: "HARMLESS\\n", yield_time_ms: 1000}})); text(await tools.write_stdin({{session_id: {sid}, chars: "\\u0004", yield_time_ms: 1000}}));'}
                    item['call_id'] = f'control_{index}'
                else:
                    item = {'type': 'message', 'id': 'final', 'role': 'assistant',
                            'content': [{'type': 'output_text', 'text': 'DONE'}]}
                events = [{'type': 'response.created', 'response': {'id': f'r{index}'}},
                          {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                          {'type': 'response.completed', 'response': {'id': f'r{index}', 'status': 'completed',
                            'output': [], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for event in events:
                    self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        hooks = json.loads((ROOT / 'hooks/codex-hooks.json').read_text())['hooks']
        hooks = copy.deepcopy(hooks)
        for event in ('PreToolUse', 'PostToolUse'):
            hooks[event].append({'matcher': '*', 'hooks': [{'type': 'command',
                'command': f'python3 {shlex.quote(str(recorder))}', 'timeout': 5}]})
        argv = [cli, 'exec', '--skip-git-repo-check', '--json',
                '--dangerously-bypass-approvals-and-sandbox', '--dangerously-bypass-hook-trust',
                '-C', str(repo), '-c', 'projects.' + json.dumps(str(repo)) + '.trust_level="trusted"', '-m', 'gpt-6.1-sol', '--enable', 'hooks',
                '-c', 'model_provider="fixture"', '-c', 'model_providers.fixture.name="Fixture"',
                '-c', f'model_providers.fixture.base_url="http://127.0.0.1:{server.server_port}"',
                '-c', 'model_providers.fixture.wire_api="responses"',
                '-c', 'model_providers.fixture.requires_openai_auth=false']
        for event, groups in hooks.items():
            argv.extend(['-c', f'hooks.{event}=' + toml_value(groups)])
        try:
            result = subprocess.run([*argv, 'fixture hook dispatch'], env=env, input='',
                                    capture_output=True, text=True, timeout=55)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        assert result.returncode == 0, (result.stdout, result.stderr)
        if os.environ.get('CODEX_HOOK_EVIDENCE_DIR'):
            evidence = Path(os.environ['CODEX_HOOK_EVIDENCE_DIR'])
            evidence.mkdir(parents=True, exist_ok=True)
            shutil.copy(capture, evidence / 'hooks.jsonl')
            (evidence / 'requests.json').write_text(json.dumps(requests, indent=2))
            (evidence / 'child-requests.json').write_text(json.dumps(child_requests, indent=2))
            (evidence / 'cli.jsonl').write_text(result.stdout)
            (evidence / 'cli.stderr').write_text(result.stderr)
        (directory / 'requests.json').write_text(json.dumps(requests))
        outputs = [i.get('output', '') for request in requests for i in request['input']
                   if i.get('type') in ('function_call_output', 'custom_tool_call_output')]
        combined = '\n'.join(str(o) for o in outputs)
        assert 'board_locks' in combined, combined
        assert 'polling guard' in combined, combined
        assert 'Handoff is 31 bytes > 20' in combined, combined
        assert 'SHELL_ALLOWED' in combined, combined
        assert (repo / 'small.txt').read_text() == 'PATCH_ALLOWED\n'
        assert not (repo / 'HANDOFF-large.md').exists()
        final_outputs = {i['call_id']: str(i.get('output', '')) for i in requests[-1]['input']
                         if i.get('type') in ('function_call_output', 'custom_tool_call_output')}
        for index in (5, 6):
            assert 'Delegation level is 0' in final_outputs[f'control_{index}'], final_outputs
        assert 'PreToolUse' not in final_outputs['control_7'], final_outputs
        assert 'fixture send denied' in final_outputs['control_8'], final_outputs
        assert 'PreToolUse' in final_outputs['control_9'], final_outputs
        assert 'task_name' in final_outputs['control_10'], final_outputs
        assert 'fixture_high' in final_outputs['control_10'], final_outputs
        assert 'failed' not in final_outputs['control_10'].lower(), final_outputs
        assert 'PreToolUse' not in final_outputs['control_12'], final_outputs
        assert len(child_requests) == 2, len(child_requests)
        assert all(r['reasoning']['effort'] == 'high' for r in child_requests), child_requests
        assert len({r['client_metadata']['thread_id'] for r in child_requests}) == 1, child_requests
        assert child_requests[0]['client_metadata']['thread_id'] != requests[0]['client_metadata']['thread_id']
        assert 'HARMLESS' in combined, combined
        records = [json.loads(line) for line in capture.read_text().splitlines()]
        pre = [r for r in records if r['hook_event_name'] == 'PreToolUse']
        names = {r['tool_name'] for r in pre}
        assert {'Bash', 'apply_patch', 'collaborationspawn_agent', 'collaborationfollowup_task', 'collaborationsend_message'} <= names, names
        assert 'write_stdin' not in names, names
        assert any(r['tool_name'] == 'Bash' and r['tool_input']['command'] == 'cat'
                   for r in records if r['hook_event_name'] == 'PostToolUse'), records
        print('PASS real CLI declared manifest: nested shell/patch guards, native spawn/followup lifecycle and send policy, TOML pinned effort, harmless message/stdin, deferred PostToolUse')
        print('Observed PreToolUse names:', ', '.join(sorted(names)))


if __name__ == '__main__':
    main()
