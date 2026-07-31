#!/usr/bin/env bash
#
# The assertion helpers, at the two points where they are more than a wrapper
# around a comparison: where they decide a verdict instead of reporting one, and
# where the report is the only thing standing between a reader and the wrong
# cause.
#
# A skip tells the runner the script checked nothing, and the runner counts that
# as an honest zero. Reached past an assertion that has already failed, that
# verdict is wrong in the most expensive direction: the FAIL is printed, and the
# lane is green anyway. Every dependency skip in the suite sits below some
# assertion that needed no dependency, so which of the two wins belongs to the
# lib rather than to each test that has to remember.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# An empty submodule checkout, which is what a fresh clone has before
# `git submodule update --init`.
fake_root="${work}/repo"
mkdir -p "${fake_root}/rpi-image-gen"

# Driven by a script, because deciding to skip is an exit, which would take this
# test with it.
driver="${work}/driver"
cat >"$driver" <<'DRIVER'
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

if [ -n "${FAIL_FIRST:-}" ]; then
	t_fail "an assertion that needed nothing" "and found the tree wrong"
fi

case "$DRIVE" in
	skip)
		t_skip "python3-nonesuch is not installed"
		;;
	builder)
		t_builder_file "${BRENN_REPO_ROOT}/rpi-image-gen/absent" \
			"the builder file is where it is expected" \
			"a bump moved it"
		;;
	eq)
		t_eq "a device reading" "179:5  " "179:5"
		;;
esac
t_done
DRIVER

drive() {
	env BRENN_TESTS_LIB="$BRENN_TESTS_LIB" BRENN_REPO_ROOT="$fake_root" \
		"$@" bash "$driver" 2>&1
}

out=$(drive DRIVE=skip)
t_eq "a missing precondition alone skips" "$?" 77
case "$out" in
	*"SKIP  python3-nonesuch"*) t_pass "and the skip names what is missing" ;;
	*) t_fail "and the skip names what is missing" "output: ${out}" ;;
esac

out=$(drive DRIVE=skip FAIL_FIRST=1)
t_eq "a missing precondition below a failure fails" "$?" 1
case "$out" in
	*"FAIL  an assertion that needed nothing"*"NOSKIP"*)
		t_pass "and the failure is still on screen, above the refusal to skip" ;;
	*) t_fail "and the failure is still on screen, above the refusal to skip" "output: ${out}" ;;
esac

# The same rule through the submodule helper, which is the shape the suite meets
# it in: a fresh clone with an empty checkout, below assertions that read only
# the tree.
out=$(drive DRIVE=builder)
t_eq "an unchecked-out builder alone skips" "$?" 77
case "$out" in
	*"git submodule update --init"*) t_pass "and the skip says how to check it out" ;;
	*) t_fail "and the skip says how to check it out" "output: ${out}" ;;
esac

out=$(drive DRIVE=builder FAIL_FIRST=1)
t_eq "an unchecked-out builder below a failure fails" "$?" 1

# A difference that is invisible in the values has to be visible in the report.
# The device lane compares readings from tools that pad their columns, and an
# undelimited report prints the expectation and the reading as two identical
# lines when they differ by two trailing spaces — which sends the reader after
# any cause but the one in front of them.
out=$(drive DRIVE=eq)
t_eq "values differing only in whitespace do not match" "$?" 1
case "$out" in
	*"expected: '179:5'"*"actual:   '179:5  '"*)
		t_pass "and both are delimited, so the difference is on screen" ;;
	*) t_fail "and both are delimited, so the difference is on screen" "output: ${out}" ;;
esac

# --- the environment a subject runs in -------------------------------------

# The third helper that decides rather than reports: it settles what a tool
# under assertion can read out of the environment. Its failure mode is silent
# and one-sided — a mistyped prefix leaves the knobs in place, and only on a
# host that has them set, which is the configured build host this exists to
# protect. A bare runner would stay green either way, so the case is made here
# by setting them.
export BRENN_TEST_SCRUB_ONE=from-the-host
export BRENN_TEST_SCRUB_TWO=also-from-the-host
export BRENN_TEST_KEEP=not-this-one

t_eq "every variable under the prefix is taken out of the subject's environment" \
	"$(t_env_scrubbed BRENN_TEST_SCRUB_ env | grep -c '^BRENN_TEST_SCRUB_')" 0
# The subject reads its own environment, so the expansions below belong to the
# shell being run and not to this one.
# shellcheck disable=SC2016
t_eq "and one outside it is left alone" \
	"$(t_env_scrubbed BRENN_TEST_SCRUB_ sh -c 'echo "${BRENN_TEST_KEEP:-}"')" not-this-one

# The removals are applied before the assignments, which is what lets a caller
# scrub a whole prefix and then set one member of it deliberately — the shape
# every bundle case uses to point the tool at a conf file of its own.
# shellcheck disable=SC2016
t_eq "a value the caller passes after the prefix still arrives" \
	"$(t_env_scrubbed BRENN_TEST_SCRUB_ BRENN_TEST_SCRUB_ONE=deliberate \
		sh -c 'echo "${BRENN_TEST_SCRUB_ONE:-}"')" deliberate

unset BRENN_TEST_SCRUB_ONE BRENN_TEST_SCRUB_TWO BRENN_TEST_KEEP

t_done
