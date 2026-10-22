#!/usr/bin/env python3
"""Count durable context-state writes, using isolated homes and the real atomic writer."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hooks"))
import context_budget


class ContextStateWrites(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.hub = self.home / "hub"
        self.hub.mkdir()
        self.cwd = self.home / "repo"
        self.cwd.mkdir()
        self.stage = self.hub / "stage-a"
        self.stage.mkdir()
        self.roles(self.stage, "own-session")
        self.env = dict(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"),
                        PATH=os.environ.get("PATH", "/usr/bin:/bin"),
                        PLUGIN_ROOT=str(ROOT), AGENT_HUB_HOME=str(self.hub),
                        AGENT_HUB_ENGINE="codex", AGENT_HUB_AUTO_HANDOFF="on",
                        AGENT_HUB_CONTEXT_WARN="300000", AGENT_HUB_CONTEXT_BLOCK="500000",
                        CODEX_THREAD_ID="own-session", CODEX_HOME=str(self.home / "codex"))
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.env, clear=True).start()
        self.hc = context_budget.hubcore()
        self.hc.use_cwd(str(self.cwd))
        patch.object(context_budget, "grilling", return_value=None).start()
        self.diagnostics = patch.object(context_budget, "diagnostic").start()
        self.state_dir = self.hub / ".state/context-budget"
        self.record = self.state_dir / "own-session.json"
        self.transcript = self.cwd / "rollout.jsonl"
        self.usage(1000)

    def roles(self, stage, session):
        (stage / "roles.json").write_text(json.dumps({"roles": {"hub": {"session": session}}}))

    def usage(self, tokens):
        self.transcript.write_text(json.dumps(dict(type="token_usage_record", payload=dict(
            model_context_window=828400, usage=dict(total_tokens=tokens)))) + "\n")

    def state(self):
        return json.loads(self.record.read_text())

    def hook(self, tool="Bash", event="PreToolUse", **fields):
        data = dict(session_id="own-session", cwd=str(self.cwd), hook_event_name=event,
                    transcript_path=str(self.transcript), tool_name=tool,
                    tool_input={"command": "echo work", "file_path": "ordinary.md"})
        data.update(fields)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch("sys.stdin", io.StringIO(json.dumps(data))):
            context_budget.main()
        return json.loads(output.getvalue()) if output.getvalue().strip() else {}

    def denied(self, result):
        return result.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"

    def test_first_real_observations_write_but_unchanged_pretools_do_not(self):
        with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes, \
             patch.object(os, "fsync", wraps=os.fsync) as syncs:
            self.assertEqual(self.hook(), {})
            self.assertGreater(writes.call_count, 0)
            self.assertEqual(syncs.call_count, writes.call_count)
            self.assertTrue(self.state()["usage_seen"])
            self.assertEqual(self.state()["hub_registry"]["stage"], "stage-a")
            writes.reset_mock()
            syncs.reset_mock()
            for tool in ("Bash", "Edit", "Write", "apply_patch"):
                with self.subTest(tool=tool):
                    writes.reset_mock()
                    syncs.reset_mock()
                    self.assertEqual(self.hook(tool), {})
                    self.assertEqual(writes.call_count, 0)
                    self.assertEqual(syncs.call_count, 0)

    def test_registration_change_saves_reset_obligation(self):
        self.usage(550000)
        self.assertTrue(self.denied(self.hook()))
        self.usage(1000)
        self.roles(self.stage, "successor")
        other = self.hub / "stage-b"
        other.mkdir()
        self.roles(other, "own-session")
        with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
            self.assertEqual(self.hook(), {})
            self.assertGreater(writes.call_count, 0)
        state = self.state()
        self.assertEqual(state["hub_registry"]["stage"], "stage-b")
        self.assertNotIn("handoff_due", state)
        self.assertNotIn("block_due", state)

    def test_block_is_durable_before_denial_and_noop_repeats_do_not_write(self):
        self.hook()
        self.usage(550000)
        persisted_block = []
        atomic_write = self.hc.atomic_write

        def write(path, text):
            atomic_write(path, text)
            persisted_block.append(self.state().get("block_due", False))

        with patch.object(self.hc, "atomic_write", side_effect=write):
            self.assertTrue(self.denied(self.hook()))
        self.assertTrue(persisted_block[-1])
        self.assertTrue(self.state()["block_due"])
        self.usage(1000)
        with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
            self.assertTrue(self.denied(self.hook()))
            self.assertEqual(writes.call_count, 0)
        # Explicit policy provenance is still persisted, even with lower usage.
        os.environ["AGENT_HUB_CONTEXT_BLOCK"] = "600000"
        with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
            self.assertEqual(self.hook(), {})
            self.assertGreater(writes.call_count, 0)
        self.assertNotIn("block_due", self.state())
        self.assertNotIn("handoff_due", self.state())

    def test_live_authority_changes_are_durable(self):
        self.hook()
        for prompt, stopped in (("Do not hand over.", True), ("Resume the handoff.", False)):
            with self.subTest(prompt=prompt), \
                 patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
                self.assertEqual(self.hook(event="UserPromptSubmit", prompt=prompt), {})
                self.assertGreater(writes.call_count, 0)
                self.assertIs(self.state()["transfer_stop"], stopped)

    def test_failed_mutation_keeps_state_io_diagnostic_and_gate(self):
        self.hook()
        self.usage(550000)
        before = self.record.read_bytes()
        with patch.object(self.hc, "atomic_write", side_effect=OSError("write failed")) as writes:
            self.assertTrue(self.denied(self.hook()))
            self.assertEqual(writes.call_count, 1)
        self.assertEqual(self.record.read_bytes(), before)
        self.assertTrue(any(call.kwargs.get("reason") == "state_io"
                            for call in self.diagnostics.call_args_list))

    def test_snapshot_detects_nested_cache_mutation(self):
        self.hook()
        before = self.state()["hub_registry"]["entries"][0][1][0]

        def update_cache(ap, hc, sid, state):
            state["hub_registry"]["entries"][0][1][0] += 1
            return "stage-a"

        with patch.object(context_budget, "registered_stage", side_effect=update_cache), \
             patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
            self.assertEqual(self.hook(), {})
            self.assertEqual(writes.call_count, 1)
        self.assertEqual(self.state()["hub_registry"]["entries"][0][1][0], before + 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
