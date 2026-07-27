#!/usr/bin/env bash
#
# What the cross-lane comparison compares.
#
# Two lanes build this product — natively on a Debian arm64 host, and through
# the pinned container everywhere else — and the claim that they build the same
# thing rests entirely on the manifest scripts/image-manifest.sh reduces an
# image to. A field it drops is a difference the comparison cannot see, and a
# field it keeps that is generated per build is a comparison that is red every
# time and stops being read. So the reduction is asserted here, against a
# fabricated image small enough to build in the gate: a real GPT table, a real
# ext4 filesystem, and a package database with the three stanza shapes that
# decide what shipped.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=scripts/lib/image-read.sh
. "${BRENN_REPO_ROOT}/scripts/lib/image-read.sh"
# The image suite's own readers, asserted here because this is the lane that
# builds a filesystem to read: the suite runs only where an image was built, and
# a reader nothing exercises is a verdict nobody checked.
#
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd sfdisk jq diff

mke2fs=$(imgread_find_tool mke2fs) || t_skip "requires mke2fs (e2fsprogs), which is not installed"
imgread_debugfs >/dev/null || t_skip "requires debugfs (e2fsprogs), which is not installed"

manifest_sh="${BRENN_REPO_ROOT}/scripts/image-manifest.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a fabricated build output ---------------------------------------------

# The three shapes the database distinguishes: installed with a version (it
# shipped), installed without one (never unpacked, so it did not), and a
# removal that left configuration behind (it is gone).
mkdir -p "${tmp}/root/usr/share/factory/var/lib/dpkg"
cat >"${tmp}/root/usr/share/factory/var/lib/dpkg/status" <<-'EOF'
	Package: shipped
	Status: install ok installed
	Version: 1.0-1

	Package: unpacked-never
	Status: install ok installed

	Package: removed
	Status: deinstall ok config-files
	Version: 2.0-1
EOF

# The three shapes the link reader distinguishes. ext4 keeps a short target in
# the inode and a long one in a block, and the two are read differently — the
# shipped image happens to carry only the second kind at one place, so without
# these the fallback is a branch no assertion has run.
short_target=../short.service
long_target=../../../../usr/lib/systemd/system/systemd-networkd-wait-online.service
ln -s "$short_target" "${tmp}/root/short.link"
ln -s "$long_target" "${tmp}/root/long.link"
printf 'not a link\n' >"${tmp}/root/regular.file"

part_blocks=10240
"$mke2fs" -q -t ext4 -b 1024 -d "${tmp}/root" -F "${tmp}/system.ext4" "$part_blocks" 2>/dev/null ||
	t_skip "mke2fs cannot populate a filesystem from a directory here"

out="${tmp}/out"
mkdir -p "$out"
img="${out}/tiny.img"
truncate -s 16M "$img"

# start and size in 512-byte sectors; 20480 sectors is the 10 MiB filesystem.
sfdisk -q "$img" >/dev/null 2>&1 <<-'EOF'
	label: gpt
	unit: sectors
	start=2048, size=20480, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="system_a"
EOF
dd if="${tmp}/system.ext4" of="$img" bs=512 seek=2048 conv=notrunc status=none

# The description a build writes next to the image. The values a comparison
# must never see are distinctive here so their absence is assertable: the
# filesystem uuid the layout mints per build, and the path the build ran at.
outputdir=/somewhere/only/this/build/knows
fs_uuid=deadbeef-0000-4000-8000-feedfacecafe
cat >"${out}/image.json" <<-EOF
	{
	  "IGversion": "2.2.0",
	  "IGmeta": {
	    "IGconf_device_sector_size": 512,
	    "IGconf_image_outputdir": "${outputdir}",
	    "IGconf_device_variant": "8G",
	    "IGconf_device_class": "cm4",
	    "IGconf_image_version": "2026-07-27",
	    "IGconf_device_storage_type": "emmc"
	  },
	  "attributes": {
	    "image-name": "tiny.img",
	    "image-size": 16777216,
	    "image-palign-bytes": "8M"
	  },
	  "layout": {
	    "partitiontable": { "label": "gpt", "id": "11111111-2222-3333-4444-555555555555" },
	    "partitionimages": {
	      "system_a": {
	        "name": "system_a",
	        "in-partition-table": "true",
	        "size": 10485760,
	        "mountpoint": "/",
	        "image": "system.ext4",
	        "partition-type-uuid": "0FC63DAF-8483-4772-8E79-3D69D8477DE4",
	        "type": "ext4",
	        "fs_uuid": "${fs_uuid}",
	        "fs_label": "SYSTEM",
	        "partition-uuid": "66666666-7777-8888-9999-aaaaaaaaaaaa"
	      }
	    }
	  }
	}
EOF

manifest=$("$manifest_sh" emit --dir "$out" 2>"${tmp}/emit.err")
status=$?
if [ "$status" -ne 0 ]; then
	t_fail "the emitter reads a built image" "exit ${status}" "$(cat "${tmp}/emit.err")"
	t_done
fi

t_contains "the image's own version is recorded — it names the build" \
	"$manifest" "description image-version 2026-07-27"
t_contains "and the hardware the image was built for" \
	"$manifest" "description device-class cm4"
t_contains "the partition table is read from the image, not from the description" \
	"$manifest" "partition 1 name=system_a start=2048 size=20480 type=0FC63DAF-8483-4772-8E79-3D69D8477DE4 attrs="

# The geometry, field by field. The two lba bounds depend on the sfdisk that
# wrote the table, so what is asserted of them is that they are recorded at all —
# a manifest carrying `first-lba=` says nothing about the table it came from.
table_line=$(printf '%s\n' "$manifest" | grep '^table ' | head -n1)
t_eq "the table's own label is recorded" "$(imgread_field "$table_line" label)" gpt
t_eq "and the sector size the offsets are resolved at" \
	"$(imgread_field "$table_line" sector-size)" 512
t_eq "and where the usable area begins" \
	"$([ -n "$(imgread_field "$table_line" first-lba)" ] && echo yes)" yes
t_eq "and where it ends" \
	"$([ -n "$(imgread_field "$table_line" last-lba)" ] && echo yes)" yes
t_contains "each filesystem the layout builds, by what it is and where it mounts" \
	"$manifest" \
	"partimage system_a type=ext4 size=10485760 label=SYSTEM mountpoint=/ source=system.ext4 in-table=true bootable=false type-uuid=0FC63DAF-8483-4772-8E79-3D69D8477DE4"

# The package set comes out of the filesystem in the image, which is the only
# reading here that is a fact about what shipped rather than about what the
# build said it would ship.
t_contains "a package with a version installed shipped" \
	"$manifest" "package shipped 1.0-1"
t_eq "one that was never unpacked did not" \
	"$(printf '%s\n' "$manifest" | grep -c '^package unpacked-never')" 0
t_eq "and neither did one whose removal left configuration behind" \
	"$(printf '%s\n' "$manifest" | grep -c '^package removed')" 0

# --- what it must not record -----------------------------------------------

label_id=$(sfdisk --dump "$img" | sed -n 's/^label-id: *//p')
t_eq "the table has an id at all, so its absence below means something" \
	"$([ -n "$label_id" ] && echo yes)" yes
t_eq "the table's generated id is not compared — uuidgen writes a new one per build" \
	"$(printf '%s\n' "$manifest" | grep -cF "$label_id")" 0
t_eq "nor is a filesystem uuid, for the same reason" \
	"$(printf '%s\n' "$manifest" | grep -cF "$fs_uuid")" 0
t_eq "nor is a partition uuid" \
	"$(printf '%s\n' "$manifest" | grep -cF "66666666-7777-8888-9999-aaaaaaaaaaaa")" 0
t_eq "nor where the build ran — the two lanes see the repository at different paths" \
	"$(printf '%s\n' "$manifest" | grep -cF "$outputdir")" 0

# A manifest that reorders between two runs of the same build is a diff nobody
# can read, which is the same as no comparison at all.
t_eq_text "reading the same image twice gives the same manifest" \
	"$("$manifest_sh" emit --dir "$out")" "$manifest"

printf '%s\n' "$manifest" >"${tmp}/a.txt"
printf '%s\n' "$manifest" >"${tmp}/b.txt"

"$manifest_sh" compare "${tmp}/a.txt" "${tmp}/b.txt" >"${tmp}/same.out" 2>&1
t_eq "two lanes that built the same image compare clean" "$?" 0

sed 's/^package shipped 1.0-1$/package shipped 1.0-2/' "${tmp}/a.txt" >"${tmp}/c.txt"
"$manifest_sh" compare "${tmp}/a.txt" "${tmp}/c.txt" >"${tmp}/diff.out" 2>&1
t_eq "one package version apart, they do not" "$?" 1
t_eq "and the difference is named rather than counted" \
	"$(grep -c '^+package shipped 1.0-2$' "${tmp}/diff.out")" 1

"$manifest_sh" compare "${tmp}/a.txt" "${tmp}/absent.txt" >"${tmp}/missing.out" 2>&1
t_eq "a manifest that never arrived is a failure, not an agreement" "$?" 1

"$manifest_sh" emit --dir "${tmp}/empty" >"${tmp}/nodir.out" 2>&1
t_eq "so is a build output directory with no image description in it" "$?" 1

# --- the entry point CI actually takes -------------------------------------
#
# CI names no directory and writes to a file, so finding the build output and
# writing the manifest are the production path, and every assertion above goes
# through neither. A break in them shows up at the end of a multi-hour emulated
# build instead of here.

"$manifest_sh" emit --dir "$out" --output "${tmp}/written.txt" 2>"${tmp}/written.err"
t_eq "writing the manifest to a file succeeds" "$?" 0
t_eq_text "and records what printing it records" "$(cat "${tmp}/written.txt")" "$manifest"

work="${tmp}/work"
mkdir -p "${work}/image-one"
cp "${out}/image.json" "$img" "${work}/image-one/"
BRENN_WORK_DIR="$work" "$manifest_sh" emit >"${tmp}/resolved.txt" 2>"${tmp}/resolved.err"
t_eq "a caller that names no directory gets the one build output there is" "$?" 0
t_eq_text "and the same manifest naming it would have given" \
	"$(cat "${tmp}/resolved.txt")" "$manifest"

mkdir -p "${work}/image-two"
BRENN_WORK_DIR="$work" "$manifest_sh" emit >/dev/null 2>"${tmp}/two.err"
t_eq "two build outputs is a question for the caller, not a guess" "$?" 1
t_ge "and the refusal names them rather than counting them" \
	"$(grep -c 'image-two' "${tmp}/two.err")" 1

BRENN_WORK_DIR="${tmp}/no-such-work" "$manifest_sh" emit >/dev/null 2>"${tmp}/none.err"
t_eq "no build output at all is refused rather than reduced to nothing" "$?" 1

# A read that failed and a database that moved are different findings, and the
# second is the one that sends a reader off to the image's packaging. Here the
# partition holds no filesystem at all.
broken="${tmp}/broken"
mkdir -p "$broken"
cp "${out}/image.json" "$broken/"
truncate -s 16M "${broken}/tiny.img"
sfdisk -q "${broken}/tiny.img" >/dev/null 2>&1 <<-'EOF'
	label: gpt
	unit: sectors
	start=2048, size=20480, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="system_a"
EOF
"$manifest_sh" emit --dir "$broken" >/dev/null 2>"${tmp}/broken.err"
t_eq "a filesystem that cannot be read is a failure" "$?" 1
t_ge "reported as one, rather than as a package database that moved" \
	"$(grep -c 'cannot read system_a' "${tmp}/broken.err")" 1

# --- the link reader every enablement verdict comes out of ------------------
#
# ext4 keeps a short symlink target in the inode and a long one in a block, and
# they are read differently. The shipped image carries one link past that limit,
# so the fallback decides whether a real assertion passes — on a branch the
# image suite cannot exercise until the image already has such a link.

IMG_DEBUGFS=$(imgread_debugfs)
spec="${img}?offset=$((2048 * 512))"

t_eq "a target short enough to live in the inode is read from it" \
	"$(img_ext4_link "$spec" /short.link)" "$short_target"
t_eq "and one too long for that is read out of its block" \
	"$(img_ext4_link "$spec" /long.link)" "$long_target"
t_eq "the type the fallback is guarded on is what debugfs reports" \
	"$(img_ext4_type "$spec" /long.link)" symlink
t_eq "so a regular file cannot be read as a link to its own contents" \
	"$(
		img_ext4_link "$spec" /regular.file >/dev/null 2>&1
		echo $?
	)" 1

t_done
