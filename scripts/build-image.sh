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
# Output lands under work/, which is build output and is not tracked.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder="${repo_root}/rpi-image-gen/rpi-image-gen"
srcdir="${repo_root}/image"
workdir="${repo_root}/work"

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

	Its own host dependencies are installed by rpi-image-gen/install_deps.sh.
	EOF
	exit 1
fi

# The build's one unpinned input. Its SBOM step uses a scanner from the host if
# there is one and downloads whatever its installer serves if there is not, so a
# scanner on PATH is what keeps the build's inputs pinned. CI installs one at a
# version and digest it pins; locally this is a notice rather than a refusal,
# because the scanner describes the build rather than shaping it.
if ! command -v syft >/dev/null 2>&1; then
	echo "build-image: syft is not installed — the build will download one over the network." >&2
	echo "build-image: install the version .github/workflows/ci.yml pins to keep the build's inputs pinned." >&2
fi

mkdir -p "$workdir"

# The builder resolves layers, configs and hooks relative to -S, so every
# brenn-os-specific input reaches it through that one directory.
exec "$builder" build \
	-S "$srcdir" \
	-c "$config" \
	-B "$workdir" \
	"$@"
