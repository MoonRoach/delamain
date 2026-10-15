#!/bin/bash
# Run every tests/t_*.sh, in parallel (TEST_JOBS at a time, default twice the CPU count, at least 8), each with its own HOME, AGENT_HUB_HOME and
# TMPDIR in throw-away directories, so no test can read or write a real hub home and no two scripts share a path. Prints
# one summary line per script, sorted by name, and exits non-zero if any script fails.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; B="$(cd "$T/../bin" && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
export HOME="$(mktemp -d)"; export AGENT_HUB_HOME="$HOME/hub-home"; export XDG_CONFIG_HOME="$HOME/.config" DELAMAIN_TEST_SANDBOX="$HOME"
# Positive control: the tools honour AGENT_HUB_HOME, and without it they fall back to $HOME/agent-hub — of a throw-away
# HOME, never the real one; a HOME of its own, run from it (no repository's .agent-hub/ around): a stage in the test
# HOME's ~/agent-hub would make every test's stage-a "a stage in another home".
AGENT_HUB_TZ=UTC "$B/jlog" --stage stage-a --tag probe "env control" > /dev/null
ls "$AGENT_HUB_HOME"/stage-a/coordinator/work/journal-*.md > /dev/null 2>&1; ctl1=$?
CTL_HOME="$(mktemp -d)"
( unset AGENT_HUB_HOME; cd "$CTL_HOME" && HOME="$CTL_HOME" AGENT_HUB_TZ=UTC "$B/jlog" --stage stage-a --tag probe "default control" > /dev/null )
ls "$CTL_HOME"/agent-hub/stage-a/coordinator/work/journal-*.md > /dev/null 2>&1; ctl2=$?
echo "control: AGENT_HUB_HOME honoured=$([ $ctl1 = 0 ] && echo yes || echo NO); default ~/agent-hub under a test HOME=$([ $ctl2 = 0 ] && echo yes || echo NO) ($CTL_HOME)"
SLOW_FIRST="t_jwait t_autopilot t_agent t_agent_top t_reviewers t_discipline t_cli_models"   # start the long ones first
# the scripts mostly sleep and wait for child processes, so run more of them than there are CPUs (at least 8)
CPUS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
JOBS="${TEST_JOBS:-$((CPUS * 2 > 8 ? CPUS * 2 : 8))}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=8;; esac
run_one() {  # run_one <script>: its own sandbox, log and exit-code file under $OUT
  t="$1"; name=$(basename "$t" .sh)
  S=$(mktemp -d); mkdir -p "$S/home" "$S/tmp"
  export HOME="$S/home" AGENT_HUB_HOME="$S/home/hub-home" TMPDIR="$S/tmp" XDG_CONFIG_HOME="$S/home/.config" DELAMAIN_TEST_SANDBOX="$S"
  bash "$t" > "$OUT/$name.log" 2>&1; echo $? > "$OUT/$name.rc"
  rm -rf "$S"
}
export -f run_one; export OUT
rm -f "$OUT"/t_*.rc   # a reused log directory must not hand back an old exit code
ls "$T"/t_*.sh | awk -v slow="$SLOW_FIRST" 'BEGIN { n = split(slow, a, " "); for (i = 1; i <= n; i++) rank["'"$T"'/" a[i] ".sh"] = i }
  { print (($0 in rank) ? rank[$0] : 99) " " $0 }' | sort -n -s | cut -d' ' -f2- | tr '\n' '\0' \
  | xargs -0 -n1 -P "$JOBS" bash -c 'run_one "$0"'
total=0; failed=0; [ $ctl1 = 0 ] && [ $ctl2 = 0 ] || failed=1
for t in "$T"/t_*.sh; do
  name=$(basename "$t" .sh)
  rc=$(cat "$OUT/$name.rc" 2>/dev/null || echo "missing")   # no exit-code file: the runner itself died, a failure
  p=$(grep -c '^PASS' "$OUT/$name.log" 2>/dev/null); f=$(grep -c '^FAIL' "$OUT/$name.log" 2>/dev/null)
  p=${p:-0}; f=${f:-0}; total=$((total + p + f))
  echo "$name: exit=$rc pass=$p fail=$f"
  if [ "$rc" != 0 ] || [ "$f" != 0 ]; then
    failed=1
    # what failed, in the output itself (CI shows no log files): each FAIL line with the detail printed under it (up to the
    # next PASS/FAIL line), at most 60 lines, and the log's tail
    echo "---- $name: FAIL lines ----"
    awk '/^PASS/ { on = 0 } /^FAIL/ { on = 1 } on' "$OUT/$name.log" 2>/dev/null | head -60 | cut -c1-300
    echo "---- $name: last 20 lines of $OUT/$name.log ----"
    tail -20 "$OUT/$name.log" 2>/dev/null | cut -c1-300
    echo "---- end $name ----"
  fi
done
echo "checks: $total; logs: $OUT; jobs: $JOBS"
exit $failed
