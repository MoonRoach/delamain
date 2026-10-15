#!/bin/bash
# Exercise registered real hook processes; no Codex model or runtime mutation.
set -eu
T="$(cd "$(dirname "$0")" && pwd)"
python3 - "$T/.." <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1]).resolve()
EXPECTED = {
    'continue': False,
    'stopReason': 'Delamain forbids automatic and manual compaction. Save a checkpoint and follow the existing handoff policy.',
    'systemMessage': 'Delamain blocked compaction. If the automatic context limit has been reached, this session may stop before an answer; continue from its checkpoint with a fresh coordinator for the same stage under existing authority. Repeating prompts in an overfull session will not help. Below that limit, normal prompts and tools can continue.',
}


class NoCompactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='no-compaction-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.hub = self.home / 'hub'
        self.hub.mkdir()
        self.env = {'PATH': os.defpath, 'HOME': str(self.home),
                    'AGENT_HUB_HOME': str(self.hub), 'PLUGIN_ROOT': str(ROOT)}
        self.config = json.loads((ROOT / 'hooks/codex-hooks.json').read_text())

    def test_registered_hook_process_vetoes_both_triggers_without_metadata(self):
        groups = self.config['hooks']['PreCompact']
        for trigger in ('auto', 'manual'):
            selected = [g for g in groups if re.search(g['matcher'], trigger)]
            self.assertEqual(len(selected), 1)
            self.assertEqual(len(selected[0]['hooks']), 1)
            handler = selected[0]['hooks'][0]
            self.assertEqual(handler['type'], 'command')
            for extra in ({}, {'session_id': 'native', 'transcript_path': '/missing'},
                          {'agent_id': 'child', 'agent_transcript_path': '/missing'},
                          {'session_id': None, 'cwd': '/missing', 'trigger': trigger}):
                for budget in ('on', 'off'):
                    with self.subTest(trigger=trigger, extra=extra, budget=budget):
                        # Both environment and hub config must be irrelevant.
                        (self.hub / 'config.json').write_text(json.dumps({
                            'AGENT_HUB_CONTEXT_BUDGET': budget,
                            'AGENT_HUB_CONTEXT_WARN': 900000,
                            'AGENT_HUB_CONTEXT_BLOCK': 900000,
                            'AGENT_HUB_SCOPE_DIRS': '/unrelated',
                        }))
                        event = {'hook_event_name': 'PreCompact', 'trigger': trigger, **extra}
                        run = subprocess.run(['/bin/bash', '-c', handler['command']],
                            input=json.dumps(event), capture_output=True, text=True,
                            env={**self.env, 'AGENT_HUB_CONTEXT_BUDGET': budget},
                            cwd=self.home, timeout=5)
                        self.assertEqual(run.returncode, 0, run.stderr)
                        self.assertEqual(run.stderr, '')
                        output = json.loads(run.stdout)
                        self.assertIs(output['continue'], False)
                        self.assertEqual(output, EXPECTED)

    def test_veto_does_not_parse_or_require_stdin(self):
        for raw in ('', '{}', 'null', 'not JSON'):
            with self.subTest(raw=raw):
                run = subprocess.run([sys.executable, str(ROOT / 'hooks/no_compaction.py')],
                    input=raw, capture_output=True, text=True, env=self.env,
                    cwd=self.home, timeout=5)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(json.loads(run.stdout), EXPECTED)

    def test_veto_exits_without_waiting_for_stdin_eof(self):
        run = subprocess.Popen([sys.executable, str(ROOT / 'hooks/no_compaction.py')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=self.env, cwd=self.home)
        try:
            self.assertEqual(run.wait(timeout=5), 0)
            self.assertEqual(json.loads(run.stdout.read()), EXPECTED)
            self.assertEqual(run.stderr.read(), '')
        finally:
            if run.poll() is None:
                run.kill()
                run.wait()
            run.stdin.close()
            run.stdout.close()
            run.stderr.close()

    def test_registration_is_scoped_to_precompact_and_claude_is_unchanged(self):
        for event, groups in self.config['hooks'].items():
            for group in groups:
                for handler in group['hooks']:
                    if 'no_compaction.py' in handler['command']:
                        self.assertEqual(event, 'PreCompact')
        self.assertNotIn('no_compaction', (ROOT / 'hooks/hooks.json').read_text())
        # Positive unrelated-event control executes the existing budget hook.
        run = subprocess.run([sys.executable, str(ROOT / 'hooks/context_budget.py')],
            input=json.dumps({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                              'tool_input': {'command': 'echo ok'}}),
            capture_output=True, text=True,
            env={**self.env, 'AGENT_HUB_CONTEXT_BUDGET': 'off'},
            cwd=self.home, timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.strip(), '')


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
