#!/bin/bash
# The native lifecycle pair is explicit SKIP on Linux, including WSL.
set -eu
. "$(dirname "$0")/isolate.sh"
cd "$(dirname "$0")/.."
python3 -B tests/test_worker_proxy_caller_lifecycle.py -v
