#!/usr/bin/env bash
#
# The kernel command line, exact-matched. Read-only root and slot-relative root
# addressing are invariants, and both live on this one line; a stray argument
# here is how a device quietly comes up writable.
#
# Read from boot_a: 015 is what holds the other slot identical to it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd mtype
img_open

if content=$(img_vfat_cat "$IMG" boot_a cmdline.txt); then
	# The file is one line; a trailing newline is not part of the command line.
	t_eq "cmdline.txt" "$(printf '%s' "$content" | tr -d '\n')" "$EXPECT_CMDLINE"
else
	t_fail "read cmdline.txt from boot_a"
fi

t_done
