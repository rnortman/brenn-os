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

# Raw output throughout: without `-r`, findmnt pads some columns to their width
# even under `-n`, and a padded field compared against an exact expectation
# fails on trailing spaces that nothing on screen shows. Which columns pad is a
# util-linux internal, so no reading here rests on it.
dev_eq "the root filesystem is ext4" 'findmnt -rno FSTYPE /' ext4
dev_eq "the root filesystem is mounted read-only" \
	'findmnt -rno OPTIONS / | cut -d, -f1' ro
dev_eq "the firmware partition is mounted read-only" \
	'findmnt -rno OPTIONS /boot/firmware | cut -d, -f1' ro

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
#
# Compared as device numbers, because the name is not evidence. What the kernel
# records as the source of / is the path the initramfs handed it, which is the
# slot link itself — so resolving that string and comparing it to what the link
# resolves to is the link compared with itself, and passes whichever partition is
# really mounted. The major:minor behind / comes from the mount, cannot be
# derived from the link, and disagrees the moment the two do.
status=0
dev_capture 'findmnt -rno MAJ:MIN /' || status=$?
mounted_devno=$DEV_OUT
if [ "$status" -ne 0 ] || [ -z "$mounted_devno" ]; then
	t_fail "the mounted root is the partition the active-slot link resolves to" \
		"the device number behind / could not be read (status ${status})" \
		"findmnt said: ${mounted_devno:-<nothing>}"
else
	dev_eq "the mounted root is the partition the active-slot link resolves to" \
		"mountpoint -x \"\$(readlink -f $(dev_quote "${EXPECT_SLOT_LINK_DIR}/active/system"))\"" \
		"$mounted_devno"
fi

# Every token of the command line we shipped, present on the running system.
# Compared token by token rather than as a whole line because the firmware
# prepends parameters of its own — the assertion is that ours survived, not
# that the firmware added nothing.
#
# Against the runtime form of the expectation, because one token does not survive
# verbatim: the firmware resolves the `console=serial0` alias to the UART the
# board actually offers. The image suite is what holds the file we shipped to its
# own value.
dev_capture 'cat /proc/cmdline'
cmdline=$DEV_OUT

# The expectation is derived, which gives it two ways of naming no tokens at all,
# and a loop over no tokens prints a pass. Both are the derivation having gone
# stale rather than the device being wrong, and both are said as failures here
# because a device suite whose command-line assertion cannot fail is worse than
# one that does not make it.
cmdline_desc="every parameter of the shipped command line is in effect"
if [ -z "$EXPECT_CMDLINE_RUNTIME" ]; then
	t_fail "$cmdline_desc" \
		"the runtime expectation is empty, so nothing would have been compared" \
		"observed: ${cmdline}"
elif [ "$EXPECT_CMDLINE_RUNTIME" = "$EXPECT_CMDLINE" ]; then
	t_fail "$cmdline_desc" \
		"the console alias this form rewrites is no longer in the shipped line," \
		"so the token the firmware resolves is not being asserted" \
		"shipped: ${EXPECT_CMDLINE}"
else
	missing=()
	for token in $EXPECT_CMDLINE_RUNTIME; do
		case " ${cmdline} " in
			*" ${token} "*) ;;
			*) missing+=("$token") ;;
		esac
	done
	if [ ${#missing[@]} -eq 0 ]; then
		t_pass "$cmdline_desc"
	else
		t_fail "$cmdline_desc" \
			"missing: ${missing[*]}" \
			"observed: ${cmdline}"
	fi
fi

# Nothing resizes. The layout is fixed at build time and the root is read-only,
# so a resize helper on the command line would be a leftover from the vendor
# image's assumptions rather than something that could work.
case " ${cmdline} " in
	*resize*) t_fail "nothing on the command line resizes anything" "observed: ${cmdline}" ;;
	*) t_pass "nothing on the command line resizes anything" ;;
esac

t_done
