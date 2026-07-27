#!/usr/bin/env bash
#
# The two halves of the A/B pair ship identical, byte for byte.
#
# This is what the rest of the update story rests on. The firmware picks a boot
# partition and the initramfs derives the root from that choice, so nothing may
# address a slot by filesystem UUID — the two carry the same one. It is also
# what lets every other test in this suite read slot A and call the answer a
# property of the device: whichever slot it comes up on, it is this image.
#
# Compared whole rather than file by file, because a sampled comparison only
# defends the files somebody thought to name.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd cmp
img_open

# The two ranges are compared inside the one image file rather than extracted
# first: no temporary the size of a slot, and a single pass over each.
compare_slots() {
	local a=$1 b=$2 i j off_a off_b size_a size_b detail
	if ! i=$(img_part_index "$a") || ! j=$(img_part_index "$b"); then
		t_fail "${a} and ${b} are byte-identical" "one of the partitions is not in the table"
		return
	fi

	size_a=$((IMG_PART_SIZE[i] * IMG_SECTOR_SIZE))
	size_b=$((IMG_PART_SIZE[j] * IMG_SECTOR_SIZE))
	if [ "$size_a" -ne "$size_b" ]; then
		t_fail "${a} and ${b} are the same size" \
			"${a}: ${size_a} bytes" "${b}: ${size_b} bytes"
		return
	fi

	off_a=$((IMG_PART_START[i] * IMG_SECTOR_SIZE))
	off_b=$((IMG_PART_START[j] * IMG_SECTOR_SIZE))
	if detail=$(cmp -i "${off_a}:${off_b}" -n "$size_a" -- "$IMG" "$IMG" 2>&1); then
		t_pass "${a} and ${b} are byte-identical (${size_a} bytes)"
	else
		t_fail "${a} and ${b} are byte-identical" "${detail}"
	fi
}

compare_slots boot_a boot_b
compare_slots system_a system_b

t_done
