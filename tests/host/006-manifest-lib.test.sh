#!/usr/bin/env bash
#
# Reading a package manifest, at the point where two lanes have to agree.
#
# The host lane holds the tracked manifests to the kernel pin and the image lane
# compares them against what a built image installs, both through
# manifest_entries. What that function keeps and what it strips therefore
# decides what each lane checks — a rule quietly widened here reaches the image
# lane's comparison, where a diff costs a gigabyte-scale build to see. So the
# rule is asserted against a manifest written to exercise it, rather than
# inferred from manifests that happen to be well-formed.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/manifest.sh
. "${BRENN_TESTS_LIB}/manifest.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

manifest="${work}/expected-fixture.packages"
cat >"$manifest" <<'MANIFEST'
# A whole-line comment, and the blank line under it.

rauc
curl   # the group this one belongs to
	iproute2
curl
MANIFEST

t_eq_text "comments, blanks and surrounding whitespace are stripped, the rest sorted and deduplicated" \
	"$(manifest_entries "$manifest")" \
	"$(printf '%s\n' curl iproute2 rauc)"

# A space inside a line is a typo, and the two names either side of it are both
# plausible packages. Closing the gap would emit a third name that is neither,
# and every reader downstream would go looking for it in an image.
printf 'linux-image rpi-v8\n' >"${work}/typo.packages"
t_eq "a space inside an entry is left where it is, not closed up" \
	"$(manifest_entries "${work}/typo.packages")" "linux-image rpi-v8"

# A manifest of nothing but commentary describes an image that installs
# nothing. Reported as empty rather than as a blank entry, which would compare
# equal to a package name of no characters.
: >"${work}/empty.packages"
t_eq "a manifest with no entries reads as none" \
	"$(manifest_entries "${work}/empty.packages" | wc -l)" 0

printf '# only a comment\n\n' >"${work}/comments.packages"
t_eq "a manifest of comments and blanks reads as none" \
	"$(manifest_entries "${work}/comments.packages" | wc -l)" 0

t_done
