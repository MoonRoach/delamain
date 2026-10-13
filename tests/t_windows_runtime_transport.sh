#!/bin/bash
# Offline transport tests. Native PowerShell controls run separately on Windows.
set -eu
cd "$(dirname "$0")/.."
python3 -B tests/test_windows_runtime_transport.py -v
