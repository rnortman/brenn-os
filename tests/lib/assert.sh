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
t_skip() {
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
