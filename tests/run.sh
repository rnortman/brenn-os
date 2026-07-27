#!/usr/bin/env bash
#
# Test runner.
#
#   tests/run.sh <suite>
#
# A suite is a directory of independent `*.test.sh` scripts. Each is run in its
# own process; its exit status is the verdict:
#
#   0   passed
#   77  skipped (a precondition the runner cannot supply, e.g. no built image)
#   *   failed
#
# A suite in which every test skipped exits non-zero. A lane that reports
# success without having checked anything is worse than no lane.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

SKIP_STATUS=77

usage() {
	echo "usage: $(basename "$0") <suite>" >&2
	echo "suites:" >&2
	find "${repo_root}/tests" -mindepth 1 -maxdepth 1 -type d ! -name lib \
		-printf '  %f\n' 2>/dev/null | sort >&2
}

suite=${1:-}
case "$suite" in
	"")
		usage
		exit 1
		;;
	-h | --help)
		usage
		exit 0
		;;
esac

suite_dir="${repo_root}/tests/${suite}"
if [ ! -d "$suite_dir" ]; then
	echo "run: no such suite: ${suite}" >&2
	usage
	exit 1
fi

mapfile -t tests < <(find "$suite_dir" -maxdepth 1 -name '*.test.sh' | sort)
if [ ${#tests[@]} -eq 0 ]; then
	echo "run: suite '${suite}' contains no tests" >&2
	exit 1
fi

export BRENN_REPO_ROOT="$repo_root"
export BRENN_TESTS_LIB="${repo_root}/tests/lib"
export BRENN_PROFILE="${BRENN_PROFILE:-reachy}"

# Somewhere for what a lane keeps for the length of a run and no longer — the
# device lane's shared ssh connection is the one thing that needs it. Per run
# rather than per machine, so that nothing one run leaves behind is picked up by
# the next.
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
export BRENN_TEST_RUN_DIR="$run_dir"

passed=0
skipped=0
failed=0
failed_names=()

echo "1..${#tests[@]}"

n=0
for t in "${tests[@]}"; do
	n=$((n + 1))
	name=$(basename "$t" .test.sh)
	out=$(mktemp)
	status=0
	bash "$t" >"$out" 2>&1 || status=$?

	case "$status" in
		0)
			passed=$((passed + 1))
			echo "ok ${n} - ${name}"
			;;
		"$SKIP_STATUS")
			skipped=$((skipped + 1))
			echo "ok ${n} - ${name} # SKIP"
			;;
		*)
			failed=$((failed + 1))
			failed_names+=("$name")
			echo "not ok ${n} - ${name}"
			;;
	esac

	sed 's/^/    /' "$out"
	rm -f "$out"
done

echo "# ${suite}: ${passed} passed, ${failed} failed, ${skipped} skipped"

if [ "$failed" -gt 0 ]; then
	echo "# failed: ${failed_names[*]}"
	exit 1
fi

if [ "$passed" -eq 0 ]; then
	echo "# every test in '${suite}' skipped — the suite checked nothing" >&2
	exit 1
fi

exit 0
