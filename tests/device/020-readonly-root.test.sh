#!/usr/bin/env bash
#
# The root filesystem is read-only, and the kernel got there the way we said it
# would.
#
# The image suite asserts what fstab and the kernel command line say. This
# asserts what the kernel did with them, which is the claim that matters: a
# filesystem mounted rw despite an `ro` in fstab is a device quietly wearing
# out its flash and losing its A/B guarantee at the same time.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

dev_eq "the root filesystem is ext4" 'findmnt -no FSTYPE /' ext4
dev_eq "the root filesystem is mounted read-only" \
	'findmnt -no OPTIONS / | cut -d, -f1' ro
dev_eq "the firmware partition is mounted read-only" \
	'findmnt -no OPTIONS /boot/firmware | cut -d, -f1' ro

# The assertion the two above exist for. A mount option can be reported and not
# enforced; a write that fails is the property itself.
probe=/etc/brenn-write-probe
dev_refuses "writing to the root filesystem is refused" \
	"touch $(dev_quote "$probe")"
dev_absent "the write probe left nothing behind" "$probe"
dev_refuses "writing to /usr is refused" 'touch /usr/brenn-write-probe'

# Root is addressed through the slot link, never by filesystem UUID: both slots
# ship byte-identical and their filesystems carry the same UUID, so a UUID here
# would name whichever slot the kernel happened to find first.
dev_capture 'findmnt -no SOURCE /'
mounted_root=$DEV_OUT
dev_eq "the mounted root is the partition the active-slot link resolves to" \
	"readlink -f ${EXPECT_SLOT_LINK_DIR}/active/system" "$mounted_root"

# Every token of the command line we shipped, present on the running system.
# Compared token by token rather than as a whole line because the firmware
# prepends parameters of its own — the assertion is that ours survived, not
# that the firmware added nothing.
dev_capture 'cat /proc/cmdline'
cmdline=$DEV_OUT
missing=()
for token in $EXPECT_CMDLINE; do
	case " ${cmdline} " in
		*" ${token} "*) ;;
		*) missing+=("$token") ;;
	esac
done
if [ ${#missing[@]} -eq 0 ]; then
	t_pass "every parameter of the shipped command line is in effect"
else
	t_fail "every parameter of the shipped command line is in effect" \
		"missing: ${missing[*]}" \
		"observed: ${cmdline}"
fi

# Nothing resizes. The layout is fixed at build time and the root is read-only,
# so a resize helper on the command line would be a leftover from the vendor
# image's assumptions rather than something that could work.
case " ${cmdline} " in
	*resize*) t_fail "nothing on the command line resizes anything" "observed: ${cmdline}" ;;
	*) t_pass "nothing on the command line resizes anything" ;;
esac

t_done
