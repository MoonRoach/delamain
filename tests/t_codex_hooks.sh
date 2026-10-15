#!/bin/bash
# Invoke the real hooks with documented Codex inputs in an isolated hub home.
set -eu
T="$(cd "$(dirname "$0")" && pwd)"
python3 - "$T/.." <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(ROOT / 'hooks'))
import codex_compat
import context_budget


class CodexHooks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.cwd = self.home / 'repo'
        self.cwd.mkdir()
        (self.cwd / '.git').mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('AGENT_', 'HUB_', 'CLAUDE_', 'CODEX_'))}
        self.env.update(HOME=str(self.home), AGENT_HUB_HOME=str(self.home / 'hub'),
                        PLUGIN_ROOT=str(ROOT), AGENT_HUB_ENGINE='codex', AGENT_HUB_TZ='UTC')
        Path(self.env['AGENT_HUB_HOME']).mkdir()
        self.config(AGENT_HUB_SCOPE_DIRS=str(self.cwd), AGENT_HUB_HANDOFF_MAX_BYTES=20)

    def config(self, **fields):
        (Path(self.env['AGENT_HUB_HOME']) / 'config.json').write_text(json.dumps(fields))

    def hook(self, name, tool=None, ti=None, event='PreToolUse', args=(), **fields):
        data = dict(session_id='codex-own', cwd=str(self.cwd), hook_event_name=event,
                    permission_mode='bypassPermissions')
        data.update(fields)
        if tool is not None:
            data.update(tool_name=tool, tool_input=ti or {})
        run = subprocess.run([sys.executable, str(ROOT / 'hooks' / name), *args],
                             input=json.dumps(data), capture_output=True, text=True, env=self.env, timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else {}

    def denied(self, out):
        return out.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'

    def patch(self, body):
        return self.hook('handoff_size.py', 'apply_patch', {'command': '*** Begin Patch\n' + body + '*** End Patch'})

    def test_patch_add_unicode_and_scope(self):
        self.assertTrue(self.denied(self.patch('*** Add File: HANDOFF-large.md\n+' + 'я' * 10 + '\n')))
        self.assertFalse(self.denied(self.patch('*** Add File: HANDOFF-small.md\n+small\n')))
        self.assertFalse(self.denied(self.patch('*** Add File: other.md\n+' + 'x' * 100 + '\n')))
        outside = self.home / 'HANDOFF-outside.md'
        self.assertFalse(self.denied(self.patch(f'*** Add File: {outside}\n+' + 'x' * 100 + '\n')))
        self.assertFalse((self.cwd / 'HANDOFF-small.md').exists(), 'guard must never mutate files')
        out = self.hook('handoff_size.py', 'apply_patch', {'command': '\n*** Begin Patch\n*** Add File: HANDOFF-padded.md\n+' + 'x' * 30 + '\n*** End Patch\n'})
        self.assertTrue(self.denied(out))

    def test_patch_update_multiple_hunks_delete_and_move(self):
        fp = self.cwd / 'HANDOFF-update.md'
        fp.write_text('first\nkeep\nlast\n')
        body = '*** Update File: HANDOFF-update.md\n@@\n-first\n+bigbigbigbig\n keep\n@@\n-last\n+bigbigbigbig\n*** End of File\n'
        self.assertTrue(self.denied(self.patch(body)))
        fp.write_text('x' * 40 + '\n')
        self.assertFalse(self.denied(self.patch('*** Update File: HANDOFF-update.md\n@@\n-' + 'x' * 40 + '\n+small\n')))
        self.assertFalse(self.denied(self.patch('*** Delete File: HANDOFF-update.md\n')))
        (self.cwd / 'ordinary.md').write_text('x\n')
        self.assertTrue(self.denied(self.patch('*** Update File: ordinary.md\n*** Move to: HANDOFF-moved.md\n@@\n-x\n+' + 'x' * 25 + '\n')))
        self.assertTrue(self.denied(self.patch('*** Add File: ordinary.md\n+small\n*** Add File: HANDOFF-large.md\n+' + 'x' * 25 + '\n')))

    def test_patch_malformed_fails_open(self):
        (self.cwd / 'HANDOFF-edit.md').write_text('a\n')
        self.assertFalse(self.denied(self.patch('*** Update File: HANDOFF-edit.md\n*** Unsupported\n')))
        self.assertFalse(self.denied(self.patch('*** Update File: HANDOFF-edit.md\n@@\n-missing\n+' + 'x' * 50 + '\n')))

    def test_rollout_uses_current_not_accumulated_and_no_cache_double_count(self):
        transcript = self.cwd / 'rollout.jsonl'
        records = [dict(type='session_meta', payload=dict(context_window=258400)),
                   dict(type='turn_context', payload=dict(model='gpt-6-sol')),
                   dict(type='event_msg', payload=dict(type='token_count', info=dict(
                       total_token_usage=dict(total_tokens=900000),
                       last_token_usage=dict(input_tokens=1000, cached_input_tokens=900, output_tokens=20,
                                             reasoning_output_tokens=10, total_tokens=1020)))),
                   dict(type='event_msg', payload=dict(type='token_count', info=None, rate_limits={}))]
        transcript.write_text(''.join(json.dumps(r) + '\n' for r in records))
        self.assertEqual(context_budget.context_tokens(transcript, True), 1020)
        records[2]['payload']['info']['last_token_usage'].pop('total_tokens')
        transcript.write_text(''.join(json.dumps(r) + '\n' for r in records))
        self.assertEqual(context_budget.context_tokens(transcript, True), 1020)
        with transcript.open('a') as f:
            f.write(json.dumps(dict(type='compacted', payload=dict(message='summary'))) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, True), 0)

    def test_native_token_usage_record_current_usage_reset_and_warning(self):
        transcript = self.cwd / 'native-rollout.jsonl'
        usage = dict(input_tokens=429141, cached_input_tokens=427904,
                     cache_write_input_tokens=0, output_tokens=7490,
                     reasoning_output_tokens=0, total_tokens=436631)
        record = dict(type='token_usage_record', payload=dict(usage=usage,
            turn_token_usage=dict(total_tokens=69502120),
            thread_token_usage=dict(total_tokens=69502120)))
        transcript.write_text(json.dumps(record) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, True), 436631)
        self.config(AGENT_HUB_CONTEXT_WARN=400000, AGENT_HUB_CONTEXT_BLOCK=500000)
        out = self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript))
        self.assertIn('Context budget: 436k', out['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        usage.pop('total_tokens')
        usage['reasoning_output_tokens'] = 7000  # component of output, never additive
        usage['cache_write_input_tokens'] = 90000  # component of input
        transcript.write_text(json.dumps(record) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, False), 436631)
        with transcript.open('a') as f:
            f.write(json.dumps(dict(type='compacted', payload={})) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, True), 0)
        accumulated_only = dict(type='token_usage_record', payload=dict(
            turn_token_usage=dict(total_tokens=69502120), thread_token_usage=dict(total_tokens=69502120)))
        with transcript.open('a') as f:
            f.write(json.dumps(accumulated_only) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, True), 0)
        with transcript.open('a') as f:
            f.write(json.dumps(record) + '\n')
        self.assertEqual(context_budget.context_tokens(transcript, True), 436631)

    def test_native_token_usage_window_defaults_and_explicit_override(self):
        self.config()
        transcript = self.cwd / 'native-window.jsonl'
        records = [dict(type='session_meta', payload=dict(context_window=200000)),
                   dict(type='token_usage_record', payload=dict(model_context_window=100000,
                        usage=dict(total_tokens=86000)))]
        transcript.write_text(''.join(json.dumps(r) + '\n' for r in records))
        self.assertEqual(context_budget.context_window(transcript), 100000)
        self.assertTrue(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        self.config(AGENT_HUB_CONTEXT_BLOCK=90000)
        self.assertFalse(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        records[-1]['payload'].pop('model_context_window')
        transcript.write_text(''.join(json.dumps(r) + '\n' for r in records))
        self.assertEqual(context_budget.context_window(transcript), 200000)

    def test_native_context_tools_and_handoff_escape(self):
        self.config(AGENT_HUB_CONTEXT_WARN=100, AGENT_HUB_CONTEXT_BLOCK=200)
        transcript = self.cwd / 'rollout.jsonl'
        transcript.write_text(json.dumps(dict(type='event_msg', payload=dict(type='token_count', info=dict(
            total_token_usage=dict(total_tokens=900000), last_token_usage=dict(total_tokens=250))))) + '\n')
        for tool in ('spawn_agent', 'collaboration.spawn_agent', 'send_input', 'collaboration.send_message'):
            out = self.hook('context_budget.py', tool, {'message': 'work'}, transcript_path=str(transcript))
            self.assertTrue(self.denied(out), tool)
        out = self.hook('context_budget.py', 'spawn_agent', {'message': 'handoff-ok: takeover'}, transcript_path=str(transcript))
        self.assertFalse(self.denied(out))
        self.assertFalse(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'ls'}, transcript_path=str(transcript))))

    def budget_hub(self, tokens=510000):
        self.config(AGENT_HUB_AUTO_HANDOFF='on')
        stage = Path(self.env['AGENT_HUB_HOME']) / 'stage-a'
        stage.mkdir()
        (stage / 'roles.json').write_text(json.dumps({'roles': {'hub': {'session': 'codex-own'}}}))
        (stage / 'config.json').write_text(json.dumps({'AGENT_HUB_CONTEXT_WARN': 350000,
                                                      'AGENT_HUB_CONTEXT_BLOCK': 500000}))
        transcript = self.cwd / 'budget.jsonl'
        transcript.write_text(json.dumps(dict(type='token_usage_record', payload=dict(
            model_context_window=828400, usage=dict(total_tokens=tokens)))) + '\n')
        return stage, transcript

    def fresh_budget(self):
        from datetime import datetime, timezone
        stage, transcript = self.budget_hub(375000)
        record = json.loads(transcript.read_text())
        record['timestamp'] = datetime.now(timezone.utc).isoformat()
        transcript.write_text(json.dumps(record) + '\n')
        self.env.update(CODEX_THREAD_ID='codex-own', CODEX_HOME=str(self.home / 'codex'))
        sessions = self.home / 'codex/sessions'
        sessions.mkdir(parents=True)
        settings = dict(model='fixture-model', effort='high', sandbox_policy={'type': 'danger-full-access'},
                        approval_policy='never')
        (sessions / 'rollout-settings.jsonl').write_text(json.dumps(dict(type='session_meta', payload={'id': 'codex-own'}))
            + '\n' + json.dumps(dict(type='turn_context', payload=settings)) + '\n')
        transcript.write_text((sessions / 'rollout-settings.jsonl').read_text() + transcript.read_text())
        return stage, transcript

    def test_grilling_preserves_due_without_stop_continuation_until_owner_ceiling(self):
        stage, transcript = self.fresh_budget()
        # First latch a real obligation; beginning a grilling must suspend, never erase it.
        self.hook('context_budget.py', event='PostToolUse', transcript_path=str(transcript))
        self.assertTrue(self.directive_state(stage)['handoff_due'])
        self.hook('context_budget.py', 'Skill', {'skill': 'fixture:grilling'},
                  event='PostToolUse', transcript_path=str(transcript))
        self.assertFalse(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'git status'},
                                              transcript_path=str(transcript))))
        self.assertEqual(self.stop(transcript), {})
        self.assertEqual(self.directive_state(stage)['stop_continuations'], 0)
        self.assertTrue(self.directive_state(stage)['handoff_due'])
        self.env['AGENT_HUB_GRILLING_CEILING'] = '360000'
        out = self.hook('context_budget.py', 'Bash', {'command': 'git status'}, transcript_path=str(transcript))
        self.assertTrue(self.denied(out))
        reason = out['hookSpecificOutput']['permissionDecisionReason']
        self.assertIn('carry the grilling', reason)
        self.assertIn('--owner-asked', reason)
        self.assertEqual(self.stop(transcript), {}, 'the ceiling never grants Stop authority to dispatch')
        self.assertEqual(self.directive_state(stage)['stop_continuations'], 0)
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_grilling_ceiling_below_warn_still_gates_without_automatic_dispatch(self):
        stage, transcript = self.fresh_budget()
        record = self.usage_record(transcript)
        record['payload']['usage']['total_tokens'] = 100000
        self.replace_usage(transcript, record)
        self.env['AGENT_HUB_GRILLING_CEILING'] = '90000'
        self.hook('context_budget.py', 'Skill', {'skill': 'fixture:grilling'},
                  event='PostToolUse', transcript_path=str(transcript))
        out = self.hook('context_budget.py', 'Bash', {'command': 'git status'}, transcript_path=str(transcript))
        self.assertTrue(self.denied(out))
        self.assertIn('carry the grilling', out['hookSpecificOutput']['permissionDecisionReason'])
        self.assertIn('at or above the 90k grilling ceiling', out['hookSpecificOutput']['permissionDecisionReason'])
        self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript))
        self.assertEqual(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)), {})
        self.assertEqual(self.stop(transcript), {})
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def usage_record(self, transcript):
        return next(json.loads(line) for line in transcript.read_text().splitlines()
                    if json.loads(line).get('type') == 'token_usage_record')

    def replace_usage(self, transcript, record):
        records = [json.loads(line) for line in transcript.read_text().splitlines()]
        transcript.write_text(''.join(json.dumps(record if row.get('type') == 'token_usage_record' else row) + '\n'
                                      for row in records))

    def stop(self, transcript, **fields):
        fields.setdefault('last_assistant_message', context_budget.READY_MARKER)
        return self.hook('context_budget.py', event='Stop', transcript_path=str(transcript), **fields)

    def raw_codex_budget(self):
        stage, transcript = self.fresh_budget()
        settings = self.home / 'codex/sessions/rollout-settings.jsonl'
        # An isolated app-server supplies the actual event session/transcript, not these env markers.
        settings.unlink()
        self.env.pop('AGENT_HUB_ENGINE')
        self.env.pop('CODEX_THREAD_ID')
        return stage, transcript

    def test_stop_raw_codex_payload_without_engine_env_uses_exact_rollout_settings(self):
        stage, transcript = self.raw_codex_budget()
        first = self.stop(transcript, last_assistant_message='I will save this for later.', permission_mode=None)
        self.assertEqual(first['decision'], 'block')
        self.assertIn('--engine codex', first['reason'])
        self.assertIn('--model fixture-model', first['reason'])
        self.assertIn('--effort high', first['reason'])
        self.assertNotIn('--surface desktop', first['reason'])
        self.assertFalse((stage / 'auto-handoff.json').exists())
        self.assertEqual(self.stop(transcript, stop_hook_active=True), {})
        self.pending(stage)
        self.assertEqual(self.stop(transcript, stop_hook_active=True)['decision'], 'block')
        self.pending(stage, 'bound', id='22222222-2222-4222-8222-222222222222')
        self.assertEqual(self.stop(transcript, stop_hook_active=True), {})
        self.assertEqual(self.directive_state(stage)['stop_continuations'], 2)

    def test_stop_raw_codex_identity_and_noncodex_boundaries(self):
        stage, transcript = self.raw_codex_budget()
        original = transcript.read_text()
        # Foreign session metadata cannot be used for this event, even with compatible settings/usage.
        transcript.write_text(original.replace('codex-own', 'other-session'))
        self.assertEqual(self.stop(transcript), {})
        transcript.write_text(original)
        self.env['CODEX_THREAD_ID'] = 'another-current-session'
        self.assertEqual(self.stop(transcript), {})
        self.env.pop('CODEX_THREAD_ID')
        # An explicitly Claude caller and an unregistered caller retain their no-op Stop boundary.
        self.env['AGENT_HUB_ENGINE'] = 'claude'
        self.assertEqual(self.stop(transcript), {})
        self.env.pop('AGENT_HUB_ENGINE')
        (stage / 'roles.json').write_text(json.dumps({'roles': {'hub': {'session': 'other-session'}}}))
        self.assertEqual(self.stop(transcript), {})
        (stage / 'roles.json').write_text(json.dumps({'roles': {'hub': {'session': 'codex-own'}}}))
        transcript.write_text(''.join(line + '\n' for line in original.splitlines()
                                     if json.loads(line)['type'] != 'session_meta'))
        self.assertEqual(self.stop(transcript), {})

    def test_stop_raw_codex_missing_current_settings_never_inherits_old_or_foreign(self):
        stage, transcript = self.raw_codex_budget()
        with transcript.open('a', encoding='utf-8') as handle:
            handle.write(json.dumps(dict(type='turn_context', payload={})) + '\n')
        self.assertEqual(self.stop(transcript), {})
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_explicit_current_rollout_missing_context_never_uses_stale_same_session_index(self):
        stage, transcript = self.fresh_budget()
        stale = self.home / 'codex/sessions/rollout-settings.jsonl'
        stale.write_text(stale.read_text().replace('fixture-model', 'old-model'))
        original = transcript.read_text()
        context_budget.hubcore()
        import autopilot
        with patch.dict(os.environ, self.env, clear=True), \
             patch.object(autopilot.codex_rollouts, 'INDEX', autopilot.codex_rollouts.Index()):
            # The normal CLI route really can discover that same-id older rollout.
            self.assertEqual(autopilot.codex_context()['model'], 'old-model')
            missing_context = ''.join(line + '\n' for line in original.splitlines()
                                      if json.loads(line).get('type') != 'turn_context')
            for body in (missing_context,
                         original.replace('codex-own', 'foreign-session'),
                         ''.join(original.splitlines(keepends=True)[1:]),
                         '{invalid header\n' + original,
                         original + json.dumps(dict(type='turn_context', payload={})) + '\n'):
                with self.subTest(body=body[:60]):
                    transcript.write_text(body)
                    with patch.object(autopilot.codex_rollouts.INDEX, 'session',
                                      side_effect=AssertionError('explicit rollout must not consult index')):
                        self.assertEqual(autopilot.codex_context('codex-own', transcript), {})
                    self.assertEqual(self.stop(transcript), {})
                    self.assertEqual(self.directive_state(stage)['stop_continuations'], 0)
            self.assertFalse((stage / 'auto-handoff.json').exists())

    def pending(self, stage, phase='prepared', **fields):
        pending = dict(surface='desktop', predecessor='codex-own', request_id='request-one', phase=phase)
        pending.update(fields)
        (stage / 'auto-handoff.json').write_text(json.dumps({'chain': 1, 'pending': pending}))

    def test_first_warn_latches_across_reset_missing_decreased_usage_and_work(self):
        stage, transcript = self.budget_hub(350000)
        self.assertTrue(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'git status'},
                                            transcript_path=str(transcript))))
        self.assertFalse(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'hub handoff --stage stage-a'},
                                             transcript_path=str(transcript))))
        for record in ('', json.dumps(dict(type='compacted')), json.dumps(dict(type='token_usage_record',
                       payload={'usage': {'total_tokens': 100}}))):
            transcript.write_text(record + '\n')
            reply = self.hook('context_budget.py', event='UserPromptSubmit', prompt='new human detail',
                              transcript_path=str(transcript))
            self.assertIn('Hand over now', reply['hookSpecificOutput']['additionalContext'])
            self.assertNotIn('decision', reply)
            self.assertTrue(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'git status'},
                                                transcript_path=str(transcript))))
        state = json.loads((stage.parent / '.state/context-budget/codex-own.json').read_text())
        self.assertEqual(state['due_since_tokens'], 350000)
        self.assertTrue(state['handoff_due'])
        self.config(AGENT_HUB_AUTO_HANDOFF='off')
        self.assertFalse(self.hook('context_budget.py', 'Bash', {'command': 'git status'}, transcript_path=str(transcript)))
        self.config(AGENT_HUB_AUTO_HANDOFF='on')
        self.assertFalse(self.hook('context_budget.py', 'Bash', {'command': 'git status'},
                                  agent_id='child', transcript_path=str(transcript)))
        (stage / 'roles.json').write_text(json.dumps({'roles': {'hub': {'session': 'successor'}}}))
        self.assertFalse(self.hook('context_budget.py', 'Bash', {'command': 'git status'}, transcript_path=str(transcript)))

    def append_human(self, transcript, text, response=False):
        record = (dict(type='response_item', payload=dict(role='user', content=[dict(type='input_text', text=text)]))
                  if response else dict(type='event_msg', payload=dict(type='user_message', message=text)))
        with transcript.open('a', encoding='utf-8') as handle:
            handle.write(json.dumps(record) + '\n')

    def directive_state(self, stage):
        return json.loads((stage.parent / '.state/context-budget/codex-own.json').read_text(encoding='utf-8'))

    def test_stop_transfer_revocation_survives_neutral_prompt_and_missing_history(self):
        stage, transcript = self.fresh_budget()
        original = transcript.read_text()
        self.append_human(transcript, 'Do not transfer this stage.')
        self.assertEqual(self.stop(transcript), {})
        self.append_human(transcript, 'What is the current state?', response=True)
        self.hook('context_budget.py', event='UserPromptSubmit', prompt='What is the current state?',
                  transcript_path=str(transcript))
        self.assertEqual(self.stop(transcript), {})
        self.assertTrue(self.directive_state(stage)['transfer_stop'])
        self.hook('context_budget.py', event='UserPromptSubmit', prompt="What does 'Resume the handoff' mean?",
                  transcript_path=str(transcript))
        self.assertEqual(self.stop(transcript), {})
        # A generated hook prompt cannot revoke the owner's stop or reset the chain.
        self.append_human(transcript, '<hook_prompt>Resume the handoff.</hook_prompt>', response=True)
        self.hook('context_budget.py', event='UserPromptSubmit',
                  prompt=context_budget.CONTINUATION_MARKER + ' Resume the handoff.', transcript_path=str(transcript))
        self.assertEqual(self.stop(transcript), {})
        self.hook('context_budget.py', event='UserPromptSubmit',
                  prompt=context_budget.READY_MARKER + ' Resume the handoff.', transcript_path=str(transcript))
        self.assertTrue(self.directive_state(stage)['transfer_stop'])
        low = next(json.loads(line) for line in original.splitlines()
                   if json.loads(line).get('type') == 'token_usage_record')
        low['payload']['usage']['total_tokens'] = 100000
        transcript.write_text(original)
        self.replace_usage(transcript, low)
        self.assertEqual(self.stop(transcript), {})
        self.assertTrue(self.directive_state(stage)['transfer_stop'])
        transcript.write_text(original)
        # Resumption clears only the negative directive; no request or human grant is fabricated.
        self.hook('context_budget.py', event='UserPromptSubmit', prompt='Resume the handoff.', transcript_path=str(transcript))
        self.assertFalse(self.directive_state(stage)['transfer_stop'])
        self.assertEqual(self.stop(transcript)['decision'], 'block')
        self.assertFalse((stage / 'auto-handoff.json').exists())
        self.assertNotIn('Do not transfer', json.dumps(self.directive_state(stage)))

    def test_stop_polite_transfer_stop_and_replayed_old_stop_after_resumption(self):
        stage, transcript = self.fresh_budget()
        self.append_human(transcript, 'Please stop the handoff.')
        self.assertEqual(self.stop(transcript), {})
        self.hook('context_budget.py', event='UserPromptSubmit', prompt='Resume the handoff.', transcript_path=str(transcript))
        # The rollout may still end at the older, already-observed stop while this prompt is being appended.
        self.assertEqual(self.stop(transcript)['decision'], 'block')
        self.assertFalse(self.directive_state(stage)['transfer_stop'])
        self.append_human(transcript, 'Please stop the handoff.')
        self.assertEqual(self.stop(transcript), {})
        self.assertTrue(self.directive_state(stage)['transfer_stop'])

    def test_stop_global_stop_sentence_before_neutral_question_remains_blocker(self):
        stage, transcript = self.fresh_budget()
        original = transcript.read_text()
        for text in ('Stop now. What is the current state?',
                     'Please stop. What is the current state?',
                     'What is the current state?\nStop now.',
                     'Стоп. Каково текущее состояние?',
                     'Пожалуйста, остановись; каково текущее состояние?'):
            with self.subTest(text=text):
                transcript.write_text(original)
                (stage.parent / '.state/context-budget/codex-own.json').unlink(missing_ok=True)
                self.append_human(transcript, text)
                self.assertEqual(self.stop(transcript, last_assistant_message='I have stopped; here is the current state.'), {})
                self.assertTrue(self.directive_state(stage)['transfer_stop'])
                self.assertEqual(self.directive_state(stage)['stop_continuations'], 0)
                self.append_human(transcript, 'What is the current state?', response=True)
                self.assertEqual(self.stop(transcript), {})
                self.assertTrue(self.directive_state(stage)['transfer_stop'])
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_stop_implementation_pause_readonly_english_preserves_transfer(self):
        stage, transcript = self.fresh_budget()
        self.append_human(transcript, 'Do not continue implementation; continue our read-only discussion and hand over when needed.')
        self.append_human(transcript, 'Continue our read-only discussion of the current state.')
        self.assertEqual(self.stop(transcript, last_assistant_message='Implementation remains paused; checking the existing transfer grant.')['decision'], 'block')
        self.assertNotIn('transfer_stop', self.directive_state(stage))
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_stop_implementation_pause_readonly_russian_preserves_transfer(self):
        stage, transcript = self.fresh_budget()
        self.append_human(transcript, 'Не продолжай реализацию; продолжай обсуждение только для чтения и передавай смену при необходимости.')
        self.append_human(transcript, 'Продолжай обсуждение состояния, реализация остаётся на паузе.')
        self.assertEqual(self.stop(transcript)['decision'], 'block')
        self.assertNotIn('transfer_stop', self.directive_state(stage))
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_stop_russian_revocation_and_global_stop_require_explicit_resumption(self):
        stage, transcript = self.fresh_budget()
        self.append_human(transcript, 'Не передавай эту смену.')
        self.assertEqual(self.stop(transcript), {})
        self.append_human(transcript, 'Каково текущее состояние?', response=True)
        self.assertEqual(self.stop(transcript), {})
        self.hook('context_budget.py', event='UserPromptSubmit', prompt='Возобнови передачу.', transcript_path=str(transcript))
        self.assertFalse(self.directive_state(stage)['transfer_stop'])
        self.append_human(transcript, 'Останови всю работу.')
        self.assertEqual(self.stop(transcript), {})
        self.assertTrue(self.directive_state(stage)['transfer_stop'])

    def test_transfer_directive_scope_controls_and_stable_source_positions(self):
        for text in ('Do not continue any work.', 'Do not continue any activity.',
                     'Please stop the handoff.', 'Stop all activity.', 'Не продолжай никакую деятельность.',
                     'Ничего больше не делай.', 'Пожалуйста, остановись.'):
            self.assertIs(context_budget.transfer_directive(text), True, text)
        for text in ('Do not continue implementation; continue our read-only discussion and hand over when needed.',
                     'Не продолжай реализацию; продолжай обсуждение и передавай смену при необходимости.'):
            self.assertIsNone(context_budget.transfer_directive(text), text)
        _, transcript = self.fresh_budget()
        self.append_human(transcript, 'Please stop the handoff.')
        with patch.object(context_budget, 'CHUNK', 37):
            before = list(context_budget.transcript_lines(transcript, offsets=True))
            self.append_human(transcript, 'Resume the handoff.')
            after = list(context_budget.transcript_lines(transcript, offsets=True))
        self.assertEqual(after[1:], before)
        raw = transcript.read_bytes()
        for line, offset in after:
            self.assertEqual(raw[offset:offset + len(line)], line)

    def test_stop_english_all_activity_stop_and_unknown_directive_history(self):
        stage, transcript = self.fresh_budget()
        self.append_human(transcript, 'Stop all activity.')
        self.assertEqual(self.stop(transcript), {})
        self.assertTrue(self.directive_state(stage)['transfer_stop'])
        with transcript.open('a') as handle:
            handle.write('{torn private directive\n')
        self.assertEqual(self.stop(transcript), {})

    def test_real_producers_write_lifecycle_events_without_private_bodies(self):
        stage, transcript = self.fresh_budget()
        sentinel = 'PRIVATE_PRODUCER_SENTINEL_auth_prompt_tool_config'
        self.hook('context_budget.py', event='UserPromptSubmit', prompt=sentinel,
                  turn_id='turn-one', transcript_path=str(transcript))
        self.assertTrue(self.denied(self.hook('context_budget.py', 'Bash', {'command': sentinel}, transcript_path=str(transcript))))
        self.assertEqual(self.stop(transcript)['decision'], 'block')
        pending = dict(surface='desktop', predecessor='codex-own', predecessor_n=1, n=2,
                       request_id='request-one', phase='prepared', create_args={'prompt': sentinel},
                       requested={'private_config': sentinel})
        (stage / 'auto-handoff.json').write_text(json.dumps({'chain': 1, 'pending': pending}))
        self.hook('context_budget.py', event='PostToolUse', transcript_path=str(transcript))
        # Exercise actual autopilot canonical persistence and verified-status producers, with no launcher/API call.
        program = """import json,sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import autopilot as ap
stage='stage-a'
data=ap.load_state(stage)
ap.save_state(stage,data)
p=data['pending']
p.update(phase='taken-over',id='22222222-2222-4222-8222-222222222222',cwd=sys.argv[2],taken_over='verified-fixture')
ap.hc.atomic_write(ap.hc.root()/stage/'roles.json',json.dumps({'roles':{'hub':{'session':p['id'],'tag':'hub-2','surface':'desktop','cwd':p['cwd']}}}))
ap.save_state(stage,data)
raise SystemExit(ap.desktop_status(stage,p['request_id'],verified=True))
"""
        run = subprocess.run([sys.executable, '-c', program, str(ROOT / 'bin'), str(self.cwd)],
                             capture_output=True, text=True, env=self.env, timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn('diagnostics unavailable', run.stderr)
        log = stage.parent / '.state/handoff-events/codex-own.jsonl'
        raw = log.read_text(encoding='utf-8')
        rows = [json.loads(line) for line in raw.splitlines()]
        by_event = {row['event']: row for row in rows}
        expected = {'due_latched': 'first_warn', 'gate_denied': 'handoff_due',
                    'continuation_requested': 'handoff_only', 'progress': 'canonical_progress',
                    'takeover_verified': 'exact_takeover'}
        for event, reason in expected.items():
            self.assertEqual(by_event[event]['reason'], reason, (event, rows))
            self.assertEqual(by_event[event]['stage'], 'stage-a')
            self.assertEqual(by_event[event]['session_id'], 'codex-own')
        self.assertEqual(by_event['due_latched']['turn_id'], 'turn-one')
        self.assertEqual(by_event['due_latched']['due_since_tokens'], 375000)
        self.assertNotIn('request_id', by_event['gate_denied'])
        self.assertNotIn('request_id', by_event['continuation_requested'])
        self.assertEqual(by_event['takeover_verified']['request_id'], 'request-one')
        self.assertEqual(by_event['takeover_verified']['phase'], 'taken-over')
        self.assertNotIn(sentinel, raw + run.stderr)

    def test_false_logger_result_is_visible_and_never_suppresses_reply_or_gate(self):
        stage, transcript = self.fresh_budget()
        context_budget.hubcore()
        import handoff_events
        for event, fields in [('UserPromptSubmit', dict(prompt='private prompt')), ('PreToolUse', dict(tool_name='Bash', tool_input={'command': 'private command'}))]:
            data = dict(session_id='codex-own', cwd=str(self.cwd), hook_event_name=event,
                        transcript_path=str(transcript), **fields)
            with patch.dict(os.environ, self.env, clear=True), patch('sys.stdin', io.StringIO(json.dumps(data))), \
                 patch('sys.stdout', new_callable=io.StringIO) as output, patch('sys.stderr', new_callable=io.StringIO) as errors, \
                 patch.object(handoff_events, 'emit_handoff_event', return_value=False):
                context_budget.main()
            result = json.loads(output.getvalue())
            self.assertTrue(result.get('hookSpecificOutput'))
            self.assertTrue(errors.getvalue())
            self.assertEqual(set(errors.getvalue().splitlines()), {'delamain: handoff diagnostics unavailable'})
            if event == 'PreToolUse':
                self.assertTrue(self.denied(result))
        import autopilot
        with patch.dict(os.environ, self.env, clear=True), patch('sys.stderr', new_callable=io.StringIO) as errors, \
             patch.object(handoff_events, 'emit_handoff_event', return_value=False):
            autopilot.handoff_event('stage-a', {'predecessor': 'codex-own'}, 'progress', reason='canonical_progress')
        self.assertEqual(errors.getvalue(), 'delamain: handoff diagnostics unavailable\n')
        class BrokenDiagnostics:
            def write(self, text):
                raise OSError('private diagnostic failure')
        with patch.dict(os.environ, self.env, clear=True), patch('sys.stdin', io.StringIO(json.dumps(data))), \
             patch('sys.stdout', new_callable=io.StringIO) as output, patch('sys.stderr', BrokenDiagnostics()), \
             patch.object(handoff_events, 'emit_handoff_event', return_value=False):
            context_budget.main()
        self.assertTrue(self.denied(json.loads(output.getvalue())))

    def test_stop_top_level_bounded_two_requires_exact_progress(self):
        stage, transcript = self.fresh_budget()
        first = self.stop(transcript)
        self.assertEqual(set(first), {'decision', 'reason'})
        self.assertEqual(first['decision'], 'block')
        self.assertTrue(first['reason'].startswith(context_budget.CONTINUATION_MARKER))
        self.assertEqual(self.stop(transcript, stop_hook_active=True), {})
        self.pending(stage)
        second = self.stop(transcript, stop_hook_active=True)
        self.assertEqual(second['decision'], 'block')
        self.pending(stage, 'bound', id='22222222-2222-4222-8222-222222222222')
        self.assertEqual(self.stop(transcript, stop_hook_active=True), {})
        state = json.loads((stage.parent / '.state/context-budget/codex-own.json').read_text())
        self.assertEqual(state['stop_continuations'], 2)
        self.assertEqual(state['request_id'], 'request-one')

    def test_stop_premature_final_without_request_gets_one_authority_check(self):
        stage, transcript = self.fresh_budget()
        first = self.stop(transcript, last_assistant_message='I will save this for later.')
        self.assertEqual(first['decision'], 'block')
        self.assertIn('Recheck the actual human grant', first['reason'])
        self.assertFalse((stage / 'auto-handoff.json').exists())
        self.assertEqual(self.stop(transcript, stop_hook_active=True,
                                  last_assistant_message='No further progress yet.'), {})

    def test_stop_zero_for_explicit_blocker_active_stale_missing_and_settings(self):
        stage, transcript = self.fresh_budget()
        self.assertEqual(self.stop(transcript, last_assistant_message='Authority absent; ask once'), {})
        self.assertEqual(self.stop(transcript, last_assistant_message='Owner stopped or revoked transfer'), {})
        original = transcript.read_text()
        with transcript.open('a') as handle:
            handle.write(json.dumps(dict(type='event_msg', payload=dict(type='user_message', message='Stop now'))) + '\n')
        self.assertEqual(self.stop(transcript, last_assistant_message='I will hand over.'), {})
        transcript.write_text(original)
        self.assertEqual(self.stop(transcript, stop_hook_active=True), {})
        record = self.usage_record(transcript)
        record['timestamp'] = '2000-01-01T00:00:00Z'
        self.replace_usage(transcript, record)
        self.assertEqual(self.stop(transcript), {})
        record.pop('timestamp'); self.replace_usage(transcript, record)
        self.assertEqual(self.stop(transcript), {})
        from datetime import datetime, timezone
        record['timestamp'] = datetime.now(timezone.utc).isoformat()
        self.replace_usage(transcript, record)
        (self.home / 'codex/sessions/rollout-settings.jsonl').unlink()
        transcript.write_text(''.join(line + '\n' for line in transcript.read_text().splitlines()
                                     if json.loads(line).get('type') != 'turn_context'))
        self.assertEqual(self.stop(transcript), {})
        record['payload']['usage']['total_tokens'] = 490000
        self.replace_usage(transcript, record)
        self.assertEqual(self.stop(transcript), {})

    def test_stop_wrong_request_identity_and_uncertain_never_advance(self):
        stage, transcript = self.fresh_budget()
        self.pending(stage)
        self.assertEqual(self.stop(transcript)['decision'], 'block')
        for fields in (dict(predecessor='another-hub'), dict(request_id='wrong-request'),
                       dict(phase='dispatching'), dict(phase='uncertain'),
                       dict(phase='bound', id='wrong-uuid'), dict(phase='bound', id='codex-own'),
                       dict(phase='prepared', last_error='secret-private-error')):
            self.pending(stage, **fields)
            self.assertEqual(self.stop(transcript, stop_hook_active=True), {}, fields)
        self.assertNotIn('secret-private-error', (stage.parent / '.state/context-budget/codex-own.json').read_text())

    def test_stop_concurrent_reservation_and_internal_prompt_preserve_chain(self):
        from concurrent.futures import ThreadPoolExecutor
        stage, transcript = self.fresh_budget()
        (stage / 'auto-handoff.json').write_text(json.dumps({'chain': 4, 'pending': None}))
        with ThreadPoolExecutor(max_workers=6) as pool:
            outputs = list(pool.map(lambda _: self.stop(transcript), range(6)))
        self.assertEqual(sum(o.get('decision') == 'block' for o in outputs), 1)
        self.hook('context_budget.py', event='UserPromptSubmit', prompt=context_budget.CONTINUATION_MARKER,
                  transcript_path=str(transcript))
        self.assertEqual(json.loads((stage / 'auto-handoff.json').read_text())['chain'], 4)

    def test_stop_counter_io_failure_never_requests_continuation(self):
        stage, transcript = self.fresh_budget()
        self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript))
        data = dict(session_id='codex-own', cwd=str(self.cwd), hook_event_name='Stop',
                    last_assistant_message=context_budget.READY_MARKER, transcript_path=str(transcript))
        with patch.dict(os.environ, self.env, clear=True), patch('sys.stdin', io.StringIO(json.dumps(data))), \
             patch('sys.stdout', new_callable=io.StringIO) as output, patch.object(context_budget, 'save_state', return_value=False):
            context_budget.main()
        self.assertEqual(json.loads(output.getvalue()), {})

    def test_budget_repeated_prompts_and_settings_refusal_still_reply(self):
        stage, transcript = self.budget_hub(375000)
        for prompt in ('Please finish the original task', 'And preserve this new detail'):
            out = self.hook('context_budget.py', event='UserPromptSubmit', prompt=prompt,
                            transcript_path=str(transcript))
            text = out['hookSpecificOutput']['additionalContext']
            self.assertIn('Acknowledge the latest human message first', text)
            self.assertIn('Hand over now', text)
            self.assertIn('Preserve the latest owner input', text)
            self.assertNotIn('next quiet point', text)
            self.assertNotIn('continue', out)
            self.assertNotIn('permissionDecision', out['hookSpecificOutput'])
        self.assertFalse(self.hook('context_budget.py', event='PostToolUse', transcript_path=str(transcript)))
        # An invalid effort raised inside plan() used to erase the entire instruction.
        self.config(AGENT_HUB_AUTO_HANDOFF='on', AGENT_HUB_SUCCESSOR_EFFORT='invalid-effort')
        out = self.hook('context_budget.py', event='UserPromptSubmit', prompt='Please answer me',
                        transcript_path=str(transcript))
        text = out['hookSpecificOutput']['additionalContext']
        self.assertIn('Acknowledge the latest human message first', text)
        self.assertIn('settings could not be resolved (UsageError)', text)
        self.assertIn('Explain the settings refusal', text)
        self.assertIn('do not guess model/effort/access', text)
        self.assertNotIn('continue', out)
        self.assertFalse((stage / 'auto-handoff.json').exists(), 'hook must not fabricate a native request')

    def test_budget_null_or_missing_usage_is_unknown_not_a_false_handoff(self):
        stage, transcript = self.budget_hub()
        for fields in ({'transcript_path': None}, {'transcript_path': str(self.cwd / 'missing.jsonl')}):
            out = self.hook('context_budget.py', event='UserPromptSubmit', prompt='Please answer', **fields)
            text = out['hookSpecificOutput']['additionalContext']
            self.assertIn('current usage is unavailable', text)
            self.assertIn('Acknowledge the latest human message first', text)
            self.assertNotIn('Hand over now', text)
            self.assertNotIn('continue', out)
        transcript.write_text('{torn log\n')
        out = self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript))
        self.assertIn('current usage is unavailable', out['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=None,
                                   session_id='another-session'))
        self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_budget_handoff_reads_pass_but_ordinary_work_stays_closed(self):
        _, transcript = self.budget_hub()
        self.env['PATH'] = str(ROOT / 'bin') + os.pathsep + self.env.get('PATH', '')
        self.env['AGENT_HUB_NATIVE_CODEX_PATHS'] = '1'
        allowed = ('hub effort --json', 'hub effort --session actual', 'hub home --json',
                   'hub home --cwd /repo', 'ask allow --list --stage stage-a',
                   'ask search handoff --stage stage-a', 'ask digest --stage stage-a',
                   'ask list --stage stage-a --all', 'cat /h/HANDOFF-a.md',
                   'hub desktop-status --stage stage-a --request actual --verified')
        denied = ('hub home migrate --apply', 'hub effort --unknown',
                  'ask allow --list --words forged', 'ask close Q-1 --answer yes',
                  'path --linux /x /extra', 'cat /h/config.json', 'cat /h/HANDOFF-a.md /etc/passwd',
                  'Get-Content -Path /h/HANDOFF-*.md', 'cat /h/HANDOFF-a.md | sh',
                  'hub effort; git status', 'path --linux $(whoami)', 'rg handoff /h',
                  'sed -n 1p /h/HANDOFF-a.md', 'git status # handoff-ok')
        for command in allowed + denied:
            out = self.hook('context_budget.py', 'Bash', {'command': command}, transcript_path=str(transcript))
            self.assertEqual(self.denied(out), command in denied, command)
        out = self.hook('context_budget.py', 'Edit', {'file_path': '/repo/work.py'}, transcript_path=str(transcript))
        self.assertTrue(self.denied(out))
        out = self.hook('context_budget.py', 'Read', {'file_path': '/plugin/templates/HANDOFF-template.md'},
                        transcript_path=str(transcript))
        self.assertFalse(self.denied(out))

    def test_budget_unreadable_or_disappearing_rollout_still_replies(self):
        stage, transcript = self.budget_hub()
        original = transcript.read_bytes()
        real_open = open
        # Exercise actual scanner opens: first open is usage, second is the window read.
        for failed_open in (1, 2):
            for failure in ('permission', 'disappeared'):
                with self.subTest(open=failed_open, failure=failure):
                    transcript.write_bytes(original)
                    calls = 0

                    def observed_open(path, *args, **kwargs):
                        nonlocal calls
                        if Path(path) == transcript:
                            calls += 1
                            if calls == failed_open:
                                if failure == 'permission':
                                    raise PermissionError('fixture cannot read rollout')
                                transcript.unlink()  # after the real is_file() succeeded
                        return real_open(path, *args, **kwargs)

                    data = dict(session_id='codex-own', cwd=str(self.cwd), hook_event_name='UserPromptSubmit',
                                transcript_path=str(transcript), prompt='Preserve this latest owner input')
                    output = io.StringIO()
                    with patch.dict(os.environ, self.env, clear=True), patch('sys.stdin', io.StringIO(json.dumps(data))), \
                            patch('sys.stdout', output), patch('builtins.open', side_effect=observed_open):
                        context_budget.main()
                    out = json.loads(output.getvalue())
                    text = out['hookSpecificOutput']['additionalContext']
                    self.assertIn('Acknowledge the latest human message first', text)
                    if failed_open == 1:
                        self.assertIn('current usage is unavailable', text)
                        self.assertIn('Save that pending input and a checkpoint', text)
                        self.assertIn('Do not compact or stop without replying', text)
                        self.assertNotIn('Hand over now', text)
                    else:
                        self.assertIn('Hand over now', text)
                        self.assertNotIn('current usage is unavailable', text)
                        # Known 510k usage still crosses the private stage's explicit 500k block.
                        transcript.write_bytes(original)
                        calls = 0
                        data.update(hook_event_name='PreToolUse', tool_name='Bash',
                                    tool_input={'command': 'git status'})
                        gated = io.StringIO()
                        with patch.dict(os.environ, self.env, clear=True), patch('sys.stdin', io.StringIO(json.dumps(data))), \
                                patch('sys.stdout', gated), patch('builtins.open', side_effect=observed_open):
                            context_budget.main()
                        denial = json.loads(gated.getvalue())
                        self.assertTrue(self.denied(denial))
                        self.assertIn('Hand over now', denial['hookSpecificOutput']['permissionDecisionReason'])
                    self.assertNotIn('continue', out)
                    self.assertNotIn('permissionDecision', out['hookSpecificOutput'])
                    self.assertFalse((stage / 'auto-handoff.json').exists())

    def test_budget_read_commands_require_trusted_resolution_without_overrides(self):
        _, transcript = self.budget_hub()
        shadow = self.cwd / 'shadow'
        shadow.mkdir()
        for name in ('cat', 'ask', 'hub', 'path', 'Get-Content'):
            executable = shadow / name
            executable.write_text('#!/bin/sh\nexit 99\n')
            executable.chmod(0o755)
        clean_path = str(ROOT / 'bin') + os.pathsep + self.env.get('PATH', '')
        self.env['PATH'] = clean_path
        self.env['AGENT_HUB_NATIVE_CODEX_PATHS'] = '1'
        queries = ('cat /h/HANDOFF-a.md', 'ask list --stage stage-a', 'hub effort --json',
                   'hub home --json', 'path --linux C:/h/HANDOFF-a.md',
                   'Get-Content -LiteralPath C:/h/HANDOFF-a.md')
        denied = [str(shadow / query) for query in queries] + list(queries[4:])
        for query in queries:
            denied.extend((f'PATH={shadow}:$PATH {query}', f'PATH={shadow}; {query}',
                           f'LD_PRELOAD=/tmp/override.so {query}', f'HOME=/tmp {query}'))
        denied.extend(('AGENT_HUB_NATIVE_CODEX_PATHS=1 Get-Content -LiteralPath C:/h/HANDOFF-a.md',
                       'AGENT_HUB_NATIVE_CODEX_PATHS=1; Get-Content -LiteralPath C:/h/HANDOFF-a.md',
                       'alias cat=/tmp/cat; cat /h/HANDOFF-a.md',
                       'cat() { jlog work; }; cat /h/HANDOFF-a.md'))
        for command in denied:
            out = self.hook('context_budget.py', 'Bash', {'command': command}, transcript_path=str(transcript))
            self.assertTrue(self.denied(out), command)
        # Real inherited PATH resolution matters even when the command text has no override.
        self.env['PATH'] = str(shadow) + os.pathsep + clean_path
        for command in queries[:4]:
            out = self.hook('context_budget.py', 'Bash', {'command': command}, transcript_path=str(transcript))
            self.assertTrue(self.denied(out), command)
        # Absolute trusted commands remain available despite the shadowing PATH.
        for command in ('/bin/cat /h/HANDOFF-a.md', '/usr/bin/cat /h/HANDOFF-a.md',
                        f'{shlex.quote(str(ROOT / "bin/ask"))} list --stage stage-a',
                        f'{shlex.quote(str(ROOT / "bin/hub"))} effort --json'):
            out = self.hook('context_budget.py', 'Bash', {'command': command}, transcript_path=str(transcript))
            self.assertFalse(self.denied(out), command)
        del self.env['AGENT_HUB_NATIVE_CODEX_PATHS']
        for command in queries[4:]:
            out = self.hook('context_budget.py', 'Bash', {'command': command}, transcript_path=str(transcript))
            self.assertTrue(self.denied(out), command)

    def test_budget_stage_policy_is_private_and_invalid_values_fall_through(self):
        stage, transcript = self.budget_hub(375000)
        self.config(AGENT_HUB_AUTO_HANDOFF='on', AGENT_HUB_CONTEXT_WARN=400000,
                    AGENT_HUB_CONTEXT_BLOCK=550000)
        other = stage.parent / 'stage-b'
        other.mkdir()
        (other / 'roles.json').write_text(json.dumps({'roles': {'hub': {'session': 'other-hub'}}}))
        self.assertTrue(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)))
        self.assertFalse(self.hook('context_budget.py', event='UserPromptSubmit', session_id='other-hub',
                                   transcript_path=str(transcript)))
        self.env['AGENT_HUB_CONTEXT_WARN'] = '450000'
        self.assertFalse(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)))
        self.env['AGENT_HUB_CONTEXT_WARN'] = 'invalid'
        self.assertTrue(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)))
        # This helper must not turn stage config into general hub-wide authority.
        (stage / 'config.json').write_text(json.dumps({'AGENT_HUB_CONTEXT_WARN': 350000,
            'AGENT_HUB_AUTO_HANDOFF': 'off', 'AGENT_HUB_CONTEXT_BLOCK_TOOLS': []}))
        self.assertTrue(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        transcript.write_text(json.dumps(dict(type='token_usage_record', payload=dict(
            usage=dict(total_tokens=560000)))) + '\n')
        self.assertTrue(self.denied(self.hook('context_budget.py', 'Bash', {'command': 'git status'},
                                              transcript_path=str(transcript))))
        for invalid in (0, -1, True, 3.5, 'oops', 2147483648, {'value': 350000}):
            (stage / 'config.json').write_text(json.dumps({'AGENT_HUB_CONTEXT_WARN': invalid}))
            transcript.write_text(json.dumps(dict(type='token_usage_record', payload=dict(
                usage=dict(total_tokens=375000)))) + '\n')
            self.assertFalse(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)),
                             str(invalid))

    def test_window_aware_defaults_and_explicit_overrides(self):
        self.config()
        transcript = self.cwd / 'rollout.jsonl'
        def usage(tokens):
            transcript.write_text(json.dumps(dict(type='event_msg', payload=dict(type='token_count', info=dict(
                model_context_window=100000, total_token_usage=dict(total_tokens=900000),
                last_token_usage=dict(total_tokens=tokens))))) + '\n')
        usage(59000)
        self.assertFalse(self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript)))
        usage(61000)
        out = self.hook('context_budget.py', event='UserPromptSubmit', transcript_path=str(transcript))
        self.assertIn('Context budget: 61k', out['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        usage(86000)
        self.assertTrue(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))
        self.config(AGENT_HUB_CONTEXT_BLOCK=90000)
        self.assertFalse(self.denied(self.hook('context_budget.py', 'spawn_agent', {}, transcript_path=str(transcript))))

    def test_delegation_injection_native_spawn_and_session_identity(self):
        self.config(AGENT_HUB_DELEGATION=True, AGENT_HUB_DELEGATION_DEFAULT=0)
        out = self.hook('delegation.py', event='SessionStart', args=('session-start',))
        self.assertIn('Delegation level 0/5', out['hookSpecificOutput']['additionalContext'])
        self.assertTrue(self.denied(self.hook('delegation.py', 'spawn_agent', {'message': 'work'}, args=('pre-tool',))))
        self.assertTrue(self.denied(self.hook('delegation.py', 'collaboration.spawn_agent', {'message': 'work'}, args=('pre-tool',))))
        self.assertFalse(self.denied(self.hook('delegation.py', 'update_plan', {}, args=('pre-tool',))))
        self.assertFalse(self.hook('delegation.py', event='UserPromptSubmit', args=('prompt',)))
        state = Path(self.env['AGENT_HUB_HOME']) / '.state' / 'delegation' / 'sessions'
        state.mkdir(parents=True)
        (state / 'codex-own').write_text('3')
        out = self.hook('delegation.py', event='UserPromptSubmit', args=('prompt',))
        self.assertIn('changed to 3', out['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.denied(self.hook('delegation.py', 'spawn_agent', {}, args=('pre-tool',))))

    def test_former_slash_command_note_is_host_neutral(self):
        # A prompt that starts with the former plugin's command gets a note naming this plugin's skill; it decides nothing.
        out = self.hook('delegation.py', event='UserPromptSubmit', args=('prompt',), prompt='/agent-hub:hub take over stage x')  # rename:keep
        note = out['hookSpecificOutput']['additionalContext']
        self.assertIn('`delamain:hub`', note)
        self.assertNotIn('Skill tool', note)
        self.assertIn('in a session started before the rename', note)
        self.assertEqual(out['hookSpecificOutput']['hookEventName'], 'UserPromptSubmit')
        for prompt in ('how is it going?', '/delamain:hub take over', '/foo:hub take over', '/agent-hub:no-such-skill x'):  # rename:keep
            self.assertFalse(self.hook('delegation.py', event='UserPromptSubmit', args=('prompt',), prompt=prompt), prompt)

    def test_codex_effort_rules_read_codex_roles(self):
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-*': 'high'})
        self.assertTrue(self.denied(self.hook('delegation.py', 'spawn_agent', {'model': 'gpt-6-sol', 'reasoning_effort': 'low'}, args=('pre-tool',))))
        self.assertFalse(self.denied(self.hook('delegation.py', 'spawn_agent', {'model': 'gpt-6-sol', 'reasoning_effort': 'high'}, args=('pre-tool',))))
        profile = self.cwd / '.codex'
        profile.mkdir()
        (profile / 'reviewer.toml').write_text('model="gpt-6-sol"\nmodel_reasoning_effort="high"\n')
        (profile / 'config.toml').write_text('[agents.reviewer]\nconfig_file="reviewer.toml"\n')
        self.assertFalse(self.denied(self.hook('delegation.py', 'spawn_agent', {'agent_type': 'reviewer'}, args=('pre-tool',))))
        (profile / 'reviewer.toml').write_text('model="gpt-6-sol"\nmodel_reasoning_effort="low"\n')
        self.assertTrue(self.denied(self.hook('delegation.py', 'spawn_agent', {'agent_type': 'reviewer'}, args=('pre-tool',))))

    def test_standalone_workers_enforce_pinned_effort(self):
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-*': 'high'})
        agents = self.cwd / '.codex' / 'agents'
        agents.mkdir(parents=True)
        for effort in ('high', 'medium'):
            source = ROOT / 'skills/setup/resources/codex-agents' / f'worker-{effort}.toml'
            (agents / source.name).write_text(source.read_text())
        # Standalone worker pins effort, while the explicit spawn supplies its model.
        high = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'worker-high', 'model': 'gpt-6-sol'}, args=('pre-tool',))
        self.assertFalse(self.denied(high))
        medium = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'worker-medium', 'model': 'gpt-6-sol'}, args=('pre-tool',))
        self.assertTrue(self.denied(medium))
        overridden = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'worker-medium', 'model': 'gpt-6-sol',
                                                            'reasoning_effort': 'high'}, args=('pre-tool',))
        self.assertTrue(self.denied(overridden), 'custom file effort overrides explicit spawn effort')

    def test_standalone_name_source_and_project_precedence(self):
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-*': 'high'})
        user = self.home / '.codex' / 'agents'
        project = self.cwd / '.codex' / 'agents'
        user.mkdir(parents=True)
        project.mkdir(parents=True)
        def role(name, effort, model='gpt-6-sol'):
            return f'name="{name}"\ndescription="fixture"\ndeveloper_instructions="fixture"\nmodel="{model}"\nmodel_reasoning_effort="{effort}"\n'
        (user / 'arbitrary.toml').write_text(role('named_worker', 'medium'))
        (project / 'different-filename.toml').write_text(role('named_worker', 'high'))
        (project / 'broken-unrelated.toml').write_text('not a = TOML[')
        (project / 'named_worker.toml').write_text(role('other_worker', 'medium'))
        out = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'named_worker'}, args=('pre-tool',))
        self.assertFalse(self.denied(out))
        (project / 'different-filename.toml').unlink()
        out = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'named_worker'}, args=('pre-tool',))
        self.assertTrue(self.denied(out), 'the user role is used only after project role disappears')
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-6-sol': 'high'})
        out = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'other_worker', 'model': 'gpt-6-luna',
                                                     'reasoning_effort': 'high'}, args=('pre-tool',))
        self.assertTrue(self.denied(out), 'role definition overrides explicit model and effort')

    def test_standalone_roles_skip_unrelated_ancestors(self):
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-*': 'high'})
        # Without a Git root, only cwd is a project layer, never arbitrary ancestors.
        (self.cwd / '.git').rmdir()
        outer = self.home / 'outside'
        self.cwd = outer / 'nested'
        self.cwd.mkdir(parents=True)
        agents = outer / '.codex' / 'agents'
        agents.mkdir(parents=True)
        (agents / 'not-in-this-project.toml').write_text('name="foreign"\ndescription="fixture"\ndeveloper_instructions="fixture"\nmodel_reasoning_effort="low"\n')
        out = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'foreign', 'model': 'gpt-6-sol',
                                                     'reasoning_effort': 'high'}, args=('pre-tool',))
        self.assertFalse(self.denied(out))

    def test_explicit_legacy_mapping_remains_supported(self):
        self.config(AGENT_HUB_EFFORT_RULES={'gpt-*': 'high'})
        directory = self.cwd / '.codex'
        (directory / 'agents').mkdir(parents=True)
        (directory / 'mapped.toml').write_text('model="gpt-6-sol"\nmodel_reasoning_effort="high"\n')
        (directory / 'config.toml').write_text('[agents.compat]\nconfig_file="mapped.toml"\n')
        (directory / 'agents/compat.toml').write_text('name="compat"\ndescription="fixture"\ndeveloper_instructions="fixture"\nmodel="gpt-6-sol"\nmodel_reasoning_effort="medium"\n')
        out = self.hook('delegation.py', 'spawn_agent', {'agent_type': 'compat'}, args=('pre-tool',))
        self.assertFalse(self.denied(out))

    def test_bash_guard_remains_active_in_bypass(self):
        denied = self.hook('polling_guard.py', 'Bash', {'command': 'sleep 120'})
        self.assertTrue(self.denied(denied))
        self.assertIn('exec_command', denied['hookSpecificOutput']['permissionDecisionReason'])
        self.assertNotIn('run_in_background', denied['hookSpecificOutput']['permissionDecisionReason'])
        self.assertFalse(self.denied(self.hook('polling_guard.py', 'Bash', {'command': 'echo done'})))
        self.assertTrue(self.denied(self.hook('kill_guard.py', 'Bash', {'command': 'pkill -f "[s]leep 300" -P 1'})))
        self.assertFalse(self.denied(self.hook('kill_guard.py', 'Bash', {'command': 'kill 12345'})))
        self.assertIn('kill_guard.py', [name for name, _ in self.manifest('Bash', {'command': 'true'})])
        self.assertTrue(self.denied(self.hook('scan_guard.py', 'Bash', {'command': 'find ~ -name hive1.py'})))
        self.assertFalse(self.denied(self.hook('scan_guard.py', 'Bash', {'command': 'find ~/repos -name hive1.py'})))
        self.assertIn('scan_guard.py', [name for name, _ in self.manifest('Bash', {'command': 'true'})])
        run = subprocess.run([str(ROOT / 'bin' / 'lock'), 'take', 'main-merge', '--repo', '*', '--until', '2099-01-01T00:00',
                              '--why', 'test', '--owner', 'Other'], capture_output=True, text=True,
                             env={**self.env, 'CODEX_THREAD_ID': 'other'}, timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)
        denied = self.hook('board_locks.py', 'Bash', {'command': 'gh pr merge 42'})
        self.assertTrue(self.denied(denied))
        self.assertFalse(self.denied(self.hook('board_locks.py', 'Bash', {'command': 'gh pr view 42'})))
        self.assertFalse(self.denied(self.hook('board_locks.py', 'Bash', {'command': 'gh pr merge 42'}, session_id='other')))

    def manifest(self, tool, ti):
        """Run only handlers selected by the declared manifest (documented aliases)."""
        out = []
        aliases = {'Bash': ['Bash', 'exec_command', 'shell_command', 'shell'],
                   'apply_patch': ['apply_patch', 'Edit', 'Write'],
                   'spawn_agent': ['spawn_agent', 'Agent']}.get(tool, [tool])
        for group in json.loads((ROOT / 'hooks/codex-hooks.json').read_text())['hooks']['PreToolUse']:
            matcher = group['matcher']
            if matcher != '*' and not any(re.search(matcher, name) for name in aliases):
                continue
            for handler in group['hooks']:
                import shlex
                argv = shlex.split(handler['command'])
                assert Path(argv[0]).name == "run-python"
                assert argv[1:3] == ["--min-version", "3.11"]
                name = Path(argv[3]).name
                out.append((name, self.hook(name, tool, ti, args=argv[4:])))
        return out

    def test_manifest_native_send_rules_and_level_zero_reactivation(self):
        prefixes = ('', 'collaboration.', 'collaboration__', 'collaboration')
        for prefix in prefixes:
            for tool in ('spawn_agent', 'resume_agent', 'send_input', 'followup_task'):
                self.config(AGENT_HUB_DELEGATION=True, AGENT_HUB_DELEGATION_DEFAULT=0)
                outputs = self.manifest(prefix + tool, {'target': 'fixture', 'message': 'work'})
                self.assertTrue(any(name == 'delegation.py' and self.denied(out) for name, out in outputs), prefix + tool)
            self.assertFalse(any(self.denied(out) for _, out in self.manifest(prefix + 'send_message', {'message': 'hello'})))
            self.config(AGENT_HUB_DELEGATION=True, AGENT_HUB_DELEGATION_DEFAULT=3,
                        AGENT_HUB_DELEGATION_RULES=[{'when': {'tool': 'SendMessage'}, 'decision': 'deny', 'reason': 'send blocked'}])
            for tool in ('send_input', 'send_message', 'followup_task'):
                outputs = self.manifest(prefix + tool, {'message': 'work'})
                self.assertTrue(any(name == 'delegation.py' and self.denied(out) for name, out in outputs), prefix + tool)
            for tool in ('update_plan', 'followup_task_extra', 'collaborationXfollowup_task', 'collaborationspawn_agent_extra', 'mcp__server__send_message'):
                outputs = self.manifest(tool, {})
                self.assertFalse(any(name == 'delegation.py' for name, _ in outputs), tool)
                self.assertFalse(any(self.denied(out) for _, out in outputs), tool)

    def test_codex_manifest_preserves_supported_paths(self):
        config = json.loads((ROOT / 'hooks' / 'codex-hooks.json').read_text())
        hooks = config['hooks']
        self.assertIn('UserPromptSubmit', hooks)
        self.assertIn('SessionStart', hooks)
        pre = hooks['PreToolUse']
        self.assertTrue(any(re.search(g['matcher'], 'apply_patch') for g in pre))
        self.assertTrue(any(re.search(g['matcher'], 'spawn_agent') for g in pre))
        self.assertTrue(any(re.search(g['matcher'], 'Bash') for g in pre))


suite = unittest.defaultTestLoader.loadTestsFromTestCase(CodexHooks)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.wasSuccessful():
    for _ in range(result.testsRun):
        print('PASS Codex hook control')
sys.exit(not result.wasSuccessful())
PY
