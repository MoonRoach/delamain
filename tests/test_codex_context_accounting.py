#!/usr/bin/env python3
"""Synthetic source-formula controls; no real transcript content is copied."""
import json
from datetime import datetime, timedelta, timezone
import contextlib
import io
import os
from types import SimpleNamespace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hooks"))
import codex_context_accounting as accounting


def response(kind, **fields):
    record = {"type": "response_item", "payload": {"type": kind, **fields}}
    if kind in ("function_call_output", "custom_tool_call_output"):
        record["metadata"] = {"fallback_token_limit_override": 12000}
    return record


def usage(total=452155):
    return {"type": "event_msg", "timestamp": datetime.now(timezone.utc).isoformat(), "payload": {"type": "token_count", "info": {
        "last_token_usage": {"total_tokens": total, "input_tokens": max(total - 20, 0),
                             "cached_input_tokens": max(total - 30, 0), "output_tokens": min(total, 20),
                             "reasoning_output_tokens": min(total, 10)},
        "total_token_usage": {"total_tokens": 55000000}}}}


def boundary():
    return response("agent_message", author="/root", recipient="/root/worker",
                    content=[{"type": "input_text", "text": "continue"}])


class ContextAccounting(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "rollout.jsonl"

    def write(self, records):
        self.path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records), encoding="utf-8")

    def records(self, total=452155):
        # 1,771,198 encoded bytes => ceil((floor(n*3/4)-650)/4) = 331937.
        return [{"type": "session_meta", "payload": {"id": "own", "source": "vscode",
                    "cli_version": accounting.REFERENCE_VERSION}},
                response("message", role="user", content=[{"type": "input_text", "text": "owner"}]),
                response("reasoning", encrypted_content="x" * 1771198), boundary(),
                response("function_call", call_id="x" * 37, name="work", arguments="{}"), usage(total),
                response("function_call_output", call_id="x" * 37, output="я" * 2060 + "x")]

    def estimate(self, records=None):
        self.write(self.records() if records is None else records)
        return accounting.estimate(self.path, "own")

    def test_causal_native_replay_upper_and_no_provider_components_added(self):
        result = self.estimate()
        self.assertEqual(result, {"estimate_state": "estimated",
            "estimate_provider_tokens": 452155, "estimate_local_tail_tokens": 1040, "estimate_prior_reasoning_tokens": 331937,
            "estimate_lower_tokens": 453195, "estimate_upper_tokens": 785132,
            "estimate_reason": "server_reasoning_unknown"})
        self.assertLess(result["estimate_provider_tokens"], 497040)
        self.assertGreater(result["estimate_upper_tokens"], 497040)

    def test_repeated_usage_deduplicates_and_current_reasoning_is_not_added(self):
        records = self.records()
        records.insert(-1, usage())
        records.insert(-3, response("reasoning", encrypted_content="x" * 4000))
        self.assertEqual(self.estimate(records)["estimate_upper_tokens"], 785132)

    def test_provider_included_reasoning_remains_explicitly_ambiguous(self):
        records = self.records(784092)  # provider may already include 331937 past reasoning
        result = self.estimate(records)
        self.assertEqual(result["estimate_lower_tokens"], 785132)
        self.assertEqual(result["estimate_upper_tokens"], 1117069)
        self.assertEqual(result["estimate_reason"], "server_reasoning_unknown")
        self.assertNotIn("server_reasoning_included", result)

    def test_agent_boundary_is_later_than_plain_user_and_plaintext_reasoning_is_zero(self):
        records = self.records()
        records.insert(3, response("reasoning", content=[{"type": "reasoning_text", "text": "not counted"}]))
        self.assertEqual(self.estimate(records)["estimate_prior_reasoning_tokens"], 331937)

    def test_small_session_and_utf8_output_call_id_rounding(self):
        records = self.records(10)
        records[2] = response("reasoning", encrypted_content="x" * 800)
        records[-1] = response("custom_tool_call_output", call_id="id", name="n", output="я")
        result = self.estimate(records)
        self.assertEqual(result["estimate_upper_tokens"], 12)  # five UTF-8 bytes, rounded once
        self.assertEqual(result["estimate_prior_reasoning_tokens"], 0)

    def test_compact_reset_and_replacement_history_is_unknown(self):
        records = self.records()
        self.assertUnknown(records + [{"type": "compacted", "payload": {}}], "compacted_history")
        records.insert(3, {"type": "compacted", "payload": {}})
        self.assertUnknown(records, "compacted_history")

    def assertUnknown(self, records, reason):
        result = self.estimate(records)
        self.assertEqual(result, {"estimate_state": "unknown", "estimate_reason": reason})

    def test_ownership_inherited_metadata_and_creation_version_is_not_capability(self):
        records = self.records()
        records[0]["payload"]["id"] = "other"
        self.assertUnknown(records, "ownership_unknown")
        records = self.records()
        records[0]["payload"]["forked_from_id"] = "parent"
        self.assertUnknown(records, "ownership_unknown")
        self.assertUnknown([records[0]] + records, "ownership_unknown")
        records = self.records()
        records[0]["payload"]["cli_version"] = "future"
        self.assertEqual(self.estimate(records)["estimate_upper_tokens"], 785132)

    def test_missing_invalid_large_incomplete_and_unsupported_are_unknown(self):
        self.assertUnknown(self.records()[1:], "ownership_unknown")
        records = self.records()
        records[-1]["payload"]["output"] = [{"type": "input_audio", "audio_url": "unused"}]
        self.assertUnknown(records, "unsupported_format")
        self.write(self.records())
        with self.path.open("ab") as stream:
            stream.write(b'{"partial":')
        self.assertEqual(accounting.estimate(self.path, "own")["estimate_reason"], "incomplete_history")
        self.write(self.records())
        with self.path.open("ab") as stream:
            stream.write(b'garbage\n')
        self.assertEqual(accounting.estimate(self.path, "own")["estimate_state"], "unknown")
        with patch.object(accounting, "MAX_SCAN", 128):
            self.assertUnknown(self.records(), "scan_limit")
        with patch.object(accounting, "MAX_RECORD", 128):
            self.assertUnknown(self.records(), "record_limit")

    def test_possible_user_boundary_range_and_sidechain_is_unknown(self):
        records = self.records()
        records[3] = response("message", role="user", content=[{"type": "input_text", "text": "context bundle"}])
        result = self.estimate(records)
        self.assertEqual(result["estimate_upper_tokens"], 785132)
        self.assertEqual(result["estimate_reason"], "server_reasoning_and_boundary_unknown")
        # Native may exclude this contextual user bundle. Moving a possible
        # boundary later only includes more prior reasoning, never less.
        records.insert(-1, response("message", role="user", content=[{"type": "input_text", "text": "context bundle"}]))
        records.insert(-3, response("reasoning", encrypted_content="x" * 4000))
        self.assertGreaterEqual(self.estimate(records)["estimate_upper_tokens"], result["estimate_upper_tokens"])
        records = self.records()
        side = response("reasoning", encrypted_content="x" * 20000)
        side["isSidechain"] = True
        records.insert(2, side)
        self.assertUnknown(records, "ownership_unknown")

    def test_legacy_provider_only_is_not_reinterpreted(self):
        self.assertUnknown([usage(1020)], "ownership_unknown")

    def test_post_tool_result_requires_exact_persisted_text_call_identity(self):
        records = self.records()
        self.write(records)
        pending = {"tool_use_id": "x" * 37, "tool_response": "я" * 2060 + "x"}
        result = accounting.estimate(self.path, "own", pending)
        self.assertEqual(result["estimate_upper_tokens"], 785132)  # exact result is not added twice
        for current in ({"tool_use_id": "not-persisted", "tool_response": "x" * 1000000},
                        {"tool_use_id": "x" * 37, "tool_response": {"content": "x" * 1000000}},
                        {"tool_use_id": "x" * 37, "tool_response": "different"}, {}):
            result = accounting.estimate(self.path, "own", current)
            self.assertEqual(result["estimate_state"], "unknown")
            self.assertEqual(result["estimate_reason"], "pending_output_unknown")

    def test_raw_large_or_missing_output_limit_does_not_pretend_native_tail(self):
        records = self.records()
        records[-1]["payload"]["output"] = "x" * 1000000
        self.assertUnknown(records, "output_truncation_unknown")
        records = self.records()
        records[-1].pop("metadata")
        self.assertUnknown(records, "output_truncation_unknown")


    def test_current_record_families_and_future_variants_are_unknown_anywhere(self):
        for kind in ("inter_agent_communication", "world_state", "retained_context",
                     "InterAgentCommunication", "WorldState", "RetainedContext",
                     "tool_search_call", "tool_search_output", "additional_tools",
                     "configuration_update", "compaction_trigger", "future_variant"):
            for index in (1, -1):
                with self.subTest(kind=kind, index=index):
                    records = self.records()
                    records.insert(index, response(kind, content="PRIVATE"))
                    self.assertUnknown(records, "unsupported_format")
        for kind in ("world_state", "retained_context", "unknown_family"):
            self.assertUnknown(self.records() + [{"type": kind, "payload": {}}], "unsupported_format")
        for kind in ("thread_rolled_back", "history_replaced"):
            self.assertUnknown(self.records() + [{"type": "event_msg", "payload": {"type": kind}}], "incomplete_history")
        self.assertUnknown(self.records() + [{"type": "event_msg", "payload": {"type": "future_event"}}], "unsupported_format")

    def test_parent_and_subagent_sources_cannot_establish_ownership(self):
        for key in ("parent_thread_id", "parent_session_id", "parent_id", "forked_from", "future_parent"):
            records = self.records()
            records[0]["payload"][key] = "foreign"
            self.assertUnknown(records, "ownership_unknown")
        records = self.records()
        records[0]["payload"]["id"] = "foreign"
        self.write(records[:1])
        with self.path.open("ab") as stream:
            stream.write(b"malformed foreign history must not be replayed\n")
        self.assertEqual(accounting.estimate(self.path, "own")["estimate_reason"], "ownership_unknown")
        for source in ({"subagent": {"parent_thread_id": "foreign"}}, "subagent", "future"):
            records = self.records()
            records[0]["payload"]["source"] = source
            # Invalid source shapes are also isolated as an unknown observation.
            self.assertEqual(self.estimate(records)["estimate_state"], "unknown")

    def test_all_usage_claims_must_be_nonempty_well_formed(self):
        for value in ({}, None, [], {"total_tokens": True}, {"total_tokens": -1},
                      {"cached_input_tokens": 40}, {"total_tokens": 0},
                      {"input_tokens": 5}, {"total_tokens": 40, "future": 9},
                      {"total_tokens": 40, "input_tokens": 10, "output_tokens": 31},
                      {"total_tokens": 40, "input_tokens": 30, "output_tokens": 10,
                       "reasoning_output_tokens": 11}):
            with self.subTest(value=value):
                records = self.records()
                records[-2]["payload"]["info"]["last_token_usage"] = value
                self.assertUnknown(records, "unsupported_format")
        records = self.records()
        records[-2]["payload"]["info"]["last_token_usage"].pop("total_tokens")
        self.assertEqual(self.estimate(records)["estimate_provider_tokens"], 452155)
        records.append({"type": "event_msg", "payload": {"type": "token_count", "info": None}})
        self.assertEqual(self.estimate(records)["estimate_provider_tokens"], 452155)
        records[-2] = {"type": "token_usage_record", "timestamp": usage()["timestamp"],
                       "payload": {"usage": {"total_tokens": 452155}}}
        self.assertEqual(self.estimate(records)["estimate_provider_tokens"], 452155)
        for malformed in (None, [], {}, "private"):
            self.assertUnknown(self.records() + [{"type": "token_usage_record", "payload": {"usage": malformed}}], "unsupported_format")

    def test_malformed_nested_fields_and_duplicate_json_keys_are_unknown(self):
        for index, field, value in ((4, "arguments", '{"nested":'),
                                    (4, "arguments", '{"x":1,"x":2}'),
                                    (4, "arguments", '{"x":NaN}'),
                                    (4, "call_id", []), (2, "summary", {}),
                                    (2, "encrypted_content", {"opaque": "private"}),
                                    (1, "content", [{"type": "input_text", "text": []}]),
                                    (1, "new_history_behavior", True)):
            records = self.records()
            records[index]["payload"][field] = value
            self.assertUnknown(records, "unsupported_format")
        self.write(self.records())
        with self.path.open("ab") as stream:
            stream.write(b'{"type":"turn_context","payload":{},"payload":{}}\n')
        self.assertEqual(accounting.estimate(self.path, "own")["estimate_state"], "unknown")
        records = self.records()
        records.insert(3, response("message", role="assistant", content=[{"type": "output_text", "text": '{"author":'}]))
        self.assertUnknown(records, "unsupported_format")

    def test_stale_usage_and_model_after_latest_anchor_are_unknown(self):
        for stamp in (None, "broken", datetime.now(timezone.utc).replace(tzinfo=None).isoformat(),
                      (datetime.now(timezone.utc) - timedelta(seconds=121)).isoformat(),
                      (datetime.now(timezone.utc) + timedelta(seconds=121)).isoformat()):
            records = self.records()
            records[-2]["timestamp"] = stamp
            self.assertUnknown(records, "stale_usage")
        self.assertUnknown(self.records() + [response("reasoning", encrypted_content="x" * 1000)], "stale_usage")

    def test_snapshot_append_rewrite_replace_and_truncate_races(self):
        original = accounting.reverse_records
        for mutation in ("append", "rewrite", "replace", "truncate"):
            self.write(self.records())
            def raced(path, session_id):
                iterator = original(path, session_id)
                # Mutate after replay has consumed all records but before the
                # generator's final descriptor/name signature check.
                for record in iterator:
                    yield record
                    if record.get("type") == "session_meta":
                        if mutation == "append":
                            with path.open("ab") as stream:
                                stream.write(b'{"type":"turn_context","payload":{}}\n')
                        elif mutation == "rewrite":
                            with path.open("r+b") as stream:
                                stream.seek(5)
                                stream.write(b"X")
                        elif mutation == "replace":
                            replacement = path.with_suffix(".replacement")
                            replacement.write_bytes(path.read_bytes())
                            replacement.replace(path)
                        else:
                            with path.open("r+b") as stream:
                                stream.truncate(0)
            with self.subTest(mutation=mutation), patch.object(accounting, "reverse_records", raced):
                self.assertEqual(accounting.estimate(self.path, "own"),
                                 {"estimate_state": "unknown", "estimate_reason": "snapshot_changed"})

    def test_chunk_record_and_total_scan_limits_are_inclusive(self):
        records = self.records(100)
        records[2] = response("reasoning", encrypted_content="x" * 800)
        self.write(records)
        size = self.path.stat().st_size
        longest = max(map(len, self.path.read_bytes().splitlines()))
        with patch.object(accounting, "CHUNK", 17), patch.object(accounting, "MAX_SCAN", size), \
             patch.object(accounting, "MAX_RECORD", longest):
            self.assertEqual(accounting.estimate(self.path, "own")["estimate_state"], "estimated")
        with patch.object(accounting, "MAX_SCAN", size - 1):
            self.assertEqual(accounting.estimate(self.path, "own")["estimate_reason"], "scan_limit")

    def test_privacy_even_for_paths_opaque_arguments_and_exceptions(self):
        sentinel = "PRIVATE_SENTINEL_arguments_path_transcript_opaque"
        self.path = self.path.with_name(sentinel + ".jsonl")
        records = self.records()
        records[2]["payload"]["encrypted_content"] = sentinel * 100
        records[4]["payload"]["arguments"] = json.dumps({"secret": sentinel})
        records[-1]["payload"]["output"] = sentinel
        self.write(records)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = accounting.estimate(self.path, "own")
            self.assertEqual(result["estimate_state"], "estimated")
            with patch.object(accounting, "reverse_records", side_effect=OSError(sentinel)):
                failure = accounting.estimate(self.path, "own")
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn(sentinel, json.dumps([result, failure]))
        self.assertEqual(failure, {"estimate_state": "unknown", "estimate_reason": "unreadable_history"})


if __name__ == "__main__":
    unittest.main()
