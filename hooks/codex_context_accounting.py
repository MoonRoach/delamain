"""Experimental observation of one explicitly owned Codex rollout.

Formula references: codex-rs/core/src/context_manager/history.rs and
history/src/lib.rs in 0.162.0-alpha.17.2 / 0.163.0-alpha.11. These internal
formats are not a supported public contract. The native server-reasoning flag
and exact instruction boundary are unavailable: ranges are heuristics, never
promised tokenizer bounds, policy metrics, or evidence of headroom.
Opaque bytes are only measured; no text, paths, or exception messages escape.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat

REFERENCE_VERSION = "0.162.0-alpha.17.2"
MAX_SCAN = 64 << 20
CHUNK = 1 << 20
MAX_RECORD = 8 << 20
MAX_USAGE_AGE = 120
MAX_NUMBER = 2**53 - 1
REASONS = frozenset({
    "server_reasoning_unknown", "server_reasoning_and_boundary_unknown",
    "unsupported_format", "output_truncation_unknown", "scan_limit", "record_limit",
    "incomplete_history", "compacted_history", "ownership_unknown",
    "pending_output_unknown", "unreadable_history", "snapshot_changed", "stale_usage",
})
MODEL_ITEMS = frozenset({"reasoning", "function_call", "custom_tool_call"})
LOCAL_ITEMS = frozenset({"agent_message", "function_call_output", "custom_tool_call_output"})
# Only events proven not to replace the model history are ignored. New families
# must be reviewed, even when they occur before the latest provider usage.
NEUTRAL_EVENTS = frozenset({
    "user_message", "agent_message", "agent_reasoning", "agent_reasoning_raw_content",
    "task_started", "task_complete", "turn_started", "turn_complete",
    "exec_command_begin", "exec_command_end", "exec_command_output_delta",
    "mcp_tool_call_begin", "mcp_tool_call_end", "custom_tool_call_begin", "custom_tool_call_end",
    "patch_apply_begin", "patch_apply_end", "item_started", "item_completed",
})


class Unknown(ValueError):
    """Carries only a fixed safe reason enum."""


def text_size(value):
    if not isinstance(value, str):
        raise Unknown("unsupported_format")
    try:
        return len(value.encode("utf-8"))
    except UnicodeError:
        raise Unknown("unsupported_format") from None


def content_size(content, encrypted=False):
    if isinstance(content, str):
        return text_size(content)
    if not isinstance(content, list):
        raise Unknown("unsupported_format")
    size = 0
    for part in content:
        if not isinstance(part, dict):
            raise Unknown("unsupported_format")
        if part.get("type") in ("input_text", "output_text") and set(part) <= {"type", "text"}:
            size += text_size(part.get("text"))
        elif encrypted and part.get("type") == "encrypted_content" and set(part) <= {"type", "encrypted_content"}:
            size += (text_size(part.get("encrypted_content")) * 9 + 15) // 16
        else:
            raise Unknown("unsupported_format")
    return size


def strict_json(value):
    def pairs(items):
        result = {}
        for key, val in items:
            if key in result:
                raise Unknown("unsupported_format")
            result[key] = val
        return result
    def constant(_):
        raise Unknown("unsupported_format")
    try:
        return json.loads(value, object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise Unknown("unsupported_format") from None


def item_tokens(item):
    """Validate every item, including model items already covered by usage."""
    kind = item.get("type")
    common = {"type", "id"}
    if "id" in item and item["id"] is not None:
        text_size(item["id"])
    if kind == "message":
        allowed = common | {"role", "content", "phase", "end_turn"}
        if item.get("role") not in ("user", "assistant", "system", "developer"):
            raise Unknown("unsupported_format")
        if item.get("phase") not in (None, "commentary", "final_answer"):
            raise Unknown("unsupported_format")
        if item.get("end_turn") is not None and type(item["end_turn"]) is not bool:
            raise Unknown("unsupported_format")
        size = content_size(item.get("content"))
        if item.get("role") == "assistant":
            possible_boundary(item)  # validate compatibility JSON even before an already-found boundary
    elif kind == "agent_message":
        allowed = common | {"author", "recipient", "content", "trigger_turn"}
        if "trigger_turn" in item and type(item["trigger_turn"]) is not bool:
            raise Unknown("unsupported_format")
        size = text_size(item.get("author")) + text_size(item.get("recipient")) + content_size(item.get("content"), True)
    elif kind == "reasoning":
        allowed = common | {"encrypted_content", "summary", "content"}
        for key, part_kind in (("summary", "summary_text"), ("content", "reasoning_text")):
            parts = item.get(key)
            if parts is not None:
                if not isinstance(parts, list):
                    raise Unknown("unsupported_format")
                for part in parts:
                    if not isinstance(part, dict) or part.get("type") != part_kind or set(part) != {"type", "text"}:
                        raise Unknown("unsupported_format")
                    text_size(part["text"])
        opaque = item.get("encrypted_content")
        size = max(0, text_size(opaque) * 3 // 4 - 650) if opaque is not None else 0
    elif kind in ("function_call", "custom_tool_call"):
        allowed = common | {"call_id", "name", "namespace", "arguments" if kind == "function_call" else "input", "status"}
        for key in ("call_id", "name"):
            text_size(item.get(key))
        if item.get("namespace") is not None:
            text_size(item["namespace"])
        if item.get("status") not in (None, "completed", "in_progress"):
            raise Unknown("unsupported_format")
        text_size(item.get("arguments" if kind == "function_call" else "input"))
        if kind == "function_call" and not isinstance(strict_json(item["arguments"]), dict):
            raise Unknown("unsupported_format")
        size = 0  # model-generated: already covered by provider usage
    elif kind in ("function_call_output", "custom_tool_call_output"):
        allowed = common | {"call_id", "name", "namespace", "output"}
        text_size(item.get("call_id"))
        size = content_size(item.get("output"), encrypted=True)
        for key in (("call_id", "name", "namespace") if kind == "function_call_output" else ("call_id", "name")):
            if item.get(key) is not None:
                size += text_size(item[key])
    else:
        raise Unknown("unsupported_format")
    if set(item) - allowed:
        raise Unknown("unsupported_format")
    return (size + 3) // 4


def validate_output_limit(record, item):
    """Persisted raw output is not necessarily runtime-truncated model input."""
    metadata = record.get("metadata")
    if not isinstance(metadata, dict):
        raise Unknown("output_truncation_unknown")
    limits = [metadata[k] for k in ("fallback_token_limit_override", "history_truncation_token_limit") if k in metadata]
    if (not limits or any(type(v) is not int or v < 1 for v in limits) or len(set(limits)) != 1
            or (content_size(item.get("output"), True) + 3) // 4 > limits[0]):
        raise Unknown("output_truncation_unknown")


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def owned_metadata(payload, session_id):
    if (payload.get("id") != session_id or not session_id
            or not isinstance(payload.get("source"), str) or payload["source"] not in ("vscode", "cli")
            or any(v for k, v in payload.items() if "parent" in k.lower() or "fork" in k.lower())):
        raise Unknown("ownership_unknown")


def parse_record(line):
    record = strict_json(line)
    if (not isinstance(record, dict) or not isinstance(record.get("payload"), dict)
            or set(record) - {"type", "timestamp", "payload", "metadata", "isSidechain"}):
        raise Unknown("unsupported_format")
    if record.get("isSidechain"):
        raise Unknown("ownership_unknown")
    return record


def reverse_records(path, session_id):
    """A bounded complete scan with a pinned descriptor and checked snapshot."""
    path = Path(path)
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise Unknown("unreadable_history")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or signature(before) != signature(opened):
            raise Unknown("snapshot_changed")
        pos = opened.st_size
        if pos > MAX_SCAN:
            raise Unknown("scan_limit")
        # Read the ownership header once, before replaying any history. The
        # reverse scan excludes these bytes, keeping the total within MAX_SCAN.
        header_line = stream.readline(MAX_RECORD + 2)
        if len(header_line.rstrip(b"\n")) > MAX_RECORD:
            raise Unknown("record_limit")
        if not header_line.endswith(b"\n"):
            raise Unknown("incomplete_history")
        header = parse_record(header_line)
        if header.get("type") != "session_meta":
            raise Unknown("ownership_unknown")
        owned_metadata(header["payload"], session_id)
        start = len(header_line)
        tail = b""
        first_chunk = True
        while pos > start:
            step = min(CHUNK, pos - start)
            pos -= step
            stream.seek(pos)
            chunk = stream.read(step)
            if len(chunk) != step:
                raise Unknown("snapshot_changed")
            if first_chunk and not chunk.endswith(b"\n"):
                raise Unknown("incomplete_history")
            first_chunk = False
            lines = (chunk + tail).split(b"\n")
            tail = lines[0] if pos > start else b""
            if len(tail) > MAX_RECORD:
                raise Unknown("record_limit")
            for line in reversed(lines[1:] if pos > start else lines):
                if len(line) > MAX_RECORD:
                    raise Unknown("record_limit")
                if not line.strip():
                    continue
                yield parse_record(line)
        yield header
        if signature(opened) != signature(os.fstat(stream.fileno())) or signature(opened) != signature(path.stat()):
            raise Unknown("snapshot_changed")


def provider_usage(record):
    payload = record["payload"]
    if record["type"] == "token_usage_record":
        usage = payload.get("usage")
    elif record["type"] == "event_msg" and payload.get("type") == "token_count":
        info = payload.get("info")
        if info is None:  # rate-limit-only update, no usage claim
            return None
        if not isinstance(info, dict):
            raise Unknown("unsupported_format")
        usage = info.get("last_token_usage")
    else:
        return None
    if not isinstance(usage, dict) or not usage:
        raise Unknown("unsupported_format")
    known = {"total_tokens", "input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens"}
    if set(usage) - known or any(type(v) is not int or not 0 <= v <= MAX_NUMBER for v in usage.values()):
        raise Unknown("unsupported_format")
    value = usage.get("total_tokens")
    if value is None:
        if not {"input_tokens", "output_tokens"} <= usage.keys():
            raise Unknown("unsupported_format")
        value = usage["input_tokens"] + usage["output_tokens"]
    if not 0 < value <= MAX_NUMBER:
        raise Unknown("unsupported_format")
    if {"input_tokens", "output_tokens"} <= usage.keys() and value != usage["input_tokens"] + usage["output_tokens"]:
        raise Unknown("unsupported_format")
    for child, parent in (("cached_input_tokens", "input_tokens"), ("cache_write_input_tokens", "input_tokens"), ("reasoning_output_tokens", "output_tokens")):
        if child in usage and (parent not in usage or usage[child] > usage[parent]):
            raise Unknown("unsupported_format")
    return value


def possible_boundary(item):
    if item.get("type") == "agent_message":
        return True, False
    if item.get("type") != "message":
        return False, False
    if item.get("role") == "user":
        return True, True
    content = item.get("content")
    if item.get("role") == "assistant" and isinstance(content, list) and len(content) == 1:
        part = content[0]
        if isinstance(part, dict) and part.get("type") in ("input_text", "output_text"):
            text = part.get("text", "")
            # Compatibility communications are serialized JSON. Never interpret
            # a damaged communication as a proven non-boundary.
            if text.lstrip().startswith(("{", "[")):
                value = strict_json(text)
                if isinstance(value, dict) and {"author", "recipient", "content", "trigger_turn"} <= value.keys():
                    if not all(isinstance(value[k], str) for k in ("author", "recipient", "content")) or type(value["trigger_turn"]) is not bool:
                        raise Unknown("unsupported_format")
                    return True, False
    return False, False


def estimate(path, session_id, pending_tool=None):
    """Return only dedicated numeric/enum fields; unknown never carries counts."""
    provider = None
    tail = prior = 0
    found_model = found_boundary = boundary_uncertain = False
    pending_matched = False
    metadata = []
    try:
        if path is None:
            raise Unknown("unreadable_history")
        for record in reverse_records(path, session_id):
            kind = record.get("type")
            payload = record["payload"]
            if record.get("isSidechain"):
                raise Unknown("ownership_unknown")
            if kind == "session_meta":
                metadata.append(payload)
            elif kind == "compacted" or (kind == "event_msg" and payload.get("type") == "context_compacted"):
                raise Unknown("compacted_history")
            elif kind == "event_msg" and payload.get("type") in ("thread_rolled_back", "history_replaced"):
                raise Unknown("incomplete_history")
            elif kind == "event_msg" and payload.get("type") not in NEUTRAL_EVENTS | {"token_count"}:
                raise Unknown("unsupported_format")
            elif kind not in ("response_item", "event_msg", "turn_context", "token_usage_record"):
                raise Unknown("unsupported_format")
            observed = provider_usage(record)
            if provider is None and observed is not None:
                if found_model:
                    raise Unknown("stale_usage")
                try:
                    stamp = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                    age = (datetime.now(timezone.utc) - stamp).total_seconds()
                    if stamp.tzinfo is None or not 0 <= age <= MAX_USAGE_AGE:
                        raise ValueError
                except (KeyError, ValueError, TypeError, AttributeError):
                    raise Unknown("stale_usage") from None
                provider = observed
            if kind != "response_item":
                continue
            item_kind = payload.get("type")
            count = item_tokens(payload)
            model = item_kind in MODEL_ITEMS or (item_kind == "message" and payload.get("role") == "assistant")
            if not found_model and not model:
                if item_kind in ("function_call_output", "custom_tool_call_output"):
                    validate_output_limit(record, payload)
                    if pending_tool is not None and payload.get("call_id") == pending_tool.get("tool_use_id"):
                        if not isinstance(pending_tool.get("tool_response"), str) or payload.get("output") != pending_tool["tool_response"]:
                            raise Unknown("pending_output_unknown")
                        pending_matched = True
                tail += count
            found_model = found_model or model
            if found_boundary and item_kind == "reasoning":
                prior += count
            if not found_boundary:
                found_boundary, boundary_uncertain = possible_boundary(payload)
        if len(metadata) != 1:
            raise Unknown("ownership_unknown")
        owned_metadata(metadata[0], session_id)
        if pending_tool is not None and not pending_matched:
            raise Unknown("pending_output_unknown")
        if provider is None or not found_model or not found_boundary:
            raise Unknown("incomplete_history")
        lower = provider + tail
        if lower + prior > MAX_NUMBER:
            raise Unknown("unsupported_format")
        return {"estimate_state": "estimated", "estimate_provider_tokens": provider,
                "estimate_local_tail_tokens": tail, "estimate_prior_reasoning_tokens": prior,
                "estimate_lower_tokens": lower, "estimate_upper_tokens": lower + prior,
                "estimate_reason": "server_reasoning_and_boundary_unknown" if boundary_uncertain else "server_reasoning_unknown"}
    except Exception as error:  # observational isolation, including future/malformed nested structures
        reason = str(error) if isinstance(error, Unknown) and str(error) in REASONS else "unreadable_history"
        return {"estimate_state": "unknown", "estimate_reason": reason}
