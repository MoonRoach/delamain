#!/usr/bin/env python3
"""Opt-in observations cannot become policy or durable context state."""
import copy
import contextlib
import io
import json
import multiprocessing
import os
from pathlib import Path
import sys
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hooks"))
import codex_context_accounting as accounting
import context_budget
import test_context_state_writes as state_controls
from test_codex_context_accounting import response, usage

REAL_DIAGNOSTIC = context_budget.diagnostic
KEY = "AGENT_HUB_CODEX_CONTEXT_ESTIMATE"


class ObservationControls(state_controls.ContextStateWrites):
    def setUp(self):
        super().setUp()
        # The coordinator owns the real hubcore registration. Do not simulate
        # it here: home/project/stage controls must exercise the actual loader.
        self.hc._CONFIG_CACHE.clear()
        self.addCleanup(self.hc._CONFIG_CACHE.clear)

    def rollout(self, tokens=1000, unknown=False):
        records = [{"type": "session_meta", "payload": {"id": "own-session", "source": "cli"}},
                   response("message", role="user", content=[{"type": "input_text", "text": "owner"}]),
                   response("reasoning", encrypted_content="x" * 4000000),
                   response("agent_message", author="/root", recipient="/root/worker", content="continue"),
                   response("function_call", call_id="call", name="work", arguments="{}"), usage(tokens),
                   response("function_call_output", call_id="call", output="tail")]
        records[-2]["payload"]["info"]["model_context_window"] = 828400
        records.insert(1, {"type": "turn_context", "payload": {
            "model": "fixture-model", "effort": "high", "approval_policy": "never",
            "sandbox_policy": {"type": "danger-full-access"}}})
        if unknown:
            records.insert(1, response("world_state", content="PRIVATE_SENTINEL"))
        self.transcript.write_text("".join(json.dumps(record) + "\n" for record in records))

    def policy_output(self, output):
        output = copy.deepcopy(output)
        fields = output.get("hookSpecificOutput", {})
        text = fields.get("additionalContext", "")
        if " Experimental Codex context estimate" in text:
            text = text.split(" Experimental Codex context estimate", 1)[0]
            if text == "Context observation:":
                return {}
            fields["additionalContext"] = text
        return output

    def test_off_bypasses_scanner_including_default_and_invalid(self):
        for value in (None, "off", "false", "invalid"):
            if value is None:
                os.environ.pop(KEY, None)
            else:
                os.environ[KEY] = value
            with patch.object(accounting, "estimate", side_effect=AssertionError("must bypass")) as estimate:
                self.hook(event="UserPromptSubmit", prompt="hello")
                estimate.assert_not_called()

    def test_only_registered_codex_main_hub_scans_even_with_auto_off(self):
        os.environ[KEY] = "on"
        self.rollout()
        for fields in ({"agent_id": "worker"}, {"session_id": "unregistered"}):
            with patch.object(accounting, "estimate", wraps=accounting.estimate) as estimate:
                result = self.hook(event="UserPromptSubmit", **fields)
                estimate.assert_not_called()
                self.assertNotIn("Experimental", json.dumps(result))
        os.environ["AGENT_HUB_ENGINE"] = "claude"
        with patch.object(accounting, "estimate", wraps=accounting.estimate) as estimate:
            self.hook(event="UserPromptSubmit")
            estimate.assert_not_called()
        os.environ["AGENT_HUB_ENGINE"] = "codex"
        os.environ["AGENT_HUB_AUTO_HANDOFF"] = "off"
        with patch.object(accounting, "estimate", wraps=accounting.estimate) as estimate:
            result = self.hook(event="UserPromptSubmit")
            estimate.assert_called_once()
            text = result["hookSpecificOutput"]["additionalContext"]
            self.assertIn("1,002–750,840", text)
            self.assertIn("heuristic range", text)
            self.assertIn("not guaranteed tokenizer bounds", text)
            self.assertNotIn("handoff_due", self.state())

    def test_env_home_only_and_environment_precedence(self):
        self.rollout()
        project = self.cwd / ".agent-hub"
        project.mkdir()
        (project / "config.json").write_text(json.dumps({KEY: "on"}))
        (self.stage / "config.json").write_text(json.dumps({KEY: "on"}))
        self.assertNotIn("Experimental", json.dumps(self.hook(event="UserPromptSubmit")))
        home_config = self.hub / "config.json"
        home_config.write_text(json.dumps({KEY: "on"}))
        self.hc._CONFIG_CACHE.clear()
        self.assertIn("Experimental", json.dumps(self.hook(event="UserPromptSubmit")))
        os.environ[KEY] = "off"
        self.assertNotIn("Experimental", json.dumps(self.hook(event="UserPromptSubmit")))
        os.environ.pop(KEY)
        home_config.write_text(json.dumps({KEY: True}))
        self.hc._CONFIG_CACHE.clear()
        self.assertIn("Experimental", json.dumps(self.hook(event="UserPromptSubmit")))

    def test_on_off_policy_messages_and_complete_state_are_identical(self):
        # Replay from the same starting bytes in the same fixture: full state,
        # diagnostics, and decisions must match, except the optional estimate.
        self.hook(event="UserPromptSubmit", prompt="owner")  # initialize policy directories before snapshot comparison
        for tokens, unknown in ((1000, False), (350000, False), (550000, False), (1000, True)):
            for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"):
                with self.subTest(tokens=tokens, unknown=unknown, event=event):
                    self.rollout(tokens, unknown)
                    if self.record.exists():
                        self.record.unlink()
                    outputs, states, logs, writes = [], [], [], []
                    for enabled in ("off", "on"):
                        if self.record.exists():
                            self.record.unlink()
                        os.environ[KEY] = enabled
                        self.diagnostics.reset_mock()
                        with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writer, \
                             patch.object(context_budget, "metric_age", return_value=1.0):
                            output = self.hook(event=event, prompt="owner", tool_use_id="call", tool_response="tail")
                        outputs.append(self.policy_output(output))
                        states.append(self.record.read_bytes() if self.record.exists() else None)
                        logs.append([call for call in self.diagnostics.call_args_list if "estimate_state" not in call.kwargs])
                        writes.append(writer.call_count)
                    self.assertEqual(outputs[0], outputs[1])
                    self.assertEqual(states[0], states[1])
                    self.assertEqual(logs[0], logs[1])
                    self.assertEqual(writes[0], writes[1])

    def test_noop_identity_and_durable_barrier_after_usage_decreases(self):
        self.rollout(550000)
        self.assertTrue(self.denied(self.hook()))
        self.rollout(1000)
        before = self.record.read_bytes()
        signature = self.record.stat()
        for enabled in ("off", "on"):
            os.environ[KEY] = enabled
            with patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes:
                self.assertTrue(self.denied(self.hook()))
                self.assertEqual(writes.call_count, 0)
            after = self.record.stat()
            self.assertEqual((after.st_ino, after.st_mtime_ns), (signature.st_ino, signature.st_mtime_ns))
            self.assertEqual(self.record.read_bytes(), before)

    def test_unknown_and_scanner_failure_preserve_provider_gates(self):
        os.environ[KEY] = "on"
        self.rollout(550000, unknown=True)
        output = self.hook(event="UserPromptSubmit")
        self.assertIn("unknown (unsupported_format)", json.dumps(output))
        estimate_calls = [call for call in self.diagnostics.call_args_list if "estimate_state" in call.kwargs]
        self.assertEqual(set(estimate_calls[-1].kwargs), {"estimate_state", "estimate_reason"})
        self.assertTrue(self.denied(self.hook()))
        before = self.record.read_bytes()
        with patch.object(accounting, "estimate", side_effect=RuntimeError("PRIVATE_SENTINEL")):
            self.assertTrue(self.denied(self.hook()))
            self.assertNotIn("PRIVATE_SENTINEL", json.dumps(self.hook(event="UserPromptSubmit")))
        self.assertEqual(self.record.read_bytes(), before)

    def test_real_diagnostic_sink_keeps_provider_metric_and_privacy_allowlist(self):
        os.environ[KEY] = "on"
        self.rollout(350000)
        sentinel = "PRIVATE_SENTINEL_arguments_transcript_path_opaque"
        self.transcript = self.cwd / (sentinel + ".jsonl")
        self.rollout(350000)
        with patch.object(context_budget, "diagnostic", REAL_DIAGNOSTIC):
            self.hook(event="UserPromptSubmit", prompt=sentinel)
        sink = self.hub / ".state/handoff-events/own-session.jsonl"
        records = [json.loads(line) for line in sink.read_text().splitlines()]
        provider = [r for r in records if r.get("metric_source") == "provider_last_usage"]
        estimates = [r for r in records if r.get("estimate_state") == "estimated"]
        self.assertEqual(provider[-1]["tokens"], 350000)
        self.assertEqual(estimates[-1]["estimate_provider_tokens"], 350000)
        self.assertNotIn("tokens", estimates[-1])
        self.assertNotIn("metric_source", estimates[-1])
        for file in (self.hub / ".state/handoff-events").iterdir():
            self.assertNotIn(sentinel.encode(), file.read_bytes())
        self.rollout(350000, unknown=True)
        with patch.object(context_budget, "diagnostic", REAL_DIAGNOSTIC):
            self.hook(event="PostToolUse")
        records = [json.loads(line) for line in sink.read_text().splitlines()]
        unknown = [r for r in records if r.get("estimate_state") == "unknown"][-1]
        self.assertEqual({k: v for k, v in unknown.items() if k.startswith("estimate_")},
                         {"estimate_state": "unknown", "estimate_reason": "unsupported_format"})


    def test_stop_continuations_identical_and_never_estimated(self):
        self.rollout(350000)
        self.hook(event="UserPromptSubmit", prompt="owner")
        initial = self.record.read_bytes()
        sequences = []
        for enabled in ("off", "on"):
            os.environ[KEY] = enabled
            self.record.write_bytes(initial)
            pending = self.stage / "auto-handoff.json"
            pending.unlink(missing_ok=True)
            sequence = []
            with patch.object(accounting, "estimate", side_effect=AssertionError("gate scan sentinel")) as estimate:
                first = self.hook(event="Stop", last_assistant_message=context_budget.READY_MARKER)
                estimate.assert_not_called()
            self.assertEqual(first["decision"], "block")
            sequence.append((first, self.record.read_bytes()))
            self.assertEqual(self.state()["stop_continuations"], 1)
            sequence.append((self.hook(event="Stop", stop_hook_active=True), self.record.read_bytes()))
            self.assertEqual(sequence[-1][0], {})
            pending.write_text(json.dumps({"pending": {"surface": "desktop", "predecessor": "own-session",
                "request_id": "request-one", "phase": "prepared"}}))
            # Canonical exact progress permits the existing second continuation.
            self.hook(event="PostToolUse", tool_use_id="call", tool_response="tail")
            second = self.hook(event="Stop", stop_hook_active=True, last_assistant_message=context_budget.READY_MARKER)
            self.assertEqual(second["decision"], "block")
            self.assertEqual(self.state()["stop_continuations"], 2)
            sequence.append((second, self.record.read_bytes()))
            sequence.append((self.hook(event="Stop", stop_hook_active=True,
                last_assistant_message=context_budget.READY_MARKER), self.record.read_bytes()))
            self.assertEqual(sequence[-1][0], {})
            sequences.append(sequence)
        self.assertEqual(sequences[0], sequences[1])


    def test_real_deny_and_stop_bypass_estimator_with_exact_stdout_state_writes(self):
        # Direct bypass is separate from the concurrent observer-lock control below.
        for event, tokens in (("PreToolUse", 550000), ("Stop", 350000)):
            with self.subTest(event=event):
                os.environ[KEY] = "off"
                self.rollout(tokens)
                self.hook(event="UserPromptSubmit", prompt="owner")
                initial = self.record.read_bytes()
                samples = []
                for enabled in ("off", "on"):
                    os.environ[KEY] = enabled
                    self.record.write_bytes(initial)
                    data = dict(session_id="own-session", cwd=str(self.cwd), hook_event_name=event,
                                transcript_path=str(self.transcript), tool_name="Bash",
                                tool_input={"command": "echo ordinary-work"},
                                last_assistant_message=context_budget.READY_MARKER)
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output), patch("sys.stdin", io.StringIO(json.dumps(data))), \
                         patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes, \
                         patch.object(self.hc, "setting", wraps=self.hc.setting) as setting, \
                         patch.object(context_budget, "metric_age", return_value=1.0), \
                         patch.object(accounting, "estimate", side_effect=AssertionError("gate scan sentinel")) as estimate, \
                         patch.object(context_budget, "context_estimate_advisory", side_effect=AssertionError("enrichment sentinel")) as advisory:
                        context_budget.main()
                        estimate.assert_not_called()
                        advisory.assert_not_called()
                        self.assertFalse(any(call.args and call.args[0] == KEY for call in setting.call_args_list))
                    raw = output.getvalue()
                    result = json.loads(raw)
                    if event == "PreToolUse":
                        self.assertTrue(self.denied(result))
                    else:
                        self.assertEqual(result["decision"], "block")
                        self.assertTrue(result["reason"].startswith(context_budget.CONTINUATION_MARKER))
                        self.assertEqual(self.state()["stop_continuations"], 1)
                    samples.append((raw, self.record.read_bytes(), writes.call_count))
                self.assertEqual(samples[0], samples[1])

    def test_main_gates_finish_while_optional_observer_io_is_held(self):
        # Fork only owned fixture processes: actual main(), actual file mutex,
        # and an indefinite observer barrier released only after a gate finishes.
        ctx = multiprocessing.get_context("fork")

        def invoke(event):
            data = dict(session_id="own-session", cwd=str(self.cwd), hook_event_name=event,
                        transcript_path=str(self.transcript), tool_name="Bash",
                        tool_input={"command": "echo ordinary-work"}, tool_use_id="call",
                        tool_response="tail", last_assistant_message=context_budget.READY_MARKER)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch("sys.stdin", io.StringIO(json.dumps(data))), \
                 patch.object(self.hc, "atomic_write", wraps=self.hc.atomic_write) as writes, \
                 patch.object(context_budget, "metric_age", return_value=1.0):
                context_budget.main()
            return output.getvalue(), self.record.read_bytes(), writes.call_count

        for event, tokens in (("PreToolUse", 550000), ("Stop", 350000)):
            for phase in ("estimate", "eligibility", "registry", "resolve", "diagnostic"):
                with self.subTest(event=event, phase=phase):
                    os.environ[KEY] = "off"
                    self.rollout(tokens)
                    self.record.unlink(missing_ok=True)
                    self.hook(event="UserPromptSubmit", prompt="owner")
                    initial = self.record.read_bytes()
                    baseline_observer = invoke("PostToolUse")
                    baseline_gate = invoke(event)
                    decision = json.loads(baseline_gate[0])
                    if event == "PreToolUse":
                        self.assertTrue(self.denied(decision))
                    else:
                        self.assertEqual(decision["decision"], "block")
                        self.assertTrue(decision["reason"].startswith(context_budget.CONTINUATION_MARKER))
                    self.record.write_bytes(initial)
                    os.environ[KEY] = "on"
                    entered, release, policy_done, gate_started = (ctx.Event() for _ in range(4))
                    observer_recv, observer_send = ctx.Pipe(duplex=False)
                    gate_recv, gate_send = ctx.Pipe(duplex=False)
                    children = []

                    def hold():
                        entered.set()
                        release.wait()

                    def observer():
                        provider = context_budget.handle_provider_policy
                        setting = self.hc.setting
                        resolve = context_budget.resolve_transcript
                        estimate = accounting.estimate
                        diagnostic = context_budget.diagnostic
                        ap = context_budget.autopilot()
                        registry = ap.hub_stage_of

                        def policy(*args, **kwargs):
                            result = provider(*args, **kwargs)
                            policy_done.set()
                            return result

                        def optional(fn, selected):
                            def call(*args, **kwargs):
                                if selected(*args, **kwargs):
                                    hold()
                                return fn(*args, **kwargs)
                            return call

                        with patch.object(context_budget, "handle_provider_policy", side_effect=policy), \
                             patch.object(self.hc, "setting", side_effect=optional(setting,
                                 lambda name, *a, **kw: phase == "eligibility" and name == KEY)), \
                             patch.object(ap, "hub_stage_of", side_effect=optional(registry,
                                 lambda *a, **kw: phase == "registry" and policy_done.is_set())), \
                             patch.object(context_budget, "resolve_transcript", side_effect=optional(resolve,
                                 lambda *a, **kw: phase == "resolve" and policy_done.is_set())), \
                             patch.object(accounting, "estimate", side_effect=optional(estimate,
                                 lambda *a, **kw: phase == "estimate")), \
                             patch.object(context_budget, "diagnostic", side_effect=optional(diagnostic,
                                 lambda *a, **kw: phase == "diagnostic" and "estimate_state" in kw)):
                            observer_send.send(invoke("PostToolUse"))

                    def gate():
                        gate_started.set()
                        gate_send.send(invoke(event))

                    try:
                        child = ctx.Process(target=observer)
                        children.append(child)
                        child.start()
                        self.assertTrue(entered.wait(5), "observer did not reach owned IO barrier")
                        self.assertTrue(policy_done.is_set(), "optional IO preceded provider policy")
                        self.assertEqual(self.record.read_bytes(), baseline_observer[1])
                        child = ctx.Process(target=gate)
                        children.append(child)
                        child.start()
                        self.assertTrue(gate_started.wait(5), "gate child did not start")
                        self.assertTrue(gate_recv.poll(5), "gate waited for optional observer IO")
                        self.assertEqual(gate_recv.recv(), baseline_gate)
                        self.assertFalse(release.is_set())
                        self.assertTrue(children[0].is_alive(), "observer escaped owned IO barrier")
                        release.set()
                        self.assertTrue(observer_recv.poll(5), "observer did not finish after release")
                        observed = observer_recv.recv()
                        self.assertEqual(self.policy_output(json.loads(observed[0])),
                                         json.loads(baseline_observer[0]) if baseline_observer[0].strip() else {})
                        self.assertEqual(observed[1], baseline_gate[1], "observer rewrote later gate state")
                        self.assertEqual(observed[2], baseline_observer[2])
                        for child in children:
                            child.join(5)
                            self.assertEqual(child.exitcode, 0)
                    finally:
                        release.set()
                        for child in children:
                            child.join(5)
                            if child.is_alive():
                                child.terminate()
                                child.join(5)
                            self.assertFalse(child.is_alive(), "owned probe child was not joined")
                        for connection in (observer_recv, observer_send, gate_recv, gate_send):
                            connection.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
