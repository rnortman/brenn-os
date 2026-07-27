#!/usr/bin/env bash
#
# autoboot.txt is what the firmware reads to decide which boot partition to
# start, and the file an update rewrites to commit a slot flip. Its exact
# contents and its size are both load-bearing.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd mtype
img_open

if ! content=$(img_vfat_cat "$IMG" bootconfig autoboot.txt); then
	t_fail "read autoboot.txt from the bootconfig partition"
	t_done
fi

t_eq_text "autoboot.txt contents" "$content" "$EXPECT_AUTOBOOT"

# The firmware stops reading past this, and a rewrite that grew beyond it would
# be silently truncated rather than rejected.
bytes=$(printf '%s\n' "$content" | wc -c)
t_le "autoboot.txt within the firmware's read limit" \
	"$bytes" "$EXPECT_AUTOBOOT_MAX_BYTES"

t_done
