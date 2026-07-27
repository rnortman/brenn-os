# Assertion helpers for `*.test.sh` scripts. Source, don't execute.
#
# A test script makes any number of assertions and ends with `t_done`. Each
# assertion prints a line; failures print what was expected next to what was
# found, because on this project a surprising value is the finding, not noise
# to be silenced.

# shellcheck shell=bash

t_failures=0

t_pass() {
	echo "PASS  $1"
}

t_fail() {
	t_failures=$((t_failures + 1))
	echo "FAIL  $1"
	shift
	local line
	for line in "$@"; do
		echo "        ${line}"
	done
}

# Skip the whole test. The runner reports it and holds the suite to account for
# having checked nothing.
#
# Past a recorded failure a skip is a lie, and the expensive kind: the failure
# is already on screen, but the script exits 77 and the suite counts it as
# checked nothing rather than as red. So a failure already recorded outranks any
# later missing precondition, and the run ends as the failure it is.
t_skip() {
	if [ "$t_failures" -gt 0 ]; then
		echo "NOSKIP  ${t_failures} failure(s) stand; would have skipped: $*"
		t_done
	fi
	echo "SKIP  $*"
	exit 77
}

t_require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 ||
			t_skip "requires ${cmd}, which is not installed"
	done
}

# Require a file inside the pinned builder submodule. Its absence has two
# meanings and they are not interchangeable: an empty checkout cannot answer the
# question and skips with the command that fixes it, while a checked-out builder
# missing the file is itself the finding — a bump moved or renamed it — and so
# fails and ends the test. Skipping the second case would quietly retire the
# assertion the caller exists to make. `what` names the property being held;
# `consequence` says what the move costs the caller.
t_builder_file() {
	local path=$1 what=$2 consequence=$3
	[ -f "$path" ] && return 0
	if [ -z "$(ls -A "${BRENN_REPO_ROOT}/rpi-image-gen" 2>/dev/null)" ]; then
		t_skip "the builder is not checked out — run: git submodule update --init"
	fi
	t_fail "$what" "nothing at ${path} — ${consequence}"
	t_done
}

t_eq() {
	local desc=$1 actual=$2 expected=$3
	if [ "$actual" = "$expected" ]; then
		t_pass "$desc"
	else
		t_fail "$desc" "expected: ${expected}" "actual:   ${actual}"
	fi
}

# Multi-line comparison, reported as a diff so a one-character drift is
# readable.
t_eq_text() {
	local desc=$1 actual=$2 expected=$3
	if [ "$actual" = "$expected" ]; then
		t_pass "$desc"
		return
	fi
	t_fail "$desc"
	diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") |
		sed 's/^/        /' || true
}

t_contains() {
	local desc=$1 haystack=$2 needle=$3
	if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
		t_pass "$desc"
	else
		t_fail "$desc" "missing line: ${needle}"
	fi
}

t_le() {
	local desc=$1 actual=$2 limit=$3
	if [ "$actual" -le "$limit" ]; then
		t_pass "${desc} (${actual} <= ${limit})"
	else
		t_fail "$desc" "limit:  ${limit}" "actual: ${actual}"
	fi
}

t_ge() {
	local desc=$1 actual=$2 floor=$3
	if [ "$actual" -ge "$floor" ]; then
		t_pass "${desc} (${actual} >= ${floor})"
	else
		t_fail "$desc" "floor:  ${floor}" "actual: ${actual}"
	fi
}

t_done() {
	if [ "$t_failures" -gt 0 ]; then
		exit 1
	fi
	exit 0
}
