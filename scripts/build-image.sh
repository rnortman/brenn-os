#!/usr/bin/env bash
#
# Build an image for one profile.
#
#   scripts/build-image.sh <profile> [-- key=value ...]
#
# Everything the build reads is in-tree and pinned: the builder is a submodule
# at a fixed commit, the Debian base is a fixed snapshot, and the Raspberry Pi
# kernel and firmware are pinned by an apt preferences file. Overrides after
# `--` are passed through to the builder, which is how a local overlay changes
# a knob without editing the tree.
#
# The builder itself needs a Debian host, so on a host that is not one it runs
# in the pinned container this repo builds. Which lane is taken, where the
# build's scratch space goes, and how to override either: scripts/lib/build-lane.sh.
#
# Output lands under work/, which is build output and is not tracked.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder="${repo_root}/rpi-image-gen/rpi-image-gen"
srcdir="${repo_root}/image"
workdir="${repo_root}/work"

# shellcheck source=scripts/lib/build-lane.sh
. "${repo_root}/scripts/lib/build-lane.sh"

list_profiles() {
	local f name
	for f in "${srcdir}"/config/*.yaml; do
		[ -e "$f" ] || continue
		name=$(basename "$f" .yaml)
		# Shared fragments are included by profiles, not built directly.
		case "$name" in
			brenn-*) continue ;;
		esac
		echo "  $name"
	done
}

usage() {
	echo "usage: $(basename "$0") <profile> [-- key=value ...]" >&2
	echo "profiles:" >&2
	list_profiles >&2
}

profile=${1:-}
case "$profile" in
	"")
		usage
		exit 1
		;;
	-h | --help)
		usage
		exit 0
		;;
esac
shift

config="${srcdir}/config/${profile}.yaml"
if [ ! -f "$config" ]; then
	echo "build-image: no such profile: ${profile}" >&2
	usage
	exit 1
fi

if [ ! -x "$builder" ]; then
	cat >&2 <<-EOF
	build-image: the image builder is not checked out.

	It is a submodule pinned to an exact commit. Fetch it with:
	    git submodule update --init --recursive
	EOF
	exit 1
fi

mkdir -p "$workdir"

lane_load_conf
lane_scratch_setup
lane=$(lane_select)

# The builder resolves layers, configs and hooks relative to -S, so every
# brenn-os-specific input reaches it through that one directory.
#
# TODO(local-image-lane): the container lane is the half of this that makes a
# build possible on a host the builder does not support; what remains is
# showing that what it produces is what CI's native lane produces.
if [ "$lane" = container ]; then
	lane_container_check || lane_die "$lane_unmet"
	tag=$(lane_image_tag)

	# Inside the container this takes the native lane, which can now pass
	# the dependency gate. The scratch and apt-cache knobs arrive as
	# container paths, so the one resolution above governs both lanes.
	lane_container_argv "$tag" \
		"${lane_container_repo}/scripts/build-image.sh" "$profile" "$@"

	if lane_dry_run; then
		lane_report container "${lane_argv[@]}"
		exit 0
	fi

	lane_ensure_image "$tag"
	exec "${lane_argv[@]}"
fi

# The build's one unpinned input on this lane. A scanner on PATH keeps the
# build's SBOM input pinned; without one the build fetches whatever version the
# network serves. CI and the container carry pinned versions; locally this is a
# notice rather than a refusal, because the scanner describes the build rather
# than shaping it.
if ! command -v syft >/dev/null 2>&1; then
	echo "build-image: syft is not installed — the build will download one over the network." >&2
	echo "build-image: install the version .github/workflows/ci.yml pins to keep the build's inputs pinned." >&2
fi

# The builder takes overrides as key=value after `--`, last one winning, so
# anything the caller passes outranks what is set here.
overrides=()
if [ -n "$BRENN_APT_CACHEDIR" ]; then
	overrides+=("IGconf_sys_apt_cachedir=${BRENN_APT_CACHEDIR}")
fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then
	shift
fi
overrides+=("$@")

argv=("$builder" build -S "$srcdir" -c "$config" -B "$workdir")
if [ ${#overrides[@]} -gt 0 ]; then
	argv+=(-- "${overrides[@]}")
fi

if lane_dry_run; then
	lane_report native "${argv[@]}"
	exit 0
fi

exec "${argv[@]}"
