#!/bin/bash
set -eu
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
python3 "$(dirname "$0")/codex_hook_runtime.py"
