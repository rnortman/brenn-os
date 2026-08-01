#!/usr/bin/env bash
#
# The kernel and boot firmware that got installed are the ones that were
# pinned.
#
# The Raspberry Pi archive publishes no snapshot service, so an apt preferences
# file is what makes two builds of one commit resolve the same kernel against
# the archive as it stands today: resolution is deterministic and drift is
# detectable here, not impossible. A pin that fails to apply — a renamed
# package, a version the archive stopped publishing, a priority that lost a tie
# — produces a working image built from something nobody chose, and nothing in
# the build says so. This is where the difference becomes visible, rather than
# on hardware behaving differently.
#
# The pin file is the source of the expectation on purpose: there is one place
# to bump a version, and this asserts the image agrees with it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"
# shellcheck source=tests/lib/pin.sh
. "${BRENN_TESTS_LIB}/pin.sh"

img_open_system_root

pinfile="${BRENN_REPO_ROOT}/image/layer/brenn/apt/preferences.rpi-pin"
[ -f "$pinfile" ] || t_skip "no pin file at ${pinfile}"

if ! installed=$(img_installed_packages "$IMG_SPEC"); then
	t_fail "read the package database" "nothing at ${EXPECT_VAR_LOWERDIR}/lib/dpkg/status"
	t_done
fi

# Pin stanzas: a Package: line of shell-glob patterns followed by a version.
patterns=()
versions=()
while IFS=$'\t' read -r pattern_set version; do
	patterns+=("$pattern_set")
	versions+=("$version")
done < <(pin_stanzas "$pinfile")

if [ ${#patterns[@]} -eq 0 ]; then
	t_fail "the pin file declares version pins" "no 'Pin: version' stanza in ${pinfile}"
	t_done
fi

# Pathname expansion off for the split below. A `Package:` line holds globs, and
# an unquoted expansion is matched against the working directory before the loop
# body ever sees it: one stray file named like a kernel package in whatever
# directory the lane was started from, and the most important pin here silently
# checks nothing. Pattern matching in `case` is unaffected, which is where the
# globs are wanted.
matched=0
set -f
for i in "${!patterns[@]}"; do
	want=${versions[$i]}
	for pattern in ${patterns[$i]}; do
		while read -r pkg ver; do
			# shellcheck disable=SC2254  # the pin file's patterns are globs by design
			case "$pkg" in
				$pattern) ;;
				*) continue ;;
			esac
			matched=$((matched + 1))
			t_eq "${pkg} is the pinned version" "$ver" "$want"
		done <<<"$installed"
	done
done
set +f

# A pin that matches nothing installed passes every assertion above while
# guaranteeing nothing at all.
if [ "$matched" -gt 0 ]; then
	t_pass "the pins cover ${matched} installed package(s)"
else
	t_fail "the pins cover something that is installed" \
		"no installed package matches any pattern in ${pinfile}"
fi

t_done
