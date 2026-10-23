#!/bin/bash
# Offline-only fixtures; never inspect a live Codex session or call a provider.
set -euo pipefail
. "$(dirname "$0")/isolate.sh"
T="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 "$T/test_codex_context_accounting.py" -v
python3 "$T/test_codex_context_observation.py" -v
