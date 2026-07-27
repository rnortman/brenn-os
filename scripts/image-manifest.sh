#!/usr/bin/env bash
#
# Reduce a built image to a manifest, and compare two of them.
#
#   scripts/image-manifest.sh emit [--dir <build output dir>] [--output <file>]
#   scripts/image-manifest.sh compare <manifest> <manifest>
#
# An image is gigabytes, so the two lanes that build one — natively on a Debian
# arm64 host, and through the pinned container on any other host — are held to
# each other through this file instead. What it records is the partition table
# as written to the image, the identity fields of the build's own image
# description, and the package set the root filesystem ships: enough that a lane
# producing a different product says so, and small enough to keep.
#
# Two classes of fact are left out, both because they already differ between two
# builds of the same tree on the same machine:
#
#   - Generated identifiers. The layout mints them with uuidgen at build time:
#     the partition table id, each partition uuid, and each filesystem uuid.
#   - Where the build ran. The output directory is a path on the build host, and
#     the two lanes see the repository at different paths by design.
#
# Everything else the description carries is compared. File content is not
# visible here at all — that is what comparing the images themselves would add,
# once the two lanes are observed to agree at this level.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prog=$(basename -- "$0")

# The image is decoded with the same readers the image suite asserts against,
# so the comparison and the suite cannot come to different conclusions about
# the same file.
#
# shellcheck source=scripts/lib/image-read.sh
. "${repo_root}/scripts/lib/image-read.sh"

# Both system slots are written from the same root filesystem image, so one
# stands for both. The image suite is what holds that true.
system_part=system_a

die() {
	echo "${prog}: $1" >&2
	shift
	local line
	for line in "$@"; do
		echo "    ${line}" >&2
	done
	exit 1
}

usage() {
	cat >&2 <<-EOF
	usage: ${prog} emit [--dir <build output dir>] [--output <file>]
	       ${prog} compare <manifest> <manifest>
	EOF
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v -- "$cmd" >/dev/null 2>&1 ||
			die "${cmd} is not installed, and reading an image needs it"
	done
}

# The build output directory, when the caller names none. A build writes one
# per image name, so anything other than exactly one directory is a question
# the caller has to answer rather than one to guess at.
#
# BRENN_WORK_DIR moves the build area this looks in, which is how a build kept
# somewhere else is reduced and how this resolution is asserted without a build.
resolve_dir() {
	local work=${BRENN_WORK_DIR:-${repo_root}/work}
	local -a dirs=()
	while IFS= read -r d; do
		dirs+=("$d")
	done < <(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'image-*' 2>/dev/null | sort)

	case ${#dirs[@]} in
		1) printf '%s' "${dirs[0]}" ;;
		0) die "no build output under ${work} — run: make image" ;;
		*) die "more than one build output under ${work}" "name one with --dir:" "${dirs[@]}" ;;
	esac
}

# The identity fields of the image description, one `key value` per line. Read
# with jq rather than a text scrape so a field that moves is a null in the
# output and a diff in the comparison, not a silently absent line.
emit_description() {
	jq -er '
		[
			["builder-version", .IGversion],
			["image-name", .attributes["image-name"]],
			["image-size", .attributes["image-size"]],
			["image-palign-bytes", .attributes["image-palign-bytes"]],
			["image-version", .IGmeta.IGconf_image_version],
			["device-class", .IGmeta.IGconf_device_class],
			["device-variant", .IGmeta.IGconf_device_variant],
			["device-storage-type", .IGmeta.IGconf_device_storage_type],
			["device-sector-size", .IGmeta.IGconf_device_sector_size]
		]
		| .[] | "description \(.[0]) \(.[1])"
	' -- "$1"
}

# One line per filesystem the layout builds, in name order: what it is, how big,
# where it mounts, and which file it was written from. The filesystem uuids
# alongside these in the description are generated per build and left out.
emit_partition_images() {
	jq -er '
		.layout.partitionimages | to_entries | sort_by(.key) | .[] |
		"partimage \(.key)" +
		" type=\(.value.type)" +
		" size=\(.value.size)" +
		" label=\(.value.fs_label // "-")" +
		" mountpoint=\(.value.mountpoint // "-")" +
		" source=\(.value.image)" +
		" in-table=\(.value["in-partition-table"] // "false")" +
		" bootable=\(.value.bootable // "false")" +
		" type-uuid=\(.value["partition-type-uuid"])"
	' -- "$1"
}

# The shipped package set, sorted. A stanza with no version was never unpacked
# and did not ship; what the recorded status says beyond that is the image
# suite's question, asserted there against the reviewed manifest.
# A failed read and a moved database are different findings, so the reader's own
# status decides which is reported: debugfs exits nonzero when it cannot read the
# filesystem, and exits 0 with nothing to show when the path is not there. Taking
# empty output for the only signal would report an unreadable image, or one read
# at the wrong offset, as a packaging change — and would accept a read that
# failed partway through, which parses cleanly as a shorter package list.
emit_packages() {
	local img=$1 offset=$2 debugfs status err
	debugfs=$(imgread_debugfs) ||
		die "debugfs (e2fsprogs) is not installed, and the package set is read with it"
	# The reader's stderr carries a version banner as well as its errors, so it
	# is kept out of the data and read back only when the read failed.
	err=$(mktemp)
	if ! status=$("$debugfs" -R "cat ${imgread_dpkg_status_path}" "${img}?offset=${offset}" 2>"$err" </dev/null); then
		local message
		message=$(cat -- "$err")
		rm -f -- "$err"
		die "cannot read ${system_part} at offset ${offset} of ${img}" "$message"
	fi
	rm -f -- "$err"
	[ -n "$status" ] || die "no package database at ${imgread_dpkg_status_path} in ${system_part}" \
		"the image was built and its filesystem reads, so this is a change in where the database ships"

	imgread_dpkg_installed "$status" | sed 's/^/package /' | sort
}

emit() {
	local dir="" output=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--dir)
				dir=${2:-}
				[ -n "$dir" ] || die "--dir needs a directory"
				shift 2
				;;
			--output)
				output=${2:-}
				[ -n "$output" ] || die "--output needs a file"
				shift 2
				;;
			*)
				usage
				exit 1
				;;
		esac
	done

	require_cmd jq sfdisk

	[ -n "$dir" ] || dir=$(resolve_dir)
	local json="${dir}/image.json"
	[ -f "$json" ] || die "no image description at ${json}" \
		"emit reads a build's output directory — run: make image"

	local name img
	name=$(jq -er '.attributes["image-name"]' -- "$json") ||
		die "the image description at ${json} names no image"
	img="${dir}/${name}"
	[ -f "$img" ] || die "the description names ${name}, which is not in ${dir}"

	# The table as it was written to the image, which is the fact the
	# description only describes. Recording it and reading the package set out
	# of it go through one decode, so the offset in the manifest and the offset
	# the filesystem is read at cannot disagree.
	local dump table offset
	dump=$(sfdisk --dump -- "$img" 2>/dev/null) || die "cannot read a partition table from ${img}"
	table=$(imgread_table "$dump") || die "cannot make sense of the partition table in ${img}"
	offset=$(imgread_part_offset_bytes "$table" "$system_part") ||
		die "no ${system_part} partition in ${img}"

	{
		echo "# brenn-os image manifest v1 — what two builds of this tree must agree on."
		echo "# Generated identifiers and the build's own location are excluded by"
		echo "# construction; see scripts/image-manifest.sh for what that covers."
		emit_description "$json"
		printf '%s\n' "$table"
		emit_partition_images "$json"
		emit_packages "$img" "$offset"
	} >"${output:-/dev/stdout}"
}

compare() {
	[ $# -eq 2 ] || {
		usage
		exit 1
	}
	local a=$1 b=$2 f
	for f in "$a" "$b"; do
		[ -f "$f" ] || die "no manifest at ${f}"
	done

	if diff -u -- "$a" "$b"; then
		echo "${prog}: the two builds describe the same image ($(grep -vc '^#' -- "$a") recorded facts)."
		return 0
	fi

	cat >&2 <<-EOF
	${prog}: the two builds do not describe the same image.

	    The diff above is the finding: one lane produced a different product from
	    the same tree. It gets read and understood before either lane or this
	    comparison is changed — a difference explained away is a difference
	    shipped.
	EOF
	return 1
}

cmd=${1:-}
case "$cmd" in
	emit)
		shift
		emit "$@"
		;;
	compare)
		shift
		compare "$@"
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage
		exit 1
		;;
esac
