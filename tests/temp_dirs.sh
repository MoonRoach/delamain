# Shared ownership of temporary files for standalone tests and the suite harness.
# Source once, before allocating fixtures. Custom EXIT traps must call test_cleanup last.
TEST_TMP_BASE=${TMPDIR:-/tmp}
TEST_TMP_ROOT=$(command mktemp -d "${TEST_TMP_BASE%/}/delamain-test.XXXXXX") || exit 1
export TMPDIR=$TEST_TMP_ROOT
test_cleanup(){ rm -rf "$TEST_TMP_ROOT"; }
trap test_cleanup EXIT
# BSD mktemp's default template does not honour TMPDIR on every macOS version.
# Keep plain `mktemp -d` allocations inside the owned root on both BSD and GNU.
mktemp(){
  if [ "$#" = 1 ] && [ "$1" = -d ]; then
    command mktemp -d "$TEST_TMP_ROOT/tmp.XXXXXX"
  else
    command mktemp "$@"
  fi
}
