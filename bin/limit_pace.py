"""Limit pace: how each engine's plan window is going against its pace, and what to do about it before spending.

Read-only over local logs; no API is queried. Two sources:
  Codex   `token_count.rate_limits` events of the recent rollouts under $CODEX_HOME/sessions (each has a timestamp).
  Claude  the last `rate_limit_event` (`unifiedWindows.seven_day` / `five_hour`) of each headless agent's log.jsonl
          in the hub home; the event has no time of its own, so the log's mtime is the sample time.

The pace model, per window: the share of the window elapsed (100 % = the reset), the usage against it, a burn rate over
the last RECENT_S of samples of the same window instance and the window's average, and the time each rate runs the
window out. Levels: ok, ahead (usage more than AHEAD_PP points ahead of the elapsed share), exhaust (a rate runs it out
before the reset); unknown (no sample) and stale (the latest sample older than STALE_S, or the window reset since).

Advice chooses an engine, equivalent model and effort for this launch from fresh remaining usage. Forecasts describe
risk, not a work schedule. Below 20% remaining, suggest the engine with more room; below 3%, refuse unless --reason
when both engines have fresh data. A model is never swapped silently. An owner-locked stage
(AGENT_HUB_STAGE_ENGINES) gets an ask proposal whose default runs this launch on the locked engine.
Forecasts in the first six hours are low-confidence and cannot by themselves move or refuse a launch.

Settings (hub home config.json or the environment):
  AGENT_HUB_LIMIT_PACE     on (default) | warn (advise, never refuse) | off (no advice at all)
  AGENT_HUB_STAGE_ENGINES  {"<stage>": "codex"} or {"<stage>": {"engine": "codex", "decision": "Q-DL-054"}}: the owner's
                           engine decision for a stage; the advisor never proposes moving that stage's work.
"""
from __future__ import annotations

import datetime as dt
import json
import shlex
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import hubcore as hc

ENGINES = ("claude", "codex")
ENGINE_NAME = {"claude": "Claude", "codex": "Codex"}
LENGTH = {"5h": 5 * 3600, "7d": 7 * 86400}
STALE_S = 3 * 3600            # a sample older than this does not describe the window now
RECENT_S = 6 * 3600           # the burn rate is measured over the samples of this span
MIN_SPAN_S = 3600             # ... when they span at least this much; else the window's average alone
MIN_ELAPSED_S = 3600          # the window's average is meaningless in the window's first hour
SAME_WINDOW_S = 600           # samples whose resets_at differ by more belong to different window instances
LATEST_S = 600                # samples this close to the newest one describe "now" together (a log's mtime is not the
                              # event's time, so parallel logs disagree by a point or by a window instance)
AHEAD_PP = 10                 # usage this many points ahead of the elapsed share is "ahead"
SHORT_REMAINING = 20         # compare engines for this launch below this remaining percentage
EXHAUSTED_REMAINING = 3      # practically exhausted: a hard stop needs fresh observations of both engines
EARLY_WINDOW_S = 6 * 3600    # early-window extrapolation is displayed with low confidence
LOG_HOURS = 12                # logs and rollouts touched within this many hours are read
LOG_MAX = 64                  # at most this many Claude logs ...
ROLLOUT_MAX = 32              # ... and Codex rollouts, newest first
TAIL_BYTES = 256_000
CLAUDE_SCAN_BYTES = 8 * 1024 * 1024  # bounded backwards search for a Claude rate-limit event
CACHE_PARSER_VERSION = 1      # bump when parsing changes so unchanged logs are read again after an upgrade
CONTEXT_CAP = "~200k"
LEVELS = ("ok", "ahead", "exhaust")
TAG = "pace"                  # the journal tag of the advisor's own lines
CLASSES = ("mechanical", "bounded", "judgement")
EFFORT_ORDER = ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")


@dataclass
class Sample:
    used: float               # percent of the window used
    seen_at: float            # epoch of the observation
    resets_at: Optional[float]
    length_s: int


@dataclass
class Pace:
    engine: str
    window: str
    level: str = "unknown"    # unknown | stale | ok | ahead | exhaust
    used: Optional[float] = None
    expected: Optional[float] = None       # the elapsed share of the window, percent
    resets_at: Optional[float] = None
    seen_at: Optional[float] = None
    age_s: Optional[float] = None
    burn_recent: Optional[float] = None    # percent per hour
    burn_avg: Optional[float] = None
    eta: Optional[float] = None            # when the shown rate (recent, else average) runs the window out
    low_confidence: bool = False          # the first six hours of a window
    confirmed: bool = False                # every known rate runs it out before the reset
    burst: bool = False                    # only the recent rate runs it out; the window average holds
    why_stale: str = ""

    @property
    def fresh(self) -> bool:
        return self.level in LEVELS

    @property
    def rank(self) -> int:
        return LEVELS.index(self.level) if self.fresh else -1


# ---------------------------------------------------------------- reading


def _number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf")


def _tail_lines(path: Path, limit: int = TAIL_BYTES) -> list:
    with path.open("rb") as f:
        size = f.seek(0, 2)
        f.seek(max(0, size - limit))
        if size > limit:
            f.readline()
        return f.read(limit).splitlines(keepends=True)


def _claude_lines(path: Path):
    """Complete lines, newest first, reading at most CLAUDE_SCAN_BYTES in fixed chunks.

    Carry the partial leading line into the next chunk; never parse a fragment at the scan boundary.
    A giant line without a newline costs at most the cap, including when the log is still being written.
    """
    with path.open("rb") as f:
        pos = f.seek(0, 2)
        start = max(0, pos - CLAUDE_SCAN_BYTES)
        pending = b""
        while pos > start:
            size = min(TAIL_BYTES, pos - start)
            pos -= size
            f.seek(pos)
            lines = (f.read(size) + pending).split(b"\n")
            pending = lines[0]
            # The last fragment at EOF is an incomplete line; after the first chunk it is empty.
            for line in reversed(lines[1:-1]):
                yield line + b"\n"
            pending += b"\n" if len(lines) > 1 else b""
        if pos == 0 and pending.endswith(b"\n"):
            yield pending


class _Cache:
    """What each log's tail held, by path, size, mtime and parser version: a log only grows, so an unchanged one is not read again
    (agent-top --json runs every few seconds). Kept in the file the caller names (agent-top: in its own cache directory);
    entries of files not seen in a read are dropped, so it never grows beyond the recent logs."""

    def __init__(self, path: Path):
        self.path = path
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self.old = data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            self.old = {}
        self.new: dict = {}

    def get(self, path: Path, st, parse):
        key, stamp = str(path), [st.st_size, st.st_mtime_ns, CACHE_PARSER_VERSION]
        hit = self.old.get(key)
        if isinstance(hit, list) and len(hit) == 2 and hit[0] == stamp and isinstance(hit[1], list):
            got = hit[1]
        else:
            got = parse(path)
        self.new[key] = [stamp, got]
        return got

    def save(self):
        if self.new == self.old:
            return
        try:
            hc.atomic_write(self.path, json.dumps(self.new, separators=(",", ":")) + "\n")
        except OSError:
            pass


def _claude_file(path: Path) -> list:
    """[[window, used, resets_at], …] of the log's last rate_limit_event."""
    for line in _claude_lines(path):
        if not line.endswith(b"\n") or b'"rate_limit_event"' not in line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        info = ev.get("rate_limit_info") if isinstance(ev, dict) else None
        wins = info.get("unifiedWindows") if isinstance(info, dict) else None
        if not isinstance(wins, dict):
            continue
        out = []
        for key, label in (("seven_day", "7d"), ("five_hour", "5h")):
            w = wins.get(key)
            if isinstance(w, dict) and _number(w.get("utilization")) and w["utilization"] >= 0:
                out.append([label, 100 * w["utilization"], w["resetsAt"] if _number(w.get("resetsAt")) else None])
        return out
    return []


def claude_samples(home: Optional[Path] = None, now: Optional[float] = None, cache: Optional[_Cache] = None) -> dict:
    """{"7d": [Sample…], "5h": […]} from the last rate_limit_event of each recently written headless agent's log."""
    now = time.time() if now is None else now
    home = home or hc.root()
    logs = []
    for p in home.glob("*/agents/*/log.jsonl"):
        try:
            st = p.stat()
        except OSError:
            continue
        if st.st_mtime >= now - LOG_HOURS * 3600:
            logs.append((st.st_mtime, p, st))
    out: dict = {"7d": [], "5h": []}
    for mtime, path, st in sorted(logs, key=lambda x: x[0], reverse=True)[:LOG_MAX]:
        try:
            got = cache.get(path, st, _claude_file) if cache else _claude_file(path)
        except OSError:
            continue
        for label, used, resets in got:
            out[label].append(Sample(used, mtime, resets, LENGTH[label]))
    return out


def _codex_file(path: Path) -> list:
    """[[window, used, seen_at, resets_at, length_s], …] of every account-bucket rate-limit event in the tail."""
    import codex_rollouts
    out = []
    for line in _tail_lines(path):
        if not line.endswith(b"\n") or b'"rate_limits"' not in line:
            continue
        try:
            ev = json.loads(line)
            payload = ev.get("payload")
            if ev.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            info = payload.get("rate_limits")
            seen = codex_rollouts.epoch(ev.get("timestamp"))
            if not isinstance(info, dict) or seen is None or (info.get("limit_id") or "codex") != "codex":
                continue
        except (ValueError, AttributeError):
            continue
        for key in ("primary", "secondary"):
            w = info.get(key)
            if not isinstance(w, dict) or not _number(w.get("used_percent")) or not _number(w.get("window_minutes")):
                continue
            minutes = int(w["window_minutes"])
            label = {300: "5h", 10080: "7d"}.get(minutes, f"{minutes}m")
            out.append([label, float(w["used_percent"]), seen, w["resets_at"] if _number(w.get("resets_at")) else None,
                        minutes * 60])
    return out


def codex_samples(now: Optional[float] = None, cache: Optional[_Cache] = None) -> dict:
    """{"7d": [Sample…], …} from every `token_count` rate-limit event of the account bucket (limit_id "codex") in the
    tails of the recently written rollouts. A window is labelled by its length; one of another length gets its own key."""
    import codex_rollouts
    now = time.time() if now is None else now
    out: dict = {}
    records = sorted(codex_rollouts.INDEX.update().records.values(), key=lambda r: r[2], reverse=True)
    for path, _, mtime in records[:ROLLOUT_MAX]:
        if mtime < now - LOG_HOURS * 3600:
            break
        try:
            got = cache.get(path, path.stat(), _codex_file) if cache else _codex_file(path)
        except OSError:
            continue
        for label, used, seen, resets, length in got:
            out.setdefault(label, []).append(Sample(used, seen, resets, length))
    return out


def read_all(now: Optional[float] = None, cache: Optional[Path] = None) -> dict:
    """{engine: {window: Pace}} for both engines, every window that has samples, and the 7d window always. `cache`
    (agent-top, which runs every few seconds) is a file that keeps what each log held; without it nothing is written,
    so a dry run stays a dry run."""
    now = time.time() if now is None else now
    out = {}
    cache = _Cache(cache) if cache else None
    for engine, reader in (("claude", lambda: claude_samples(now=now, cache=cache)),
                           ("codex", lambda: codex_samples(now, cache=cache))):
        try:
            series = reader()
        except Exception:  # noqa: BLE001 — a broken source is "unknown", never a failed spawn or digest
            series = {}
        series.setdefault("7d", [])
        out[engine] = {w: assess(engine, w, s, now) for w, s in series.items()}
    if cache:
        cache.save()
    return out


# ---------------------------------------------------------------- the pace model


def _eta(last: Sample, rate: Optional[float]) -> Optional[float]:
    if last.used >= 100:
        return last.seen_at
    if not rate or rate <= 0:
        return None
    return last.seen_at + (100 - last.used) / rate * 3600


def _latest(samples: list) -> Sample:
    """The sample that stands for "now": among those within LATEST_S of the newest, the window instance with the latest
    resets_at, and in it the highest used (within an instance utilisation only grows, so a lower one is an older
    event under a newer mtime), observed at the newest of them."""
    newest = max(s.seen_at for s in samples)
    near = [s for s in samples if s.seen_at >= newest - LATEST_S]
    resets = [s.resets_at for s in near if s.resets_at is not None]
    if resets:
        top = max(resets)
        near = [s for s in near if s.resets_at is not None and abs(s.resets_at - top) <= SAME_WINDOW_S]
    best = max(near, key=lambda s: (s.used, s.seen_at))
    return Sample(best.used, max(s.seen_at for s in near), best.resets_at, best.length_s)


def assess(engine: str, window: str, samples: list, now: float) -> Pace:
    p = Pace(engine, window)
    if not samples:
        return p
    last = _latest(samples)
    p.used, p.seen_at, p.resets_at, p.age_s = last.used, last.seen_at, last.resets_at, max(0.0, now - last.seen_at)
    if last.resets_at is not None and last.resets_at <= now:
        p.level, p.why_stale = "stale", "the window has reset since the latest sample"
        return p
    if p.age_s > STALE_S:
        p.level, p.why_stale = "stale", f"the latest sample is {_dur(p.age_s)} old"
        return p
    if last.resets_at is None:
        p.level, p.why_stale = "stale", "the sample has no reset time"
        return p
    elapsed = min(max(last.seen_at - (last.resets_at - last.length_s), 0.0), last.length_s)
    p.expected = 100 * elapsed / last.length_s
    p.low_confidence = window == "7d" and elapsed < EARLY_WINDOW_S
    if elapsed >= MIN_ELAPSED_S:
        p.burn_avg = last.used / (elapsed / 3600)
    same = [s for s in samples if s.resets_at is not None and abs(s.resets_at - last.resets_at) <= SAME_WINDOW_S
            and last.seen_at - RECENT_S <= s.seen_at <= last.seen_at]
    first = min(same, key=lambda s: s.seen_at)
    span = last.seen_at - first.seen_at
    if span >= MIN_SPAN_S:
        p.burn_recent = max(0.0, (last.used - first.used) / (span / 3600))
    rates = [r for r in (p.burn_recent, p.burn_avg) if r is not None]
    before = [e is not None and e < last.resets_at for e in (_eta(last, r) for r in rates)]
    p.eta = _eta(last, rates[0]) if rates else None
    p.confirmed = bool(before) and all(before)
    p.burst = any(before) and not p.confirmed
    if p.confirmed or last.used >= 100:
        p.level = "exhaust"
    elif p.burst or last.used - p.expected > AHEAD_PP:
        p.level = "ahead"
    else:
        p.level = "ok"
    return p


# ---------------------------------------------------------------- classes and equivalents


def classify(model: str) -> str:
    m = (model or "").lower()
    if any(k in m for k in ("haiku", "luna", "mini", "nano")):
        return "mechanical"
    if any(k in m for k in ("opus", "fable", "astra")):
        return "judgement"
    return "bounded"


def class_default_effort(engine: str, cls: str) -> Optional[str]:
    """The effort the owner's policy gives routine work of a class: Sol medium, Sonnet high; None: no rule."""
    if cls != "bounded":
        return None
    return "medium" if engine == "codex" else "high"


def equivalent(engine: str, cls: str) -> str:
    """The other engine's equivalent of a class (the owner's table: Opus ↔ Astra or Sol high, Sonnet ↔ Sol medium,
    Haiku ↔ Luna)."""
    if engine == "claude":     # moving Claude work to Codex
        return {"mechanical": "Codex Luna medium", "bounded": "Codex Sol medium",
                "judgement": "Codex Astra high (an executor that decides as it goes: Sol high)"}[cls]
    return {"mechanical": "Claude Haiku high", "bounded": "Claude Sonnet high",
            "judgement": "Claude Opus high"}[cls]


def other(engine: str) -> str:
    return "codex" if engine == "claude" else "claude"


def stage_lock(stage: Optional[str]) -> Optional[dict]:
    """The owner's engine decision for a stage: {"engine": …, "decision": …} or None."""
    if not stage:
        return None
    data = hc.setting_json("AGENT_HUB_STAGE_ENGINES", {})
    rec = data.get(stage) if isinstance(data, dict) else None
    if isinstance(rec, str):
        rec = {"engine": rec}
    if not isinstance(rec, dict) or rec.get("engine") not in ENGINES:
        return None
    return {"engine": rec["engine"], "decision": str(rec.get("decision") or "owner's decision")}


def mode() -> str:
    raw = (hc.setting("AGENT_HUB_LIMIT_PACE") or "on").strip().lower()
    if raw not in ("on", "warn", "off"):
        hc.warn(f"AGENT_HUB_LIMIT_PACE {raw!r}: one of on, warn, off; using on")
        return "on"
    return raw


# ---------------------------------------------------------------- words


def _dur(s: float) -> str:
    s = max(0, int(s))
    if s < 90 * 60:
        return f"{max(1, s // 60)} min"
    if s < 48 * 3600:
        return f"{s / 3600:.1f} h"
    return f"{s / 86400:.1f} d"


def _when(t: float) -> str:
    return dt.datetime.fromtimestamp(t, hc.TZ).strftime("%m-%d %H:%M")


def _pct(x: float) -> str:
    return f"{x:.0f}%"


def room(p: Pace) -> Optional[float]:
    """The burn rate (percent per hour) the rest of the window allows until its reset."""
    if not p.fresh or p.resets_at is None or p.seen_at is None or p.resets_at <= p.seen_at:
        return None
    return max(0.0, 100 - p.used) / ((p.resets_at - p.seen_at) / 3600)


def describe(p: Pace) -> str:
    """One sentence of numbers about a window."""
    name = f"{ENGINE_NAME[p.engine]} {p.window}"
    if p.level == "unknown":
        return f"{ENGINE_NAME[p.engine]}: no plan-usage sample in the logs of the last {LOG_HOURS} h (unknown)"
    if p.level == "stale":
        return f"{name}: {_pct(p.used)} used, data stale ({p.why_stale}): not judged"
    text = f"{name}: {_pct(p.used)} used at {_pct(p.expected)} of the window, reset {_when(p.resets_at)}"
    rates = []
    if p.burn_recent is not None:
        rates.append(f"{p.burn_recent:.1f}%/h over the last {RECENT_S // 3600} h")
    if p.burn_avg is not None:
        rates.append(f"{p.burn_avg:.1f}%/h window average")
    if room(p) is not None:
        rates.append(f"room {room(p):.1f}%/h to the reset")
    if rates:
        text += "; burn " + ", ".join(rates)
    if p.level == "exhaust" and p.eta is not None:
        text += f" — over pace: runs out ~{_when(p.eta)}, {_dur(p.resets_at - p.eta)} before the reset"
    elif p.burst:
        text += (f" — ahead of pace: the last {RECENT_S // 3600} h's burn would run it out before the reset; "
                 "the window average holds")
    else:
        text += " — " + ("ahead of pace" if p.level == "ahead" else "on pace")
    if p.low_confidence:
        text += "; early-window forecast: low-confidence"
    return text + f" (sample {_dur(p.age_s)} old)"


def short(p: Pace) -> str:
    """The numbers of a window in a few words, for an owner question."""
    name = f"{ENGINE_NAME[p.engine]} {p.window}"
    if not p.fresh:
        return f"{name}: {p.level}"
    out = f"{name} {_pct(p.used)} used at {_pct(p.expected)} of the window (reset {_when(p.resets_at)})"
    if p.level == "exhaust" and p.eta is not None:
        out += f", runs out ~{_when(p.eta)}"
    if room(p) is not None and p.burn_recent is not None:
        out += f", burning {p.burn_recent:.1f}%/h against room for {room(p):.1f}%/h"
    return out


def headroom(p: Pace) -> bool:
    return p.fresh and 100 - p.used >= EXHAUSTED_REMAINING


def preferred(p: Pace, q: Pace) -> Pace:
    """Use fresh remaining percentages; forecasts alone never change a launch's engine."""
    if p.fresh and q.fresh and 100 - p.used < SHORT_REMAINING and q.used < p.used:
        return q
    return p


def unverified_exhaustion(p: Pace, q: Pace) -> Optional[str]:
    """Warn about near-empty quota without treating a missing alternative reading as a refusal."""
    if p.fresh and 100 - p.used < EXHAUSTED_REMAINING and not q.fresh:
        return (f"{ENGINE_NAME[p.engine]} is practically exhausted; {ENGINE_NAME[q.engine]} is unverified "
                f'({q.level}): probe it, or launch with --reason "…"')
    return None


def ask_command(stage: str, p: Pace, lock: Optional[dict], q: Optional[Pace], cls: Optional[str]) -> str:
    """A permission for this launch with an executable default, respecting the owner's engine lock."""
    nums = short(p) + ("; " + short(q) if q is not None else "")
    if lock and lock["engine"] == p.engine:
        move = equivalent(p.engine, cls) if cls else f"{ENGINE_NAME[other(p.engine)]} at the equivalent class"
        text = (f"{nums}. Stage {stage} runs on {ENGINE_NAME[p.engine]} only ({lock['decision']}). "
                f"Allow {move} for this launch?")
        default = f"run this launch on the locked engine {ENGINE_NAME[p.engine]}"
    else:
        chosen = preferred(p, q) if q else p
        text = f"{nums}. Run this launch on {ENGINE_NAME[chosen.engine]} at the task's equivalent class?"
        default = f"run this launch on {ENGINE_NAME[chosen.engine]}"
    return f"ask add --stage {shlex.quote(stage)} {shlex.quote(text)} --default {shlex.quote(default)}"


@dataclass
class Advice:
    lines: list = field(default_factory=list)
    refuse: Optional[str] = None      # the refusal text, when the launch must not go ahead without --reason
    stop: bool = False                # the hard-stop case holds (refused, or passed by --reason or the warn mode)
    pace: Optional[Pace] = None


def advise(engine: str, model: str, effort: Optional[str], stage: str, paces: dict, task_class: Optional[str] = None,
           reason: str = "", lock: Optional[dict] = None) -> Advice:
    """Compare engines for this launch, retaining the requested model until an explicit new launch."""
    adv = Advice()
    p = paces.get(engine, {}).get("7d") or Pace(engine, "7d")
    q = paces.get(other(engine), {}).get("7d") or Pace(other(engine), "7d")
    adv.pace = p
    cls = task_class or classify(model)
    five = paces.get(engine, {}).get("5h")
    if five is not None and five.level == "exhaust":
        adv.lines.append(describe(five) + "; consider this window when choosing the engine for this launch")
    if not p.fresh:
        if p.level == "stale":
            adv.lines.append(describe(p) + "; the advisor does not refuse on stale data")
        return adv
    default = class_default_effort(engine, cls)
    waste = (default and effort in EFFORT_ORDER and EFFORT_ORDER.index(effort) > EFFORT_ORDER.index(default)
             and not reason)
    if p.level == "ok" and 100 - p.used >= SHORT_REMAINING and not waste:
        return adv
    adv.lines.insert(0, describe(p))
    if waste:
        adv.lines.append(f"1. waste: routine {cls} work runs at {default} (asked: {effort}); keep {effort} for "
                         'work that needs judgement (--task-class judgement --reason "…")')
    locked = lock is not None and lock["engine"] == engine
    chosen = preferred(p, q)
    warning = unverified_exhaustion(p, q)
    if warning:
        adv.lines.append("2. launch: " + warning)
    elif chosen.engine != engine and locked:
        adv.lines.append(f"2. move: stage {stage} is on {ENGINE_NAME[engine]} by {lock['decision']}; "
                         f"run this launch on the locked engine. {describe(q)}. Ask the owner:")
        adv.lines.append("   " + ask_command(stage, p, lock, q, cls))
    elif chosen.engine != engine:
        adv.lines.append(f"2. move: {describe(q)}; run this as {equivalent(engine, cls)} instead "
                         "(same class, more remaining room for this launch)")
    else:
        adv.lines.append(f"2. launch: run on {ENGINE_NAME[engine]} with the requested model and effort")
    if not q.fresh and 100 - p.used < SHORT_REMAINING and not warning:
        adv.lines.append(f"   headroom on {ENGINE_NAME[q.engine]} is not verified: run a probe there; "
                         "keep this launch on the requested engine meanwhile")
    if q.fresh and 100 - p.used < SHORT_REMAINING and 100 - q.used < SHORT_REMAINING:
        adv.lines.append(f"Both engines have little room; {'the locked engine' if locked else ENGINE_NAME[chosen.engine]} "
                         "may run out before the reset during this work")
    adv.stop = 100 - p.used < EXHAUSTED_REMAINING and q.fresh
    if adv.stop:
        state = ("Both engines are practically exhausted" if not headroom(q) else
                 f"{ENGINE_NAME[engine]} is practically exhausted; {ENGINE_NAME[q.engine]} has room")
        adv.lines.append(state + '; run this launch with --reason "…" if keeping the requested engine')
        if not reason and mode() == "on":
            adv.refuse = f'limit pace: {describe(p)}. {state}. Start this launch with --reason "…" (journalled)'
    return adv


def verdict(p: Pace) -> str:
    if not p.fresh:
        return {"unknown": "no data", "stale": "stale data"}.get(p.level, p.level)
    if p.level == "exhaust":
        return "over pace"
    if p.burst:
        return "ahead of pace (the recent burn; the window average holds)"
    return "ahead of pace" if p.level == "ahead" else "on pace"


def summary(engine: str, paces: dict, stage: Optional[str] = None) -> str:
    """The advisor line of an engine for the hub digest and agent-top: numbers, and the action when off pace."""
    p = paces.get(engine, {}).get("7d") or Pace(engine, "7d")
    q = paces.get(other(engine), {}).get("7d") or Pace(other(engine), "7d")
    if not p.fresh:
        text = describe(p)
    else:
        text = f"{short(p)} — {verdict(p)}" + (f" (sample {_dur(p.age_s)} old)" if p.age_s > 1800 else "")
    five = paces.get(engine, {}).get("5h")
    if five is not None and five.level == "exhaust" and five.eta is not None:
        text += f"; 5h window {_pct(five.used)}, capped ~{_when(five.eta)} until {_when(five.resets_at)}"
    if p.low_confidence:
        text += "; early-window forecast: low-confidence"
    if p.level not in ("ahead", "exhaust") and (not p.fresh or 100 - p.used >= SHORT_REMAINING):
        return text
    return text + ". Advice: " + launch_action(p, q, stage)


def launch_action(p: Pace, q: Pace, stage: Optional[str]) -> str:
    """Task-independent surfaces point to per-launch selection; spawn supplies the actual task class."""
    warning = unverified_exhaustion(p, q)
    if warning:
        return "this launch: " + warning
    lock = stage_lock(stage)
    chosen = preferred(p, q)
    if lock and lock["engine"] == p.engine and chosen.engine != p.engine:
        action = f"this launch stays on {ENGINE_NAME[p.engine]} ({lock['decision']}); ask add to allow another engine"
    elif chosen.engine != p.engine:
        action = f"this launch: consider {ENGINE_NAME[q.engine]} at the equivalent class (agent spawn --dry-run)"
    else:
        action = f"this launch: keep {ENGINE_NAME[p.engine]} at the task's model/effort"
    if p.fresh and q.fresh and 100 - p.used < SHORT_REMAINING and 100 - q.used < SHORT_REMAINING:
        action += "; both short, may run out before the reset"
    if p.fresh and q.fresh and 100 - p.used < EXHAUSTED_REMAINING:
        action += "; practically exhausted: --reason required"
    return action


def compact(engine: str, paces: dict, stage: Optional[str] = None) -> str:
    """Short per-launch context for the hub digest, not a stage work schedule."""
    p = paces.get(engine, {}).get("7d") or Pace(engine, "7d")
    q = paces.get(other(engine), {}).get("7d") or Pace(other(engine), "7d")
    name = f"{ENGINE_NAME[engine]} week"
    if not p.fresh:
        return f"{name}: {verdict(p)}" + (f" ({_pct(p.used)} at the last sample)" if p.used is not None else "")
    text = f"{name} {_pct(p.used)} used at {_pct(p.expected)} elapsed"
    if p.level == "exhaust" and p.eta is not None:
        text += f", runs out ~{_when(p.eta)}"
    text += " — " + ("ahead (recent burn)" if p.burst else verdict(p))
    if p.low_confidence:
        text += " (low-confidence)"
    if p.level == "ok" and 100 - p.used >= SHORT_REMAINING:
        return text
    return text + ": " + launch_action(p, q, stage)


# ---------------------------------------------------------------- crossings


def _crossings_file() -> Path:
    return hc.state_dir() / "limit-pace" / "crossings.json"


def note_crossing(stage: str, p: Pace, write: bool = True, journal: bool = True) -> Optional[str]:
    """When `p` is at a higher level than `stage` was last told for this window instance, the `@hub LIMIT …` line
    (recorded, and written to the stage's journal when `journal`, unless write=False) — once per stage, engine, window
    instance and level. Early low-confidence forecasts are display-only and consume no crossing state.
    A level that falls is not recorded: the next rise in the same window is not a new crossing."""
    if not p.fresh or p.low_confidence or p.rank == 0 or p.resets_at is None:
        return None
    path = _crossings_file()
    key = f"{stage}/{p.engine}/{p.window}"
    with hc.Flock(path.with_suffix(".lock")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                data = {}
        except (OSError, ValueError):
            data = {}
        rec = data.get(key) if isinstance(data.get(key), dict) else {}
        same = _number(rec.get("resets_at")) and abs(rec["resets_at"] - p.resets_at) <= SAME_WINDOW_S
        told = rec.get("level") if same and rec.get("level") in LEVELS else "ok"
        if p.rank <= LEVELS.index(told):
            return None
        text = f"@hub LIMIT {describe(p)} — choose engine/model/effort for this launch: agent spawn --dry-run; forecast is context"
        if write:
            data[key] = {"resets_at": p.resets_at, "level": p.level, "at": time.time()}
            hc.atomic_write(path, json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
            if journal:
                hc.journal_append(stage, TAG, text)
        return text
