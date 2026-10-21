#!/bin/bash
# Offline transport and bridge-policy controls. Native PowerShell runs separately on Windows.
set -eu
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
cd "$(dirname "$0")/.."
python3 -B tests/test_windows_runtime_transport.py -v
python3 -B tests/test_desktop_bridge.py -v
