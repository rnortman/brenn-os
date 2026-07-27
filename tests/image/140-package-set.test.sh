#!/usr/bin/env bash
#
# Everything that is installed, and nothing else.
#
# The package set is exhaustive by intent: each one was chosen, and the ones
# that are absent are absent on purpose. Asserting only that the packages we
# name are present says nothing about what arrived alongside them, and what
# arrives alongside them is a second listener, a daemon writing to a /var that
# is RAM, or growth against a fixed slot size — none of which announce
# themselves. A tracked manifest turns "a bump added something" into a failure
# here instead of a discovery on a device.
#
# The manifest is written from a real build, once, and reviewed before it is
# baked: an unexpected package is a finding, not a line to add.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

manifest="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.packages"

if ! installed=$(img_installed_packages "$IMG_SPEC"); then
	t_fail "read the package database" "nothing at ${EXPECT_VAR_LOWERDIR}/lib/dpkg/status"
	t_done
fi

installed=$(printf '%s\n' "$installed" | cut -d' ' -f1 | sort -u)

if [ ! -f "$manifest" ]; then
	t_fail "the installed package set is written down" \
		"no manifest at ${manifest}" \
		"this image installs $(printf '%s\n' "$installed" | wc -l) packages; the list" \
		"follows. Review it — every line is a package that ships to a device —" \
		"and then record it as the manifest."
	printf '%s\n' "$installed" | sed 's/^/        /'
	t_done
fi

expected=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$manifest" | grep -v '^$' | sort -u)

t_eq_text "the installed package set is exactly the tracked manifest" \
	"$installed" "$expected"

t_done
