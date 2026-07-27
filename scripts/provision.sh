#!/usr/bin/env bash
#
# Install a device's first provisioning generation.
#
#   scripts/provision.sh [-n] <persistent-partition-or-mount> <generation-dir>
#
# A freshly flashed device has a generic image and no identity: no host name, no
# machine id, no wireless credentials, no host key, no trust anchor, no
# collector. All of that is one directory — a generation — and this puts the
# first one in place, on the writable partition, while the device is still on
# the bench. Every generation after it is shipped over the network and trialled;
# this one cannot be, because there is no boot to trial it against and nothing
# to fall back to, which is why it is installed committed.
#
# The generation itself is assembled outside this repository, from wherever the
# operator keeps secrets. Nothing site-specific is in this script, and running
# it leaves nothing site-specific behind in the tree.
#
# -n validates the generation and stops, writing nothing. Worth doing before
# taking a device apart.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# One implementation of the rules and one of the write, shared with the device:
# both programs are installed in the image, where the on-device apply path uses
# them. Preferring the in-tree copies means a change to the contract is
# exercised by this tool before it ever reaches hardware, and that a generation
# installed on the bench is the same thing as one installed over the network.
overlay="${repo_root}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn"
validate="${overlay}/brenn-config-validate"
[ -x "$validate" ] || validate=/usr/lib/brenn/brenn-config-validate
installer="${overlay}/brenn-config-install"
[ -x "$installer" ] || installer=/usr/lib/brenn/brenn-config-install
lib="${overlay}/brenn-config-lib.sh"
[ -r "$lib" ] || lib=/usr/lib/brenn/brenn-config-lib.sh
# shellcheck source=../image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-lib.sh
. "$lib"

# Where a generation lives on the partition, and the name the first one takes.
store=provisioning
first="gen-1"

# The partition this may be written to. Writing site configuration into a system
# slot would break the bit-identical-slots invariant and be overwritten by the
# next update; writing it into a boot partition would drop the permissions the
# host key depends on. Both are easy to do with one wrong letter in a device
# name, so the label is checked rather than trusted.
expect_label=persistent

check_only=0

usage() {
	echo "usage: $(basename "$0") [-n] <persistent-partition-or-mount> <generation-dir>" >&2
	echo "  -n   validate the generation and stop; write nothing" >&2
}

die() {
	echo "provision: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
		-n)
			check_only=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			exit 2
			;;
		*) break ;;
	esac
done

if [ $# -ne 2 ]; then
	usage
	exit 2
fi

target=$1
gen=$2

[ -d "$gen" ] || die "no such generation directory: ${gen}"
[ -x "$validate" ] || die "the contract checker is missing: ${validate}"
[ -x "$installer" ] || die "the generation installer is missing: ${installer}"

# Validate before anything is touched — including before a partition is
# mounted, so that a rejected generation costs nothing.
"$validate" "$gen" || die "the generation does not satisfy the contract; nothing was written"
echo "provision: ${gen} satisfies the contract"

if [ "$check_only" -eq 1 ]; then
	exit 0
fi

# Everything below writes. The files belong to root and the two secrets are
# readable by nobody else, which cannot be arranged by a user who is not root —
# and mounting the partition needs root anyway.
[ "$(id -u)" -eq 0 ] || die "installing a generation needs root (the files belong to root)"

mountpoint=""
mounted=""

cleanup() {
	if [ -n "$mounted" ]; then
		umount "$mounted" || echo "provision: ${mounted} is still mounted" >&2
		rmdir "$mounted" 2>/dev/null || true
	fi
}
trap cleanup EXIT

if [ -b "$target" ]; then
	# No fallback if the tool that reads the label is absent: the refusal below
	# is this program's safety contract, and a run that skipped it with a
	# warning would be a run that wrote a raw block device on the strength of a
	# line the operator scrolled past.
	command -v lsblk >/dev/null 2>&1 ||
		die "lsblk is not installed: refusing to write to a partition whose label cannot be read"
	label=$(lsblk -no PARTLABEL "$target" 2>/dev/null | head -n1 | tr -d '[:space:]')
	[ "$label" = "$expect_label" ] ||
		die "${target} is labelled '${label}', not '${expect_label}': refusing to write to it"
	mountpoint=$(mktemp -d)
	mount "$target" "$mountpoint" || die "could not mount ${target}"
	mounted=$mountpoint
	echo "provision: mounted ${target} (${expect_label}) at ${mountpoint}"
elif [ -d "$target" ]; then
	mountpoint=$target
else
	die "${target} is neither a block device nor a mounted directory"
fi

dest="${mountpoint}/${store}"

# First provisioning only. A device that already has a committed generation gets
# its configuration changed the way every change after the first is made: as a
# transaction on the running device, which trials the candidate and reverts it
# if the device does not come back.
if [ -e "${dest}/active" ] || [ -e "${dest}/trial" ]; then
	die "${dest} already holds a generation; change it on the device with brenn-config-apply"
fi

# A generation with no link to it is what an interrupted run leaves. Removing it
# silently would be indistinguishable from overwriting configuration somebody
# wanted, so it is the operator's to look at.
if [ -e "${dest}/${first}" ]; then
	die "${dest}/${first} exists but nothing selects it; inspect and remove it"
fi

mkdir -p "$dest"

# The write itself, by the same program the on-device tool uses, so that the
# generation a device is born with is indistinguishable from the ones it is
# given later.
BRENN_CONFIG_VALIDATE="$validate" "$installer" "$gen" "${dest}/${first}" ||
	die "the generation was not installed"

# The link is what selects, so it goes last and atomically: an interrupted run
# leaves a device with no generation, which boots to the console, rather than
# one with half a generation, which boots believing it is configured.
ln -s "$first" "${dest}/active.new"
mv -T "${dest}/active.new" "${dest}/active"

chown 0:0 "$dest"
chmod 0755 "$dest"

brenn_flush "$dest"

echo "provision: installed ${gen} as ${store}/${first}, committed"
