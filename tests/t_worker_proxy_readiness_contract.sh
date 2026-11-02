#!/bin/bash
# Offline process ownership contracts; never invokes Windows or a real AI CLI.
set -eu
. "$(dirname "$0")/isolate.sh"
cd "$(dirname "$0")/.."
python3 -B tests/test_worker_proxy_readiness_contract.py -v
