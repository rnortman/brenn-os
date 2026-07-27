#!/usr/bin/env bash
#
# Lint the layer metadata blocks under image/.
#
# A layer's metadata block is a schema the builder parses; a typo in it fails
# late, in the middle of a half-hour build, or silently drops a variable. The
# linter is the builder's own, so this is worth exactly as much as the pinned
# submodule is.
#
# Like the shell lint, this skips loudly rather than blocking a commit on a
# machine that has not fetched the submodule or the linter's dependency. CI has
# both, so the skip is never CI's path.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder="${repo_root}/rpi-image-gen/rpi-image-gen"

if [ ! -x "$builder" ]; then
	echo "lint-layers: builder submodule not checked out — LAYER LINT SKIPPED (fetched and enforced in CI)"
	exit 0
fi

# The linter parses deb822; without it every invocation dies the same way and
# the failure says nothing about the tree.
if ! python3 -c 'import debian.deb822' >/dev/null 2>&1; then
	echo "lint-layers: python3-debian not installed — LAYER LINT SKIPPED (installed and enforced in CI)"
	exit 0
fi

# Enumerated from the index, so a new layer cannot join the tree unlinted.
# Config files carry no metadata block and are not layers.
mapfile -t candidates < <(git -C "$repo_root" ls-files -- 'image/*.yaml')

layers=()
for f in "${candidates[@]}"; do
	if grep -q '^# METABEGIN' "${repo_root}/${f}"; then
		layers+=("$f")
	fi
done

if [ ${#layers[@]} -eq 0 ]; then
	echo "lint-layers: no layers found under image/ — nothing to lint"
	exit 0
fi

echo "lint-layers: ${#layers[@]} layer(s)"

status=0
for f in "${layers[@]}"; do
	if ! "$builder" metadata --lint "${repo_root}/${f}"; then
		echo "lint-layers: FAILED ${f}" >&2
		status=1
	fi
done

exit "$status"
