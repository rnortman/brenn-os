#!/usr/bin/env bash
#
# The carrier's hardware, as the running kernel found it.
#
# The image suite asserts that the boot configuration asks for this hardware.
# Only a device can say whether asking worked: an overlay that names a
# peripheral this board does not have, or names it at the wrong address, fails
# silently at boot and leaves a device that looks healthy and cannot move, see
# or cool itself.
#
# Every assertion here is written before the first boot and is expected to fail
# until hardware confirms it. The failure is the measurement: an unexpected
# reading is reviewed before anything here is changed to accept it (CLAUDE.md).

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# The servo bus. Two readings, because they fail differently: the device-tree
# node says the overlay was applied, and the bound platform device says the
# kernel has a driver on it. An enabled node with no driver is a bus that
# nothing can send a byte down.
dev_eq "the servo UART is enabled in the device tree" \
	"tr -d '\\000' < $(dev_quote "${EXPECT_UART3_DT_NODE}/status")" okay

# The port a tty resolves to is a subdevice of the platform device — serial-core
# names it `<platform device>:<controller>.<port>` — so the suffix is dropped and
# what is left is the device the driver bound to.
# shellcheck disable=SC2016  # these expansions are for the device's shell
dev_capture 'for t in /sys/class/tty/*/device; do [ -e "$t" ] && basename "$(readlink -f "$t")"; done | sed "s/:.*//" | sort -u'
t_contains "a serial port is bound to the servo UART" \
	"$DEV_OUT" "$EXPECT_UART3_PLATFORM_DEVICE"

# The fan. A bound driver alone is not the assertion — the reading is, because
# a controller that probed and reports nothing cools nothing.
dev_capture 'grep -h . /sys/class/hwmon/hwmon*/name 2>/dev/null | sort -u'
t_contains "the fan controller is bound and reporting" \
	"$DEV_OUT" "$EXPECT_FAN_HWMON_NAME"

# shellcheck disable=SC2016  # these expansions are for the device's shell
dev_capture "$(printf 'for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = %s ] && cat "$h/%s"; done' \
	"$EXPECT_FAN_HWMON_NAME" "$EXPECT_FAN_INPUT")"
case "$DEV_OUT" in
	'' | *[!0-9]*)
		t_fail "the fan controller reports a speed" \
			"expected a number from ${EXPECT_FAN_INPUT}" \
			"read: ${DEV_OUT:-<nothing>}"
		;;
	*) t_pass "the fan controller reports a speed (${DEV_OUT} rpm)" ;;
esac

# The camera, counted through the driver. The count is the assertion in both
# directions: none means the sensor did not bind, and more than one means a
# second sensor is attached and declared, which no revision of this hardware has.
#
# It says nothing about a connector declared with nothing on it: that probe fails
# and never binds, so it does not reach this count. A re-declared empty connector
# must be caught by name in the boot configuration.
dev_capture "ls /sys/bus/i2c/drivers/$(dev_quote "$EXPECT_CAMERA_DRIVER")/ 2>/dev/null | grep -c -E '^[0-9]+-[0-9a-f]+$'"
t_eq "the head camera is bound to the sensor driver" "$DEV_OUT" "$EXPECT_CAMERA_COUNT"

# The IMU's bus. The adapter number depends on probe order, so the assertion is
# about the platform device behind it, which is the address the overlay names.
# Enumerated from the bus rather than from /sys/class/i2c-adapter, which this
# kernel does not create; the adapter's parent is the platform device.
# shellcheck disable=SC2016  # these expansions are for the device's shell
dev_capture 'for a in /sys/bus/i2c/devices/i2c-*; do [ -e "$a" ] && basename "$(dirname "$(readlink -f "$a")")"; done | sort -u'
t_contains "the IMU bus has an adapter" "$DEV_OUT" "$EXPECT_IMU_PLATFORM_DEVICE"

# The USB audio board: enumerated, and reachable by the group the profile grants
# rather than by everyone. Read from the device node itself — the rule file is in
# the image and asserted there; what a device says is whether udev applied it.
#
# The two ids in the expectation are one board. It enumerates under the vendor's
# own id once its firmware has been updated and under the id of the module it is
# built on before that, and the factory software tries them in that order,
# warning that the firmware is old when it finds the second. So exactly one of
# them is expected: none means the board is not there, and both at once would
# mean a second board, which no revision of this hardware has.
readings=""
unreadable=""
while IFS= read -r id; do
	[ -n "$id" ] || continue
	vendor=${id%%:*}
	product=${id##*:}
	# shellcheck disable=SC2016  # these expansions are for the device's shell
	# The trailing `:` is what makes the reading the assertion: the loop's own
	# status is that of the last device it looked at, which is whichever one
	# happens to be plugged in last and says nothing about the one being
	# searched for. What the status is left to report is the device having failed
	# to answer at all, which is not the same finding as an absent board.
	probe=$(printf 'for v in /sys/bus/usb/devices/*/idVendor; do d=${v%%/idVendor}; [ "$(cat "$v")" = %s ] && [ "$(cat "$d/idProduct")" = %s ] && stat -c "%%a %%G" "/dev/bus/usb/$(printf %%03d "$(cat "$d/busnum")")/$(printf %%03d "$(cat "$d/devnum")")"; done; :' \
		"$vendor" "$product")
	status=0
	dev_capture "$probe" || status=$?
	if [ "$status" -ne 0 ]; then
		unreadable="${unreadable}${id} (status ${status}): ${DEV_OUT:-<nothing>} "
		continue
	fi
	# Only a line shaped like the reading counts as one. The remote stderr is
	# folded into the output on purpose, so a diagnostic from the probe — an
	# unmatched glob, a node that went away between two reads — arrives on the
	# same channel as an answer, and counted as an answer it is a board that is
	# not there reported as a board that is.
	while IFS= read -r node; do
		[ -n "$node" ] || continue
		case "$node" in
			[0-7][0-7][0-7]' '?* | [0-7][0-7][0-7][0-7]' '?*)
				readings="${readings}${id} ${node}"$'\n'
				;;
			*) unreadable="${unreadable}${id} (not a reading): ${node} " ;;
		esac
	done <<<"$DEV_OUT"
done <<<"$EXPECT_USB_AUDIO_IDS"

count=$(printf '%s' "$readings" | grep -c . || true)

if [ -n "$unreadable" ]; then
	t_fail "exactly one of the audio board's two firmware generations is present" \
		"the device gave no usable answer about: ${unreadable}" \
		"read from the rest: ${readings:-<none>}"
	t_fail "and its USB device node is reachable by its group" \
		"not asserted: a probe did not run to completion"
elif [ "$count" -eq 1 ]; then
	reading=${readings%%$'\n'*}
	t_pass "exactly one of the audio board's two firmware generations is present (${reading%% *})"
	t_eq "and its USB device node is reachable by its group" \
		"${reading#* }" "${EXPECT_USB_AUDIO_MODE#0} ${EXPECT_USB_AUDIO_GROUP}"
else
	t_fail "exactly one of the audio board's two firmware generations is present" \
		"looked for: $(printf '%s' "$EXPECT_USB_AUDIO_IDS" | tr '\n' ' ')" \
		"found: ${readings:-<none>}"
	t_fail "and its USB device node is reachable by its group" \
		"no single device node to read"
fi

t_done
