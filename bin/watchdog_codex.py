"""Codex watchdog boundary: queue only a confirmed, idle app hub's own thread.

`hub start`/`takeover` record host: codex-app only from the current app session.
Terminal and legacy/unknown hosts remain notify-only, regardless of rollout source.

The 0.160.0 scratch control proved that queue starts an idle app-server turn.
A notLoaded reply is local to one server, not a global writer lock. Never use
exec resume here. R4 accepts only a final, own-turn server_overloaded error;
completion, interruption, quota/auth and untyped errors never authorize retry.
"""
from __future__ import annotations

from datetime import datetime, timezone
import contextlib
import json
import shlex
import subprocess
from uuid import UUID

import codex_rollouts
import codex_sessions
import autopilot
import engines
import hubcore as hc
import watchdog_receipts as receipts


def _session(rec: dict) -> str | None:
    """Use the recorded thread UUID, never a name, --last, or another thread."""
    sid = rec.get("cli_session_id") or rec.get("session")
    try:
        return sid if isinstance(sid, str) and str(UUID(sid)) == sid.lower() else None
    except ValueError:
        return None


def retryable_turn(path, sid: str, now: datetime) -> dict | None:
    """Bounded persisted evidence: only terminal overload of the last own turn is retryable.

    A runtime ErrorNotification may be recoverable; task_complete.error instead
    records the final outcome. Require matching start/id and exclude inherited
    history, partial writes and any subsequent user/turn boundary.
    """
    def stamp(raw):
        try:
            t = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            return t.astimezone(timezone.utc) if t.tzinfo else None
        except (ValueError, AttributeError, TypeError):
            return None
    try:
        with path.open("rb") as f:
            head = json.loads(f.readline(256_001))
            if head.get("type") != "session_meta" or head.get("payload", {}).get("id") != sid:
                return None
            birth = stamp(head.get("timestamp"))
            f.seek(0, 2)
            offset = max(0, f.tell() - 512_000)
            f.seek(offset)
            if offset:
                f.readline()  # discard the first potentially partial line
            data = f.read()
        if birth is None or not data.endswith(b"\n"):
            return None
        started, started_time, candidate = None, None, None
        for line in data.splitlines():
            ev = json.loads(line)
            payload = ev.get("payload")
            if not isinstance(payload, dict):
                return None
            if ev.get("type") == "response_item" and payload.get("role") == "user":
                candidate = None  # input of an already started turn preserves its start
            if ev.get("type") != "event_msg":
                continue
            kind, at = payload.get("type"), stamp(ev.get("timestamp"))
            if kind == "user_message":
                candidate = None
            elif kind in ("turn_aborted", "error"):
                started, candidate = None, None
            elif kind == "task_started":
                started = payload if at and birth <= at <= now else None
                started_time = at
                candidate = None
            elif kind == "task_complete":
                candidate = None
                error = payload.get("error")
                turn = payload.get("turn_id")
                if (started and isinstance(turn, str) and turn and turn == started.get("turn_id")
                        and type(payload.get("started_at")) is int
                        and payload["started_at"] >= int(birth.timestamp())
                        and payload["started_at"] == started.get("started_at")
                        and type(payload.get("completed_at")) is int
                        and payload["started_at"] <= payload["completed_at"] <= now.timestamp()
                        and isinstance(error, dict) and error.get("codex_error_info") == "server_overloaded"
                        and at and started_time <= at <= now):
                    candidate = {"at": at, "turn_id": turn, "error": "server_overloaded"}
                started = None
        return candidate
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def state(stage: str, rec: dict, now: datetime) -> dict:
    """Unknown liveness or host means notify. The core handles detached agents."""
    result = {"busy": None, "last_activity": None, "dead_turn": None,
              "transport": "notify", "why": "no recorded Codex thread UUID"}
    sid = _session(rec)
    if sid is None:
        return result
    rollout = codex_rollouts.INDEX.session(sid)
    if rollout:
        result["last_activity"] = datetime.fromtimestamp(rollout[2], timezone.utc)
    status = codex_sessions.runtime_status(sid, rec.get("cwd"))
    status = status if isinstance(status, str) else None
    result["busy"] = {"active": True, "idle": False}.get(status)
    if status != "idle":
        result["why"] = ("Codex thread is active" if status == "active" else
                         "notLoaded does not exclude another rollout writer; resume disabled" if status == "notLoaded" else
                         "Codex runtime status is unknown or in error")
    elif rec.get("kind") == "desktop" or str(rec.get("session", "")).startswith("local_"):
        result["why"] = "Desktop hubs are notify-only"
    elif codex_sessions.detached(stage, rec):
        result["why"] = "detached hubs use the core's agent-send path"
    elif rec.get("host") != "codex-app":
        # Rollout source is creation provenance, not the current host: a TUI can
        # resume a vscode thread. Legacy records must not guess app vs terminal.
        result["why"] = "terminal or unconfirmed Codex host; require host=codex-app"
    elif rollout is None:
        result["why"] = "no rollout activity evidence for the recorded thread"
    else:
        result["transport"] = "codex-queue"
        result["why"] = "confirmed app hub is idle; queue starts a turn on Codex 0.160.0"
        result["dead_turn"] = retryable_turn(rollout[0], sid, now)
    return result


def wake_guard(stage: str, rec: dict, now: datetime) -> str:
    """Fresh registry/quiet/handoff checks, shared with the native bridge; no runtime inference."""
    current = hc.roles_load(stage)["roles"].get("hub")
    if current != rec or _session(current or {}) != _session(rec):
        return "hub registry changed or was retired; wake cancelled"
    if current.get("engine") != "codex" or current.get("host") != "codex-app":
        return "current hub has no confirmed app provenance"
    marker = hc.root() / stage / "do-not-wake.json"
    if marker.exists():
        try:
            value = json.loads(marker.read_text())
            until = value.get("until")
            until = datetime.fromisoformat(until.replace("Z", "+00:00")) if until else None
            if until is None or (until.replace(tzinfo=hc.TZ) if until.tzinfo is None else until) > now:
                return "wake-ups are paused"
        except (OSError, ValueError, TypeError, AttributeError):
            return "do-not-wake marker is unreadable; wake cancelled"
    pending = autopilot.load_state(stage).get("pending")
    if pending and not pending.get("taken_over"):
        return "a successor takeover is pending"
    return ""


def wake(stage: str, rec: dict, text: str, dry_run: bool, expected_error=None, *, wd=None, tick=None) -> dict:
    """Fence registration with takeover's lock order through the actual queue call."""
    wd = wd or receipts.core()
    # The normal tick already holds TickLock and passes its state object so a
    # later tick save cannot overwrite a newly persisted receipt.
    with contextlib.nullcontext() if tick is not None else wd.TickLock(take=not dry_run) as lock:
        if tick is None:
            if not lock.held:
                return {"ok": False, "how": "notify", "detail": "another watchdog tick/attempt is running"}
            tick = wd.Tick(dry_run, True)
        with contextlib.nullcontext() if dry_run else autopilot.state_lock(stage):
            with contextlib.nullcontext() if dry_run else hc.roles_lock(stage):
                return _wake_locked(stage, rec, text, dry_run, expected_error, wd=wd, tick=tick)


def _wake_locked(stage: str, rec: dict, text: str, dry_run: bool, expected_error=None, *, wd, tick) -> dict:
    """Recheck liveness and host immediately before a same-thread queue; no fallback."""
    codex_rollouts.INDEX.checked = None  # a resumed thread may have a newer rollout
    current = state(stage, rec, datetime.now(timezone.utc))
    if current["busy"] is not False or current["transport"] != "codex-queue":
        return {"ok": False, "how": "notify", "detail": current["why"]}
    if expected_error is not None and current["dead_turn"] != expected_error:
        return {"ok": False, "how": "notify", "detail": "failed turn was superseded; retry cancelled"}
    why = wake_guard(stage, rec, datetime.now(timezone.utc))
    if why:
        return {"ok": False, "how": "notify", "detail": why}
    sid = _session(rec)
    fresh = wd.load_state()
    # Keep even a refusing caller current: the enclosing tick saves it again.
    if "uuid_receipts" in fresh:
        tick.state["uuid_receipts"] = fresh["uuid_receipts"]
    why = receipts.guard(wd, fresh, sid, tick.now, stage=stage)
    if why:
        return {"ok": False, "how": "notify", "detail": why}
    claimed = None
    try:
        argv = [engines.codex_bin(rec.get("cwd")), "queue", "--thread", sid, "--message", text]
        how = shlex.join([*argv[:3], sid[:8], *argv[4:]])
        if dry_run:
            return {"ok": True, "how": how, "detail": "dry run; no message queued"}
        claimed = receipts.cli_claim(wd, tick, sid)
        proc = subprocess.run(argv, cwd=rec.get("cwd") or None, env=hc.child_env(),
                              capture_output=True, text=True, errors="replace", timeout=20)
    except subprocess.TimeoutExpired:
        return {"ok": False, "how": how, "detail": "queue outcome unknown: TimeoutExpired"}
    except (hc.Failure, hc.UsageError, OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "how": locals().get("how", "codex queue"),
                "detail": f"queue failed: {type(exc).__name__}"}
    # A signal or generic nonzero exit can follow delivery. Only the CLI's
    # accepted-success outcome proves this uncertain receipt can be closed.
    if proc.returncode == 0:
        receipts.cli_finish(wd, tick, claimed)
    output = (proc.stderr if proc.returncode else proc.stdout).strip().splitlines()
    detail = output[0][:500] if output else f"queue exit {proc.returncode}"
    # Keep the local action summary's IDs abbreviated too.
    detail = detail.replace(sid, sid[:8])
    return {"ok": proc.returncode == 0, "how": how, "detail": detail}
