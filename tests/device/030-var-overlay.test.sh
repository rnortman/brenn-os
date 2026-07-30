#!/usr/bin/env bash
#
# /var is an overlay: the filesystem baked into the image underneath, RAM on
# top.
#
# This is the one deviation from the A/B layout's defaults that the image
# cannot verify for itself. The layout binds a per-slot /var onto the flash;
# we replace it with an overlay so that everything a running Debian writes to
# /var — logs, spools, the state every unit keeps — lands in RAM and is gone at
# shutdown, while the dpkg database and the /var/lib skeleton stay readable
# from the image.
#
# Whether the kernel will mount that overlay, and whether the system underneath
# it is intact, is a hardware question. It is the first thing to look at if a
# first boot is broken in a way nothing else explains.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

dev_eq "/var is an overlay" 'findmnt -no FSTYPE /var' "$EXPECT_VAR_FSTYPE"
dev_eq "the RAM half of the overlay is a tmpfs" \
	"findmnt -no FSTYPE $(dev_quote "$EXPECT_VAR_UPPER_MOUNT")" \
	"$EXPECT_VAR_UPPER_FSTYPE"

# The three directories the overlay is made of, as the kernel reports them
# rather than as the unit file asks for them.
dev_capture 'findmnt -no OPTIONS /var'
options=$DEV_OUT
for pair in \
	"lowerdir=${EXPECT_VAR_LOWERDIR}" \
	"upperdir=${EXPECT_VAR_UPPERDIR}" \
	"workdir=${EXPECT_VAR_WORKDIR}"; do
	case ",${options}," in
		*",${pair},"*) t_pass "the overlay uses ${pair}" ;;
		*) t_fail "the overlay uses ${pair}" "options: ${options}" ;;
	esac
done

# The reason the overlay exists rather than a plain tmpfs: the system that was
# built into the image is still there underneath. A package database that is
# unreadable at run time is a device that cannot be inspected, and every unit
# expecting a directory under /var/lib finds an empty tree.
dev_succeeds "the dpkg database is readable through the overlay" \
	'test -s /var/lib/dpkg/status'
dev_capture 'dpkg-query -W -f "x" 2>/dev/null | wc -c'
packages=${DEV_OUT//[^0-9]/}
if [ -n "$packages" ] && [ "$packages" -gt 100 ]; then
	t_pass "dpkg reports an installed package set (${packages} packages)"
else
	t_fail "dpkg reports an installed package set" "reported: ${DEV_OUT:-<nothing>}"
fi

# Writes land on the RAM half. Asserted by making one and finding it there,
# because a lowerdir that is somehow writable would satisfy every assertion
# above.
probe="brenn-var-probe-$$"
dev_succeeds "a write to /var succeeds" "touch /var/tmp/${probe}"
dev_exists "the write landed on the RAM half" "${EXPECT_VAR_UPPERDIR}/tmp/${probe}"
dev_run "rm -f /var/tmp/${probe}" >/dev/null 2>&1

# Nothing else is mounted under /var. The two entries the layout's own fstab
# would have added — the journal and a per-slot bind onto the flash — are held
# back in the image, and their absence here is what proves that took.
dev_eq_text "/var carries no further mounts" \
	'findmnt -rno TARGET --submounts /var' /var

# The application account's home is on the volatile half by design: it exists
# so that nothing a service does by habit reaches the flash.
dev_exists "the application account's home exists" "$EXPECT_APP_HOME"

t_done
