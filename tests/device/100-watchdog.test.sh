#!/usr/bin/env bash
#
# The hardware watchdog is armed.
#
# This is the assertion the whole rollback story rests on. The firmware's
# one-shot trial flag returns the device to the system that was working after a
# *reset*; a candidate that hangs instead of panicking produces no reset, so
# without a watchdog counting down there is nothing to return from. The same
# applies outside an update: a wedged appliance nobody can reach is a wedged
# appliance until somebody walks over to it.
#
# "Configured" and "armed" are different claims, and only the second one is
# worth anything. The image suite reads the setting out of the configuration
# file; this reads the device the kernel exposes, the timeout it was programmed
# with, and the process holding it open — none of which a configuration file
# can promise.
#
# Nothing here triggers the watchdog. A test that proves it by letting the
# device reset is a test that costs a boot, and the timeout being programmed is
# what was in question.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# What systemd resolved, which is the merge of the packaged defaults and our
# drop-in. Timespans are reported the way they were written.
dev_eq "systemd runs the watchdog at the configured interval" \
	'systemctl show -p RuntimeWatchdogUSec --value' "$EXPECT_WATCHDOG_RUNTIME"

# The second timeout: once a reboot has been asked for, this is how long the
# shutdown gets before the watchdog stops being petted and the board resets
# anyway. A hang during shutdown is the failure mode it covers, and a trial boot
# that hangs on its way out is exactly that.
dev_eq "and keeps counting through a shutdown" \
	'systemctl show -p RebootWatchdogUSec --value' "$EXPECT_WATCHDOG_REBOOT"

# The hardware, as the kernel found it. The identity is the driver's own name
# for the peripheral: a device that came up under some other driver is a
# different watchdog with different behaviour, and is worth knowing about
# before it is relied on.
dev_exists "the watchdog device exists" "$EXPECT_WATCHDOG_DEVICE"
dev_eq "the watchdog is the one on this SoC" \
	"cat $(dev_quote "${EXPECT_WATCHDOG_SYSFS}/identity")" \
	"$EXPECT_WATCHDOG_IDENTITY"

# Programmed, and running. The timeout is what systemd asked the hardware for,
# in seconds; the state is the kernel's own answer to whether the counter is
# ticking.
dev_eq "the hardware timeout is the interval systemd asked for" \
	"cat $(dev_quote "${EXPECT_WATCHDOG_SYSFS}/timeout")" \
	"$EXPECT_WATCHDOG_TIMEOUT"
dev_eq "the watchdog is running" \
	"cat $(dev_quote "${EXPECT_WATCHDOG_SYSFS}/state")" \
	"$EXPECT_WATCHDOG_STATE"

# And systemd is the one holding it. An open descriptor on pid 1 is what says
# the countdown is being reset by the thing whose liveness it measures; a
# watchdog opened by nothing would simply have reset the board already, and one
# opened by some other process would be measuring that process instead.
dev_capture "readlink /proc/1/fd/* 2>/dev/null | grep -c -x $(dev_quote "$EXPECT_WATCHDOG_DEVICE") || true"
if [ "${DEV_OUT:-0}" -ge 1 ] 2>/dev/null; then
	t_pass "process 1 holds the watchdog open"
else
	t_fail "process 1 holds the watchdog open" \
		"descriptors on ${EXPECT_WATCHDOG_DEVICE}: ${DEV_OUT:-<nothing>}"
fi

t_done
