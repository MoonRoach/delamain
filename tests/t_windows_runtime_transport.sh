#!/bin/bash
# Offline transport and bridge-policy controls. Native PowerShell runs separately on Windows.
set -eu
cd "$(dirname "$0")/.."
python3 -B tests/test_windows_runtime_transport.py -v
python3 -B tests/test_desktop_bridge.py -v
