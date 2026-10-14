#!/usr/bin/env python3
"""Plan-usage fixture logs for the limit-pace tests, relative to the real clock.

  limit_pace_fixture.py codex  USED,USED,… [--span-h H] [--elapsed-h H] [--age-m M] [--tag T]
  limit_pace_fixture.py claude USED,USED,… [--span-h H] [--elapsed-h H] [--age-m M] [--stage S] [--tag T]
  limit_pace_fixture.py clear

The samples are spread evenly over the last --span-h hours, the newest --age-m minutes ago; the week window's reset is
set so that --elapsed-h hours of it had passed at the newest sample. Codex: one rollout under $CODEX_HOME/sessions with
`token_count` events. Claude: one headless agent log per sample under $AGENT_HUB_HOME/<stage>/agents/fx-<i>/, its
mtime at the sample time (the event has no time of its own). --tag T writes a second series next to the first (another
rollout, other log directories), e.g. the old and the new instance of a window that restarted.
"""
import argparse
import datetime as dt
import json
import os
import shutil
import time
from pathlib import Path

WEEK_H = 168


def series(a):
    used = [float(x) for x in a.used.split(",")]
    now = time.time()
    last = now - a.age_m * 60
    step = a.span_h * 3600 / max(1, len(used) - 1)
    times = [last - (len(used) - 1 - i) * step for i in range(len(used))]
    resets = last + (WEEK_H - a.elapsed_h) * 3600
    return list(zip(used, times)), resets


def codex(a):
    pts, resets = series(a)
    folder = Path(os.environ["CODEX_HOME"]) / "sessions" / "2026" / "10" / "14"
    folder.mkdir(parents=True, exist_ok=True)
    lines = [{"type": "session_meta", "payload": {"id": "fx-limit-pace", "source": "cli"}}]
    for used, t in pts:
        stamp = dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        lines.append({"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
            "limit_id": "codex", "primary": {"used_percent": used, "window_minutes": 10080, "resets_at": int(resets)},
            "secondary": None}}})
    path = folder / f"rollout-fx-limit-pace{'-' + a.tag if a.tag else ''}.jsonl"
    path.write_text("".join(json.dumps(x) + "\n" for x in lines))


def claude(a):
    pts, resets = series(a)
    root = Path(os.environ["AGENT_HUB_HOME"]) / a.stage / "agents"
    for i, (used, t) in enumerate(pts):
        d = root / f"fx-{a.tag + '-' if a.tag else ''}{i}"
        d.mkdir(parents=True, exist_ok=True)
        ev = {"type": "rate_limit_event", "rate_limit_info": {"status": "allowed", "unifiedWindows": {
            "five_hour": {"utilization": 0.1, "resetsAt": int(t + 3 * 3600)},
            "seven_day": {"utilization": used / 100, "resetsAt": int(resets)}}}}
        log = d / "log.jsonl"
        log.write_text(json.dumps({"type": "system", "subtype": "init"}) + "\n" + json.dumps(ev) + "\n")
        os.utime(log, (t, t))


def clear(_):
    shutil.rmtree(Path(os.environ["CODEX_HOME"]) / "sessions", ignore_errors=True)
    for d in Path(os.environ["AGENT_HUB_HOME"]).glob("*/agents/fx-*"):
        shutil.rmtree(d, ignore_errors=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("what", choices=("codex", "claude", "clear"))
    p.add_argument("used", nargs="?", default="")
    p.add_argument("--span-h", type=float, default=6)
    p.add_argument("--elapsed-h", type=float, default=40)
    p.add_argument("--age-m", type=float, default=1)
    p.add_argument("--stage", default="fx-usage")
    p.add_argument("--tag", default="")
    a = p.parse_args()
    {"codex": codex, "claude": claude, "clear": clear}[a.what](a)


if __name__ == "__main__":
    main()
