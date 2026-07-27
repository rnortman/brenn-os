#!/usr/bin/env bash
#
# The partition table is the layout contract: names, order, sizes, and that the
# whole thing fits the medium it is going to be written to.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open

t_eq "partition names and order" \
	"${IMG_PART_NAME[*]}" "$EXPECT_PART_NAMES"

# Sizes are compared in MiB. Partition sizes are exact (alignment affects
# starts, not sizes), so a drift here means a knob moved.
sizes_mib=()
for s in "${IMG_PART_SIZE[@]}"; do
	sizes_mib+=("$((s * IMG_SECTOR_SIZE / 1048576))")
done
t_eq "partition sizes (MiB)" "${sizes_mib[*]}" "$EXPECT_PART_SIZES_MIB"

# The end of the last partition, not the file size: a sparse or truncated image
# file says nothing about what the layout demands of the medium.
last=$((${#IMG_PART_START[@]} - 1))
end_bytes=$(((IMG_PART_START[last] + IMG_PART_SIZE[last]) * IMG_SECTOR_SIZE))
t_le "layout fits the smallest assumed medium" "$end_bytes" "$EXPECT_MEDIA_MIN_BYTES"

# Exactly one writable partition. Everything else is either read-only at
# runtime or touched only by an update.
t_eq "one persistent partition" \
	"$(printf '%s\n' "${IMG_PART_NAME[@]}" | grep -c '^persistent$')" "1"

t_done
