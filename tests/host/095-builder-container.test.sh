#!/usr/bin/env bash
#
# The pinned host environment the builder runs in.
#
# The builder needs a Debian host, so on any other host it runs in the container
# containers/builder/Containerfile defines. That makes the container definition
# part of the build's input surface, and it is pinned the way every other input
# is: base by digest, packages by snapshot timestamp, scanner by version and
# digest. A tag instead of a digest, or a suite instead of a timestamp, would
# make the lane's toolchain whatever the day happened to serve.
#
# The package set is the other half. It is the builder's own dependency manifest
# transcribed, and a submodule bump that adds a dependency has to land here too —
# otherwise the first sign of the drift is a dependency check failing inside a
# container, on a machine that cannot install anything to fix it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

containerfile="${BRENN_REPO_ROOT}/containers/builder/Containerfile"
depends="${BRENN_REPO_ROOT}/rpi-image-gen/depends"
workflow="${BRENN_REPO_ROOT}/.github/workflows/ci.yml"
common="${BRENN_REPO_ROOT}/image/config/brenn-common.yaml"

if [ ! -f "$containerfile" ]; then
	t_fail "the builder container is defined" "nothing at ${containerfile}"
	t_done
fi

# The base, by digest. A tag is a moving reference to a rebuilt image.
from=$(sed -n 's/^FROM[[:space:]]*//p' "$containerfile" | head -n1)
t_eq "the base image is pinned by digest" \
	"$(printf '%s' "$from" | grep -c '@sha256:[0-9a-f]\{64\}$')" 1

# The archive, at a timestamp, and at the same timestamp the image's own base is
# bootstrapped from: the tools and the thing they build then come from one dated
# view of Debian, and bumping the image's pin cannot silently leave the
# toolchain behind.
epoch=$(sed -n 's/^[[:space:]]*SOURCE_DATE_EPOCH:[[:space:]]*//p' "$common" | head -n1)
t_eq "the image pins a source date" \
	"$(printf '%s' "$epoch" | grep -c '^[0-9]\{1,\}$')" 1
expected_snapshot=$(date -u -d "@${epoch}" +%Y%m%dT%H%M%SZ)

mapfile -t snapshots < <(
	grep -o 'snapshot\.debian\.org/archive/[a-z-]*/[0-9]\{8\}T[0-9]\{6\}Z' "$containerfile" |
		sed 's|.*/||' | sort -u
)
t_eq "the container's packages come from one snapshot timestamp" \
	"${#snapshots[@]}" 1
t_eq "and it is the timestamp the image's own base is pinned to" \
	"${snapshots[0]:-none}" "$expected_snapshot"

# A snapshot Release file expires about a week after it is made. apt spells the
# waiver `Check-Valid-Until: no` in a deb822 file and silently ignores the
# one-line format's `Options: check-valid-until=no`, so the wrong spelling reads
# as correct and stops this image building a week after the pin is set.
t_eq "both snapshot stanzas waive the Release freshness check" \
	"$(grep -c "'Check-Valid-Until: no'" "$containerfile")" 2
t_eq "and never as an Options field, which deb822 ignores in silence" \
	"$(grep -ci 'check-valid-until=' "$containerfile")" 0

# The scanner, at the version CI pins. Both lanes then describe a build with
# the same tool, and the local lane stops needing a scanner on the host at all.
ci_version=$(sed -n 's/^[[:space:]]*SYFT_VERSION:[[:space:]]*//p' "$workflow" | head -n1)
ci_digest=$(sed -n 's/^[[:space:]]*SYFT_SHA256:[[:space:]]*//p' "$workflow" | head -n1)
image_version=$(sed -n 's/^[[:space:]]*SYFT_VERSION=\([^;]*\);.*/\1/p' "$containerfile" | head -n1)
t_eq "the container pins the scanner version the workflow pins" \
	"$image_version" "$ci_version"

# One digest per architecture the container can be built for, because a release
# asset can be replaced under an unchanged version.
for arch in amd64 arm64; do
	digest=$(sed -n "s/^[[:space:]]*SYFT_SHA256_${arch}=\([^;]*\);.*/\1/p" "$containerfile" | head -n1)
	t_eq "the ${arch} scanner download is pinned by digest" \
		"$(printf '%s' "$digest" | grep -c '^[0-9a-f]\{64\}$')" 1
	if [ "$arch" = arm64 ]; then
		t_eq "and the arm64 digest is the one the workflow verifies" \
			"$digest" "$ci_digest"
	fi
done

t_builder_file "$depends" \
	"the builder's dependency manifest is where the package set is copied from" \
	"if the bump moved it, this assertion is looking at nothing"

# The install list, as the package names apt is given. Anything else in the
# Containerfile is a command or a continuation and carries a space or a
# semicolon; a package sits alone on its line.
mapfile -t installed < <(
	sed -n 's/^[[:space:]]*\([a-z0-9][a-z0-9.+-]*\);\{0,1\}[[:space:]]*\\$/\1/p' "$containerfile" | sort -u
)
t_ge "the Containerfile installs a package set" "${#installed[@]}" 20

# A manifest entry is category:program:package, the package field optional and
# used when the package is not named for the program it provides.
mapfile -t required < <(
	sed 's/#.*//' "$depends" |
		awk -F: 'NF >= 2 { pkg = ($3 != "") ? $3 : $2; if (pkg != "") print pkg }' |
		sort -u
)
t_ge "the manifest names dependencies" "${#required[@]}" 20

missing=""
for pkg in "${required[@]}"; do
	printf '%s\n' "${installed[@]}" | grep -qxF "$pkg" || missing+="${pkg}"$'\n'
done
t_eq_text "every dependency the builder declares is installed in the container" \
	"${missing%$'\n'}" ""

t_done
