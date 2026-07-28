#!/usr/bin/env bash
#
# The gate does not call the script that empties the build area.
#
# `make clean` removes work/, and `make test-clean` asserts what it would do by
# running it in dry-run mode. Both are deliberately outside `make check`: the gate
# runs on every commit, out of a pre-commit hook, and a gate that invokes the
# build-area remover — even to ask what it would do — is one bad edit away from
# a gate that removes it.
#
# That rule is otherwise carried by prose in three places, and it is under named
# pressure: TODO(clean-lane-ci)'s done-when is that some automated runner runs
# `make test-clean`, so the next person in this area is invited to wire the lane
# into something. Wiring it into a CI job is what that entry asks for; wiring it
# into `check` is the one arrangement that must not happen, and a comment is a
# poor place to keep that distinction. Hence this file, in the gate itself.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

makefile="${BRENN_REPO_ROOT}/Makefile"
[ -f "$makefile" ] || {
	t_fail "the Makefile is present" "not at ${makefile}"
	t_done
}

# The check target as written: its own line, so a prerequisite counts too,
# through to the next line that is neither a recipe line nor blank.
check_block=$(awk '
	/^check:/ { inblock = 1; print; next }
	inblock && (/^\t/ || /^$/) { print; next }
	inblock { exit }
' "$makefile")

t_eq "the gate has a target to assert against at all" \
	"$(printf '%s\n' "$check_block" | grep -c '^check:')" 1
t_eq "which neither depends on nor runs anything that cleans the build area" \
	"$(printf '%s\n' "$check_block" | grep -ci clean)" 0

# The lane that does assert the cleaner is still a target, and still a separate
# one — the rule is that the gate does not call it, not that nothing does.
t_eq "the cleaner's own lane is a target of its own" \
	"$(grep -c '^test-clean:' "$makefile")" 1

# The other direction, which a Makefile assertion alone would miss: tests/host is
# what `make check` runs, so a case added there could reach the script without
# the gate's recipe changing a character. tests/clean is the suite that owns it.
mapfile -t reaching < <(grep -rlF -- 'clean-work' "${BRENN_REPO_ROOT}/tests/host" |
	grep -vF -- "$(basename -- "${BASH_SOURCE[0]}")" || true)
t_eq "and no test in the gate's own suite reaches the build-area remover either" \
	"${reaching[*]-}" ""

t_done
