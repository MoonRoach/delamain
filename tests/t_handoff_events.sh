#!/bin/bash
# Picked up automatically by run_all.sh's tests/t_*.sh discovery.
set -euo pipefail
T="$(cd "$(dirname "$0")" && pwd)"
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/home" "$S/tmp"
export HOME="$S/home" AGENT_HUB_HOME="$S/home/hub-home" TMPDIR="$S/tmp"
export PYTHONDONTWRITEBYTECODE=1
python3 "$T/test_handoff_events.py"
echo 'PASS handoff events: schema, privacy, bounds, path safety, IO and concurrency'
