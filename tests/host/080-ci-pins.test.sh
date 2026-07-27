#!/usr/bin/env bash
#
# The tool versions the image lane pins, against what the builder expects.
#
# The build has one input it fetches from the network without a hash: the SBOM
# scanner, which the builder downloads at build time if the host has none. The
# image lane closes that by putting a hash-pinned scanner on PATH first, at the
# version the builder would otherwise have fetched. That equality is the whole
# mitigation, and it is exactly the kind of thing a submodule bump moves
# quietly, so it is asserted here rather than discovered in a diff of two
# SBOMs.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

workflow="${BRENN_REPO_ROOT}/.github/workflows/ci.yml"
[ -f "$workflow" ] || {
	t_fail "the workflow is present" "not at ${workflow}"
	t_done
}

ci_version=$(sed -n 's/^[[:space:]]*SYFT_VERSION:[[:space:]]*//p' "$workflow" | head -n1)
ci_digest=$(sed -n 's/^[[:space:]]*SYFT_SHA256:[[:space:]]*//p' "$workflow" | head -n1)

t_eq "the lane pins a scanner version" \
	"$([ -n "$ci_version" ] && echo yes)" yes
t_eq "and pins the download by digest, since a release asset can be replaced" \
	"$(printf '%s' "$ci_digest" | grep -c '^[0-9a-f]\{64\}$')" 1

# A checkout without the submodule cannot answer the question and says so. A
# checkout *with* the submodule and no hook where the hook belongs is the case
# this test exists for — a bump that moved it — so it fails rather than skips:
# skipping there would quietly restore the unpinned download this pin removes.
hook="${BRENN_REPO_ROOT}/rpi-image-gen/layer/sbom/gen.sh"
if [ ! -f "$hook" ]; then
	if [ -z "$(ls -A "${BRENN_REPO_ROOT}/rpi-image-gen" 2>/dev/null)" ]; then
		t_skip "the builder is not checked out — run: git submodule update --init"
	fi
	t_fail "the builder's scanner hook is where the pin expects it" \
		"nothing at ${hook} — if the bump moved it, the lane's pin has to follow"
	t_done
fi

# The builder writes it as a tag; the lane writes it as a version. Compared as
# versions so the two spellings of the same pin do not read as a mismatch.
builder_version=$(sed -n 's/^SYFT_VER=v\{0,1\}//p' "$hook" | sed 's/[[:space:]].*//' | head -n1)
t_eq "the builder pins a scanner version too" \
	"$([ -n "$builder_version" ] && echo yes)" yes
t_eq "the lane pins the version the builder would have fetched" \
	"$ci_version" "$builder_version"

t_done
