#!/bin/bash
# Interpreter discovery and hook execution with isolated PATH fixtures.
set -eu
T="$(cd "$(dirname "$0")" && pwd)"
python3 - "$T/.." <<'PY'
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv[1]).resolve()


class PythonRuntime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='runtime with spaces ')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('DELAMAIN_', 'AGENT_', 'HUB_', 'CLAUDE_', 'CODEX_'))}
        self.env.update(PATH=str(self.directory), HOME=str(self.directory), AGENT_HUB_HOME=str(self.directory / 'hub'))
        self.probe = self.directory / 'probe script.py'
        self.probe.write_text('import json, sys\nprint(json.dumps([sys.argv[1:], sys.stdin.read()]))\nprint("stderr preserved", file=sys.stderr)\nraise SystemExit(23)\n')

    def interpreter(self, name, version):
        path = self.directory / name
        path.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then\n'
                        + f'  case "$3" in 3.10) exit {int(version < (3, 10))} ;; 3.11) exit {int(version < (3, 11))} ;; esac\n'
                        + 'fi\n' + f'printf "%s\\n" {shlex.quote(name)} >> {shlex.quote(str(self.directory / "selected"))}\n'
                        + f'exec {shlex.quote(sys.executable)} "$@"\n')
        path.chmod(0o755)
        return path

    def run_launcher(self, *args):
        return subprocess.run([str(ROOT / 'bin/run-python'), *args], env=self.env,
                              input='stdin with spaces\n', capture_output=True, text=True, timeout=5)

    def assert_selected(self, name, *prefix):
        result = self.run_launcher(*prefix, str(self.probe), 'space arg', 'literal $HOME; `echo x`')
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(json.loads(result.stdout), [['space arg', 'literal $HOME; `echo x`'], 'stdin with spaces\n'])
        self.assertEqual(result.stderr, 'stderr preserved\n')
        self.assertEqual((self.directory / 'selected').read_text().strip(), name)

    def test_compatible_default_precedes_versioned(self):
        self.interpreter('python3', (3, 11))
        self.interpreter('python3.14', (3, 14))
        self.assert_selected('python3')

    def test_old_default_uses_compatible_alternative(self):
        self.interpreter('python3', (3, 9))
        self.interpreter('python3.12', (3, 12))
        self.assert_selected('python3.12', '--min-version', '3.11')

    def test_common_minimum_keeps_python_310(self):
        self.interpreter('python3', (3, 10))
        self.assert_selected('python3')

    def test_codex_minimum_rejects_python_310(self):
        self.interpreter('python3', (3, 10))
        result = self.run_launcher('--min-version', '3.11', str(self.probe))
        self.assertEqual(result.returncode, 1)
        self.assertIn('Python 3.11+', result.stderr)
        self.assertFalse((self.directory / 'selected').exists())

    def test_override_with_spaces(self):
        self.interpreter('python3', (3, 14))
        selected = self.interpreter('explicit python', (3, 11))
        self.env['DELAMAIN_PYTHON'] = str(selected)
        self.assert_selected('explicit python', '--min-version', '3.11')

    def test_incompatible_and_missing_override_never_fall_back(self):
        self.interpreter('python3', (3, 14))
        old = self.interpreter('old python', (3, 9))
        for override in (str(old), str(self.directory / 'missing')):
            with self.subTest(override=override):
                self.env['DELAMAIN_PYTHON'] = override
                result = self.run_launcher(str(self.probe))
                self.assertEqual(result.returncode, 1)
                self.assertIn('DELAMAIN_PYTHON', result.stderr)
                self.assertFalse((self.directory / 'selected').exists())

    def test_no_python_and_invalid_invocation(self):
        for args, code in (((str(self.probe),), 1),):
            self.assertEqual(self.run_launcher(*args).returncode, code)

    def test_usage_errors_exit_1_not_2(self):
        # Exit 2 means "block" to Claude/Codex hooks; a usage error must fail open with 1.
        self.interpreter('python3', (3, 11))
        self.assertEqual(self.run_launcher('--min-version', '3.10', '-c', 'pass').returncode, 0)  # positive control
        for args in (('--min-version', '3.9', '-c', 'pass'), ('--min-version',), ()):
            with self.subTest(args=args):
                result = self.run_launcher(*args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('run-python', result.stderr)

    def test_python_command_fallback(self):
        self.interpreter('python', (3, 11))
        self.assert_selected('python', '--min-version', '3.11')

    def test_real_hook_command_selects_runtime_and_preserves_input(self):
        self.interpreter('python3', (3, 9))
        self.interpreter('python3.12', (3, 12))
        manifest = json.loads((ROOT / 'hooks/codex-hooks.json').read_text())
        plugin = self.directory / 'plugin with spaces'
        plugin.symlink_to(ROOT, target_is_directory=True)
        self.env['PLUGIN_ROOT'] = str(plugin)
        command = manifest['hooks']['PreToolUse'][0]['hooks'][1]['command']
        result = subprocess.run(['/bin/sh', '-c', command], env=self.env,
                                input=json.dumps({'hook_event_name': 'PreToolUse', 'session_id': 'fixture',
                                                  'cwd': str(self.directory), 'tool_name': 'Bash',
                                                  'tool_input': {'command': 'sleep 120'}}),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertEqual((self.directory / 'selected').read_text().strip(), 'python3.12')

    def test_exit_note_uses_launch_interpreter(self):
        sys.path.insert(0, str(ROOT / 'bin'))
        loader = importlib.machinery.SourceFileLoader('runtime_agent_fixture', str(ROOT / 'bin/agent'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        agent = importlib.util.module_from_spec(spec)
        loader.exec_module(agent)
        selected = self.directory / 'launch python'
        recorded = self.directory / 'exit args'
        selected.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' + shlex.quote(str(recorded)) + '\n')
        selected.chmod(0o755)
        # A stale child PATH must never be used for the exit note.
        self.interpreter('python3', (3, 9))
        meta = dict(dir=str(self.directory), engine='claude', process_token='token', session_id='session',
                    stage='fixture', tag='test', role='builder', cwd=str(self.directory))
        real_popen = subprocess.Popen
        captured = []
        def popen(argv, **kwargs):
            process = real_popen(argv, **kwargs)
            captured.append(process)
            return process
        with patch.object(agent, 'claude_argv', return_value=['/bin/sh', '-c', 'exit 17']), \
             patch.object(agent, 'child_env', return_value=dict(self.env, HUB_STAGE='fixture')), \
             patch.object(agent, 'bg_wait_ceiling', return_value='0'), \
             patch.object(agent, 'save_meta'), patch.object(agent, 'init_timeout', return_value=1), \
             patch.object(agent, 'wait_for_init', return_value={'session_id': 'session'}), \
             patch.object(agent.sys, 'executable', str(selected)), patch.object(agent.subprocess, 'Popen', side_effect=popen):
            agent.launch(meta, 'brief', False)
            self.assertEqual(captured[0].wait(timeout=5), 17)
        self.assertTrue(recorded.exists(), 'the exit note did not run the launch interpreter (selected python never recorded args)')
        self.assertEqual(recorded.read_text().splitlines(), [str(ROOT / 'bin/agent'), 'exit-note', 'builder',
                                                           '--stage', 'fixture', '--code', '17'])
        self.assertFalse((self.directory / 'selected').exists())


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PythonRuntime))
if result.wasSuccessful():
    for _ in range(result.testsRun):
        print('PASS Python runtime control')
sys.exit(not result.wasSuccessful())
PY
