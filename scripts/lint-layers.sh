#!/usr/bin/env bash
#
# Lint the layer metadata blocks under image/.
#
# A layer's metadata block is a schema the builder parses; a typo in it fails
# late, in the middle of a half-hour build, or silently drops a variable. The
# linter is the builder's own, so this is worth exactly as much as the pinned
# submodule is — and, like the build, it runs in the pinned container on a host
# the builder does not support, so this check is not degraded on the machine the
# developer actually works on (scripts/lib/build-lane.sh).
#
# Two things still make it skip loudly rather than block a commit: an unfetched
# submodule, which leaves nothing to lint in either lane, and a host that has
# neither a builder it can run nor the container lane's prerequisites. CI has
# both, so the skip is never CI's path.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder="${repo_root}/rpi-image-gen/rpi-image-gen"

# shellcheck source=scripts/lib/build-lane.sh
. "${repo_root}/scripts/lib/build-lane.sh"

if [ ! -x "$builder" ]; then
	echo "lint-layers: builder submodule not checked out — LAYER LINT SKIPPED (fetched and enforced in CI)"
	exit 0
fi

lane_load_conf
lane_scratch_setup
lane=$(lane_select)

# The linter parses deb822; without it every invocation dies the same way and
# the failure says nothing about the tree. It is a dependency of the lane that
# runs the builder directly — the container's package set carries it — so it is
# probed after the lane is known and not before, or a host whose lane supplies
# it would skip on a dependency it never needed.
if [ "$lane" = native ]; then
	if ! python3 -c 'import debian.deb822' >/dev/null 2>&1; then
		echo "lint-layers: python3-debian not installed — LAYER LINT SKIPPED (installed and enforced in CI)"
		exit 0
	fi
elif ! lane_container_check; then
	echo "lint-layers: LAYER LINT SKIPPED — ${lane_unmet}"
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

# One invocation per layer, and in the container lane one container for all of
# them: the enumeration is a repo fact, read here, and the paths it produces are
# repo-relative, so they name the same files on either side of the mount.
#
# Both lanes run this one command, from the top of the repo — which is the
# working directory the container is given, and the one set below for the native
# lane. The loop is written on one line so that a dry run reports it as one line,
# and it is the same argv that runs, so what the report says is what happens.
#
# shellcheck disable=SC2016  # the loop body is expanded by the shell inside
lint_argv=(bash -c \
	'status=0; for f in "$@"; do rpi-image-gen/rpi-image-gen metadata --lint "$f" || { echo "lint-layers: FAILED ${f}" >&2; status=1; }; done; exit "$status"' \
	lint-layers "${layers[@]}")

if [ "$lane" = container ]; then
	tag=$(lane_image_tag)
	lane_container_argv "$tag" "${lint_argv[@]}"

	if lane_dry_run; then
		lane_report container "${lane_argv[@]}"
		exit 0
	fi

	lane_ensure_image "$tag"
	exec "${lane_argv[@]}"
fi

if lane_dry_run; then
	lane_report native "${lint_argv[@]}"
	exit 0
fi

cd "$repo_root"
exec "${lint_argv[@]}"
