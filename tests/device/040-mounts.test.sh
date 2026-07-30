#!/usr/bin/env bash
#
# What is mounted, and which slot the device is running.
#
# The flash-wear invariant reduces to one census: of everything backed by a
# block device, exactly one filesystem is writable. Everything else that a
# general-purpose Debian would write to disk is either in RAM or does not exist
# — so this test enumerates the whole set rather than checking the mounts it
# expects to find, because a fourth entry nobody looked for is the failure mode
# it exists to catch.
#
# The slot half is the other thing only a running device can answer: the
# firmware reports which partition it booted, and everything that administers
# the device — the update mechanism above all — addresses slots through the
# links derived from that report.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# Target, filesystem type and writability for every mount whose source is a
# block device. Parsed here rather than on the device: the remote end stays a
# command anyone can retype by hand when a reading needs chasing down.
dev_capture 'findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS'
census=$(printf '%s\n' "$DEV_OUT" | awk '
	$2 ~ /^\/dev\// {
		split($4, opts, ",")
		print $1, $3, opts[1]
	}
' | sort)

t_eq_text "exactly one block-backed filesystem is writable" \
	"$census" \
	"$(printf '%s\n' "$EXPECT_BLOCK_MOUNTS" | sort)"

# /data is the name every contract in this project uses; the layout calls the
# partition something else, and the image bakes the link between the two.
dev_eq "/data resolves to the persistent partition" \
	'readlink -f /data' /persistent
dev_eq "/data is the writable partition, not a directory on the root" \
	'findmnt -rno TARGET --target /data' /persistent

# The mounts the layout would have given us, held back in the image because each
# one is a steady write to the flash. Their absence is what makes the census
# above the whole story.
while IFS= read -r target; do
	[ -n "$target" ] || continue
	dev_refuses "nothing is mounted at ${target}" \
		"mountpoint -q $(dev_quote "$target")"
done <<<"$EXPECT_ABSENT_MOUNTPOINTS"

# The application's filesystem: in RAM, capped, and present before anything
# tries to unpack a payload into it.
dev_eq "the application filesystem is a tmpfs" \
	"findmnt -rno FSTYPE $(dev_quote "$EXPECT_APP_DIR")" "$EXPECT_APP_MOUNT_FSTYPE"
dev_eq "the application filesystem is capped at the profile's size" \
	"findmnt -rno SIZE -b $(dev_quote "$EXPECT_APP_DIR")" \
	"$((EXPECT_APP_MOUNT_SIZE_K * 1024))"

# The slot links, and the firmware's own report of what it booted. A mismatch
# here is the single most expensive thing that can be wrong on this device: an
# update installed into "the other slot" would land on the running one.
for link in $EXPECT_SLOT_LINKS; do
	dev_exists "the slot link ${link} exists" "${EXPECT_SLOT_LINK_DIR}/${link}"
done

if ! dev_firmware_partition; then
	t_fail "the firmware reports which partition it booted" \
		"read of ${EXPECT_DT_BOOTLOADER_DIR}/partition returned: ${DEV_OUT:-<nothing>}"
	t_done
fi
booted=$DEV_PARTITION
t_pass "the firmware reports booting partition ${booted}"

# The boot partition the firmware named, and the boot partition the active-slot
# link points at, have to be the same device.
dev_capture "readlink -f ${EXPECT_SLOT_LINK_DIR}/active/boot"
active_boot=$DEV_OUT
active_number=$(dev_partition_number "$active_boot")
if [ "${active_number:-x}" = "$booted" ]; then
	t_pass "the active-slot boot link is the partition the firmware booted (${active_boot})"
else
	t_fail "the active-slot boot link is the partition the firmware booted" \
		"firmware booted partition: ${booted}" \
		"active/boot resolves to:   ${active_boot:-<nothing>}"
fi

# And the other slot is the other one. Two links resolving to the same device
# would let an update write the pair it is running from.
dev_capture "readlink -f ${EXPECT_SLOT_LINK_DIR}/other/system"
other_system=$DEV_OUT
dev_capture "readlink -f ${EXPECT_SLOT_LINK_DIR}/active/system"
if [ "$DEV_OUT" != "$other_system" ]; then
	t_pass "the two system slots are different partitions"
else
	t_fail "the two system slots are different partitions" \
		"both resolve to ${other_system}"
fi

t_done
