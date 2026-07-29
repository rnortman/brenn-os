#!/usr/bin/env bash
#
# Put an image on a device, and take a copy of what was there first.
#
#   scripts/flash.sh backup <device> <output-dir>
#   scripts/flash.sh write  <device> <image.img>
#
# This is the one command in the whole device lifecycle that destroys something
# irreplaceable: a whole-device write over the medium a robot shipped with, run
# from a workstation whose own disk is one letter away in the device name. It
# happens a handful of times in a product's life and never routinely — every
# subsequent OS change ships as an update bundle to the running device.
#
# So the tool is built the way the rest of this tree treats devices: it refuses
# by default and identifies before it touches. The target must be a whole disk,
# on USB, reporting the mass-storage gadget's model, with nothing mounted off
# it. A workstation's own disk fails at least two of those. Every check is a
# refusal, never a warning, and the tool declines to run at all rather than
# guess when the thing that answers those questions is missing.
#
# Both modes verify what they did by reading it back, because a USB link that
# drops bytes is the failure this procedure actually has, and a backup that
# cannot be trusted must not look like one.
#
# Nothing here is unit-specific and nothing it writes belongs in a repository:
# a dump of a device is that device's data and lives in the operator's own
# storage.

set -euo pipefail

prog=${0##*/}

# The mass-storage gadget the CM4's boot ROM runs once rpiboot has uploaded it,
# as Linux reports it in lsblk's MODEL column. The `RPi-MSD- 0001` name that
# appears in vendor documentation is what Raspberry Pi Imager displays on
# Windows; it matches nothing here and a guard holding out for it would refuse
# every real session.
#
# Overridable, because gadget or firmware changes rename such strings and a
# guard with no way past it is a tool that stops working on the day it is
# needed. Using the override is a deliberate act, and the value it reveals
# belongs back in this line.
expect_model=${BRENN_FLASH_EXPECT_MODEL:-Raspberry Pi multi-function USB device}

# Bulk transfer block size, and the sector granularity the tail of a transfer
# falls back to. Direct I/O demands both offset and length be sector multiples,
# so a byte-exact read is composed from three aligned pieces rather than one
# ragged one.
big=4194304
small=512

usage() {
	echo "usage: ${prog} backup <device> <output-dir>" >&2
	echo "       ${prog} write  <device> <image.img>" >&2
	echo "  backup  full compressed dump of <device>, verified against a second read" >&2
	echo "  write   write a raw image to <device>, verified by reading it back" >&2
}

die() {
	echo "flash: $*" >&2
	exit 1
}

# One lsblk field for one device, whitespace-trimmed at both ends. Interior
# spaces are part of the value — the gadget's model has three of them.
lsblk_one() {
	local field=$1 dev=$2 out
	out=$(lsblk -d -n -o "$field" -- "$dev" 2>/dev/null | head -n1) || return 1
	out=${out#"${out%%[![:space:]]*}"}
	out=${out%"${out##*[![:space:]]}"}
	printf '%s' "$out"
}

# Everything that has to be true of a target before either mode touches it.
# Each is a hard refusal naming what it saw, because the operator reading the
# message is mid-teardown with the robot open and needs to know which of the
# four assumptions broke.
identify() {
	local dev=$1 type tran model mounts

	[ -e "$dev" ] || die "no such device: ${dev}"

	type=$(lsblk_one TYPE "$dev") ||
		die "${dev}: lsblk could not read it; refusing to write to a device it cannot identify"
	[ -n "$type" ] ||
		die "${dev}: lsblk reports nothing about it; refusing to write to a device it cannot identify"

	# A partition passes for a disk in every way that matters to dd and in none
	# that matter here: writing a whole-device image to one lands the partition
	# table inside a filesystem.
	[ "$type" = disk ] ||
		die "${dev} is a ${type}, not a whole disk; the image contains a partition table and goes to the disk"

	# The gadget arrives over USB and the workstation's own storage does not.
	# This is the check that stands between a mistyped letter and the machine
	# running the command.
	tran=$(lsblk_one TRAN "$dev") ||
		die "${dev}: lsblk could not read its transport; refusing to write to a device it cannot identify"
	[ "$tran" = usb ] ||
		die "${dev} is attached over '${tran:-unknown}', not usb; the device in flashing mode is a USB disk"

	model=$(lsblk_one MODEL "$dev") ||
		die "${dev}: lsblk could not read its model; refusing to write to a device it cannot identify"
	[ "$model" = "$expect_model" ] ||
		die "${dev} reports model '${model}', not '${expect_model}'; if the gadget really has been renamed, set BRENN_FLASH_EXPECT_MODEL and record the new value"

	# A desktop automounter grabs a vendor root filesystem the instant the
	# gadget enumerates, and read-write at that. Refusing here is the second
	# line of defence behind turning automount off; the first line is that
	# nothing should have mounted it at all. A query that cannot answer is a
	# refusal like the fields above, never an empty answer: "could not tell" and
	# "nothing is mounted" differ by a live filesystem.
	mounts=$(lsblk -n -o MOUNTPOINTS -- "$dev" 2>/dev/null) ||
		die "${dev}: lsblk could not read mount state; refusing to write to a device whose filesystems may be mounted (an lsblk without the MOUNTPOINTS column is too old for this tool)"
	mounts=$(printf '%s\n' "$mounts" | sed '/^[[:space:]]*$/d')
	[ -z "$mounts" ] ||
		die "${dev} or one of its partitions is mounted:"$'\n'"${mounts}"$'\n'"unmount it (and turn desktop automount off) before running this"

	echo "flash: ${dev} is ${model} over ${tran}, whole disk, nothing mounted"
}

# Fails rather than answers when it cannot measure, so that a caller says which
# thing went unmeasured instead of the run ending on a bare non-zero status.
byte_size() {
	local path=$1 n
	if [ -b "$path" ]; then
		if command -v blockdev >/dev/null 2>&1; then
			blockdev --getsize64 "$path"
			return
		fi
		n=$(lsblk -d -n -b -o SIZE -- "$path" 2>/dev/null | head -n1 | tr -d '[:space:]') || return 1
		[ -n "$n" ] || return 1
		printf '%s' "$n"
		return
	fi
	stat -Lc %s -- "$path"
}

mib() {
	echo $(($1 / 1048576))
}

# Whether reads of this path can bypass the page cache. On a block device that
# is the difference between verifying the medium and verifying what was just
# written to memory; on the regular files the host lane targets it is often
# unsupported, and there the cache is not the thing being doubted.
supports_direct() {
	dd if="$1" of=/dev/null bs="$small" count=1 iflag=direct status=none 2>/dev/null
}

# How reads of this target are going to reach the medium instead of the page
# cache: bypassed where direct I/O works, dropped where it does not. A block
# device that allows neither cannot be verified at all — what came back would be
# the memory the write had just filled, and a verify that cannot fail is not a
# verify — so that is a refusal like every other check this tool cannot run.
# Decided before anything moves, so the refusal costs nothing.
read_mode=buffered

# Between two reads of a block device that cannot be read directly, the cache
# the first one filled has to go, or the second answers out of it.
drop_cache() {
	[ "$read_mode" = flushed ] || return 0
	blockdev --flushbufs "$1" ||
		die "${1}: its buffer cache could not be dropped; refusing to verify against what may be memory rather than the medium"
}

set_read_mode() {
	local dev=$1
	if supports_direct "$dev"; then
		read_mode=direct
		return
	fi
	read_mode=buffered
	[ -b "$dev" ] || return 0
	command -v blockdev >/dev/null 2>&1 ||
		die "${dev} does not take direct reads and blockdev is not installed to drop its cache; refusing to run a verify that would read back the memory the transfer just filled"
	read_mode=flushed
	drop_cache "$dev"
}

# dd's progress meter is worth having on a fourteen-gigabyte transfer and is
# noise everywhere else.
dd_status() {
	if [ -t 2 ]; then
		printf 'status=progress'
	else
		printf 'status=none'
	fi
}

# Read exactly <count> bytes from the front of <path> to stdout, in three
# aligned pieces: bulk blocks, whole sectors, then the odd tail. Byte-exact
# matters because the read-back compares a digest over exactly as many bytes as
# the image holds, and everything past that is whatever the medium had before.
read_prefix() {
	local path=$1 count=$2 direct=$3
	local -a flags=()
	if [ "$direct" = direct ]; then
		flags=(iflag=direct)
	fi
	local bulk=$((count / big))
	local rest=$((count - bulk * big))
	local sectors=$((rest / small))
	local tail=$((rest - sectors * small))

	if [ "$bulk" -gt 0 ]; then
		dd if="$path" bs="$big" count="$bulk" status=none "${flags[@]}"
	fi
	if [ "$sectors" -gt 0 ]; then
		dd if="$path" bs="$small" skip=$((bulk * (big / small))) count="$sectors" \
			status=none "${flags[@]}"
	fi
	if [ "$tail" -gt 0 ]; then
		dd if="$path" bs=1 skip=$((bulk * big + sectors * small)) count="$tail" status=none
	fi
}

read_whole() {
	local path=$1 direct=$2
	local -a flags=()
	if [ "$direct" = direct ]; then
		flags=(iflag=direct)
	fi
	dd if="$path" bs="$big" "$(dd_status)" "${flags[@]}"
}

digest() {
	sha256sum | cut -d' ' -f1
}

# Lower-case, alphanumerics and hyphens, no runs, no edges. Model strings carry
# spaces and punctuation and end up in a file name.
slug() {
	printf '%s' "$1" |
		tr '[:upper:]' '[:lower:]' |
		sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//'
}

# --- backup ---------------------------------------------------------------

# A dump is three files that mean nothing apart, so a run that does not reach
# the end takes all three with it. A partial dump that looks like a whole one is
# the failure this tool exists to prevent.
backup_run=""
backup_keep=0

cleanup_backup() {
	if [ -n "$backup_run" ] && [ "$backup_keep" -eq 0 ]; then
		rm -rf -- "$backup_run"
	fi
}

do_backup() {
	local dev=$1 outdir=$2

	command -v zstd >/dev/null 2>&1 ||
		die "zstd is not installed; refusing to write an uncompressed whole-device dump instead"
	command -v sha256sum >/dev/null 2>&1 ||
		die "sha256sum is not installed; refusing to take a dump nothing can verify"

	[ -d "$outdir" ] || die "no such output directory: ${outdir}"

	identify "$dev"
	set_read_mode "$dev"

	local size model serial stamp stem run
	size=$(byte_size "$dev") || die "cannot determine the size of ${dev}"
	[ "$size" -gt 0 ] || die "${dev} reports a size of zero"
	model=$(lsblk_one MODEL "$dev") || die "${dev}: lsblk could not read its model"
	serial=$(lsblk_one SERIAL "$dev") || die "${dev}: lsblk could not read its serial"
	stamp=$(date -u +%Y%m%d-%H%M%S) || die "the clock could not be read"

	# Model and serial say which unit; the device name and size say which of its
	# disks, because the logical units of one gadget share a model and can share
	# a serial. Without the last two, backing up a second disk into the same
	# directory would look like an attempt to overwrite the first.
	stem="$(slug "$model")-$(slug "${serial:-noserial}")-${stamp}-$(slug "${dev##*/}")-${size}"
	run="${outdir}/${stem}"

	# The dump, its digests and its provenance are one artefact in three files,
	# so they go in one directory. Its prior existence is the no-clobber guard:
	# the one copy that will ever exist of what is on this device is not
	# something to write over.
	[ ! -e "$run" ] ||
		die "${run} already exists; refusing to write over an existing dump"
	mkdir -- "$run" || die "could not create ${run}"

	local archive="${run}/${stem}.img.zst"

	backup_run="$run"
	trap cleanup_backup EXIT

	echo "flash: reading ${size} bytes ($(mib "$size") MiB) from ${dev}"
	read_whole "$dev" "$read_mode" | zstd -T0 -q -o "$archive" ||
		die "reading ${dev} failed; nothing usable was written"

	# The verify compares the stored archive against a second reading of the
	# device, not the device against itself. Once the write happens the source
	# can never be read again, so the pass has to cover the workstation side
	# too: a truncated stream, a killed compressor or a bad sector under the
	# output file all fail here instead of years later.
	echo "flash: verifying — reading ${dev} again and decompressing what was stored"
	drop_cache "$dev"
	local device_sha stored_sha archive_sha
	device_sha=$(read_whole "$dev" "$read_mode" | digest) ||
		die "the second read of ${dev} failed; the dump is unverified and has been removed"
	stored_sha=$(zstd -dc -- "$archive" | digest) ||
		die "${archive} does not decompress; the dump has been removed"

	[ "$device_sha" = "$stored_sha" ] ||
		die "the stored dump does not match the device: device ${device_sha}, stored ${stored_sha}; the dump has been removed"

	archive_sha=$(sha256sum -- "$archive" | cut -d' ' -f1)

	# Digests of what is on disk, not of what went past in the stream. The raw
	# line names a file that is not stored — it is what `zstd -d` produces — so
	# a check run without decompressing first uses --ignore-missing.
	{
		printf '%s  %s.img\n' "$device_sha" "$stem"
		printf '%s  %s.img.zst\n' "$archive_sha" "$stem"
	} >"${run}/SHA256SUMS"

	{
		echo "Whole-device dump taken before the medium was overwritten."
		echo
		echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "source:      ${dev}"
		echo "model:       ${model}"
		echo "serial:      ${serial}"
		echo "size:        ${size} bytes ($(mib "$size") MiB)"
		echo "read:        ${read_mode}"
		echo "invocation:  ${prog} backup ${dev} ${outdir}"
		echo
		echo "SHA256SUMS carries two digests: ${stem}.img is the decompressed"
		echo "content, which is not stored, and ${stem}.img.zst is the file"
		echo "beside this one. To check what is here:"
		echo
		echo "  sha256sum -c --ignore-missing SHA256SUMS"
		echo
		echo "To put it back on a device, decompress it and write it:"
		echo
		echo "  zstd -d ${stem}.img.zst"
		echo "  sudo flash.sh write /dev/sdX ${stem}.img"
	} >"${run}/PROVENANCE.txt"

	backup_keep=1
	echo "flash: dump verified, sha256 ${device_sha}"
	echo "flash: wrote ${run}"
	echo "flash: keep it outside any repository — it is this unit's data"
}

# --- write ----------------------------------------------------------------

do_write() {
	local dev=$1 image=$2

	command -v sha256sum >/dev/null 2>&1 ||
		die "sha256sum is not installed; refusing to write an image nothing can verify"

	[ -f "$image" ] || die "no such image: ${image}"

	# The sparse copy the build writes alongside the raw image is an Android
	# sparse container, not a filesystem image: written literally it produces a
	# device holding a description of an image rather than an image.
	case "$image" in
		*.sparse)
			die "${image} is a sparse image; convert it first: simg2img ${image} ${image%.sparse}.img"
			;;
	esac
	if [ "$(head -c4 -- "$image" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
		die "${image} is in Android sparse format whatever its name; convert it first with simg2img"
	fi

	identify "$dev"

	local image_size dev_size
	image_size=$(byte_size "$image") || die "cannot determine the size of ${image}"
	dev_size=$(byte_size "$dev") || die "cannot determine the size of ${dev}"
	[ "$image_size" -gt 0 ] || die "${image} is empty"

	# The layout's fit against the smallest medium the profile may assume is
	# asserted off-device; this is the same fact asked of the medium actually in
	# hand, before a byte moves.
	[ "$dev_size" -ge "$image_size" ] ||
		die "${image} is ${image_size} bytes ($(mib "$image_size") MiB) and ${dev} holds ${dev_size} ($(mib "$dev_size") MiB); refusing to write a truncated image"

	# Direct writes skip the page cache, which on a fourteen-gigabyte transfer is
	# the difference between a progress meter that means something and one that
	# reports memory filling up. The kernel takes only whole sectors that way,
	# so an image whose length is not a sector multiple goes through the cache
	# and is pushed out by conv=fsync instead.
	local -a wflags=()
	if [ -b "$dev" ] && [ $((image_size % small)) -eq 0 ]; then
		wflags=(oflag=direct)
	fi

	# Asked before the transfer rather than after it: a device whose read-back
	# could only come from the page cache is refused while it still holds what it
	# shipped with, not once fourteen gigabytes have landed on it.
	set_read_mode "$dev"

	echo "flash: writing ${image_size} bytes ($(mib "$image_size") MiB) to ${dev}"
	dd if="$image" of="$dev" bs="$big" conv=notrunc,fsync "$(dd_status)" "${wflags[@]}" ||
		die "the write to ${dev} failed; the device now holds a torn image — re-enter flashing mode and run this again"

	# Reading back through the page cache would verify memory against the file
	# that filled it, so what the write left there goes before the read.
	drop_cache "$dev"

	echo "flash: verifying — reading ${image_size} bytes back from ${dev}"
	local image_sha dev_sha
	image_sha=$(digest <"$image") || die "${image} could not be read back to digest it"
	dev_sha=$(read_prefix "$dev" "$image_size" "$read_mode" | digest) ||
		die "reading ${dev} back failed; the write is unverified — run this again"

	[ "$image_sha" = "$dev_sha" ] ||
		die "${dev} does not hold what was written: image ${image_sha}, device ${dev_sha}; the write did not take — run it again"

	echo "flash: verified sha256 ${image_sha}"

	# The partitions the image brought only exist to the kernel once it has read
	# the new table, and the very next step of the install addresses one of them
	# by name.
	local persistent=""
	if [ -b "$dev" ]; then
		if command -v blockdev >/dev/null 2>&1; then
			blockdev --rereadpt "$dev" ||
				echo "flash: ${dev} kept its old partition table; unplug and replug, or reboot, before provisioning" >&2
		fi
		persistent=$(lsblk -n -o PATH,PARTLABEL -- "$dev" 2>/dev/null |
			awk '$2 == "persistent" { print $1; exit }' || true)
	fi

	echo "flash: ${image} is on ${dev}"
	if [ -n "$persistent" ]; then
		echo "flash: next: sudo scripts/provision.sh ${persistent} <generation-dir>"
	else
		echo "flash: next: provision the partition labelled 'persistent' —"
		echo "flash:       sudo scripts/provision.sh /dev/disk/by-partlabel/persistent <generation-dir>"
	fi
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
esac

if [ $# -ne 3 ]; then
	usage
	exit 2
fi

mode=$1
device=$2
target=$3

case "$mode" in
	backup | write) ;;
	*)
		usage
		exit 2
		;;
esac

# Bash's own answer, so that the refusal below still happens when the tool is
# run with nothing on its path — which is how the missing-lsblk refusal is
# reached, and it should be reached rather than crashed past.
[ "${EUID}" -eq 0 ] ||
	die "reading or writing a whole device needs root"

# No fallback when the tool that identifies the target is absent. Every guard
# above reads lsblk, and a run that skipped them with a warning would be a run
# that wrote fourteen gigabytes to a device on the strength of a line the
# operator scrolled past.
command -v lsblk >/dev/null 2>&1 ||
	die "lsblk is not installed; refusing to touch a device whose identity cannot be read"

case "$mode" in
	backup) do_backup "$device" "$target" ;;
	write) do_write "$device" "$target" ;;
esac
