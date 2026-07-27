#!/usr/bin/env bash
#
# The boot firmware configuration carries the carrier's hardware description:
# without these lines the servo bus, the fan, the cameras and the IMU do not
# appear at all. Asserted line by line rather than as a whole file so that
# adding an unrelated setting does not fail the test, but losing a device does.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd mtype
img_open

if ! content=$(img_vfat_cat "$IMG" boot_a config.txt); then
	t_fail "read config.txt from boot_a"
	t_done
fi

settings=$(printf '%s\n' "$content" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*#' | grep -v '^$')

while IFS= read -r want; do
	[ -n "$want" ] || continue
	t_contains "config.txt has ${want}" "$settings" "$want"
done <<<"$EXPECT_CONFIG_LINES"

while IFS= read -r unwanted; do
	[ -n "$unwanted" ] || continue
	if printf '%s\n' "$settings" | grep -qxF -- "$unwanted"; then
		t_fail "config.txt must not set ${unwanted}"
	else
		t_pass "config.txt does not set ${unwanted}"
	fi
done <<<"$EXPECT_CONFIG_ABSENT"

t_done
