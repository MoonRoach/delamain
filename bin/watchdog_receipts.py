"""UUID delivery receipts shared by the native consumer and the local CLI tick.

Call guards and mutations under watchdog.TickLock. This is a local file fence,
not an atomic transaction with an app API or a distributed writer lock.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import sys
from uuid import UUID, uuid4

import codex_rollouts
import hubcore as hc


def recipient_activity(path, sid, since, now):
    """Only a new own turn proves recipient progress; work/registration/file touches do not."""
    if path is None or since is None:
        return False
    try:
        with path.open("rb") as f:
            head = json.loads(f.readline(256_001))
            birth = codex_rollouts.epoch(head.get("timestamp"))
            if head.get("type") != "session_meta" or head.get("payload", {}).get("id") != sid or birth is None:
                return False
            f.seek(0, 2); offset = max(0, f.tell() - 512_000); f.seek(offset)
            if offset:
                f.readline()
            data = f.read()
        if not data.endswith(b"\n"):
            return False
        events = [json.loads(line) for line in data.splitlines()]
        for ev in events:
            payload = ev.get("payload")
            if ev.get("type") != "event_msg" or not isinstance(payload, dict) or payload.get("type") != "task_started":
                continue
            at = codex_rollouts.epoch(ev.get("timestamp")); started = payload.get("started_at")
            if (type(started) is int and at is not None and isinstance(payload.get("turn_id"), str) and payload["turn_id"]
                    and started >= max(birth, since.timestamp())
                    and since.timestamp() < at <= now.timestamp() and started <= at):
                return True
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return False


def core():
    """Load the existing watchdog lock/state implementation for direct CLI callers."""
    name = "watchdog_receipt_core"
    if name not in sys.modules:
        loader = importlib.machinery.SourceFileLoader(name, str(hc.BIN / "watchdog"))
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
        sys.modules[name] = mod
        loader.exec_module(mod)
    return sys.modules[name]


def remember(state, episode):
    ledger = state.setdefault("uuid_receipts", {})
    if not isinstance(ledger, dict):
        raise hc.Failure("UUID receipt ledger is malformed; wake cancelled")
    # Carry forward pre-ledger native attempts before a stage actor is replaced.
    for saved in state["stages"].values():
        old = saved.get("native_episode")
        if isinstance(old, dict) and isinstance(old.get("session"), str):
            ledger.setdefault(old["session"].lower(), dict(old))
    ledger[episode["session"].lower()] = dict(episode)


def guard(wd, state, sid, now, *, stage=None, native=False):
    """Unknown outcomes survive actor changes, backoff and new work until own-turn progress."""
    ledger = state.get("uuid_receipts", {})
    if not isinstance(ledger, dict):
        return "UUID receipt ledger is malformed; wake cancelled"
    for key, value in ledger.items():
        try:
            if (not isinstance(value, dict) or str(UUID(key)) != key.lower()
                    or str(value.get("session", "")).lower() != key.lower()):
                return "UUID receipt ledger entry is malformed; wake cancelled"
        except (ValueError, TypeError, AttributeError):
            return "UUID receipt ledger entry is malformed; wake cancelled"
    records = [(None, value) for value in ledger.values()]
    for other_stage, saved in state["stages"].items():
        if "native_episode" in saved and saved["native_episode"] is not None:
            records.append((other_stage, saved["native_episode"]))
        # Preserve pre-ledger CLI timeouts until recipient progress as well.
        hub = saved.get("hub")
        ep = hub.get("episode") if isinstance(hub, dict) else None
        if isinstance(ep, dict) and str(ep.get("result", "")).startswith("failed: queue outcome unknown:"):
            records.append((other_stage, {**ep, "session": hub.get("session"), "result": "unknown"}))
    rollout = codex_rollouts.INDEX.session(sid)
    for other_stage, ep in records:
        if not isinstance(ep, dict) or not isinstance(ep.get("session"), str):
            return "UUID receipt is malformed; wake cancelled"
        if ep["session"].lower() != sid.lower():
            continue
        result = ep.get("result")
        if result not in ("unknown", "sent", "failed", "completed-skip"):
            return "UUID receipt outcome is malformed; wake cancelled"
        acted = wd.parse_ts(ep.get("acted_at"))
        progressed = recipient_activity(rollout[0] if rollout else None, sid, acted, now)
        if result == "unknown" and not progressed:
            return "the UUID has unknown delivery with no verified recipient turn progress"
        if progressed or result == "completed-skip":
            continue
        # The native candidate handles its own identity/work-specific cooldown.
        if native and other_stage == stage:
            continue
        nxt = wd.parse_ts(ep.get("next_try_at"))
        if nxt is None:
            return "UUID receipt cooldown is malformed; wake cancelled"
        if now < nxt:
            return "the UUID has a cooling delivery attempt"
    return ""


def cli_claim(wd, tick, sid):
    token = uuid4().hex
    claimed_at = wd.clock()  # the tick may have spent time observing other stages/RPCs
    ep = {"session": sid, "attempt": token, "result": "unknown",
          "acted_at": wd.iso(claimed_at), "next_try_at": wd.iso(claimed_at + tick.wake_after)}
    remember(tick.state, ep)
    wd.save_state(tick.state)  # persist before queue: interruption or timeout keeps the UUID fenced
    return ep


def cli_finish(wd, tick, ep):
    # Only an explicit queue outcome closes the uncertain receipt. Core episodes
    # continue to implement the standalone tick's existing known-outcome backoff.
    tick.state["uuid_receipts"].pop(ep["session"].lower())
    wd.save_state(tick.state)
