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

# shellcheck disable=SC2016  # these expansions are for the device's shell
dev_capture 'for t in /sys/class/tty/*/device; do [ -e "$t" ] && basename "$(readlink -f "$t")"; done | sort -u'
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

# Both cameras, counted through the driver. The overlays declare two, and one
# camera answering twice as fast as expected is what a miscount looks like on
# hardware that has one.
dev_capture "ls /sys/bus/i2c/drivers/$(dev_quote "$EXPECT_CAMERA_DRIVER")/ 2>/dev/null | grep -c -E '^[0-9]+-[0-9a-f]+$'"
t_eq "both cameras are bound to the sensor driver" "$DEV_OUT" "$EXPECT_CAMERA_COUNT"

# The IMU's bus. The adapter number depends on probe order, so the assertion is
# about the platform device behind it, which is the address the overlay names.
# shellcheck disable=SC2016  # these expansions are for the device's shell
dev_capture 'for a in /sys/class/i2c-adapter/i2c-*; do [ -e "$a/device" ] && basename "$(readlink -f "$a/device")"; done | sort -u'
t_contains "the IMU bus has an adapter" "$DEV_OUT" "$EXPECT_IMU_PLATFORM_DEVICE"

# The two USB audio devices: enumerated, and reachable by the group the profile
# grants rather than by everyone. Read from the device node itself — the rule
# file is in the image and asserted there; what a device says is whether udev
# applied it.
while IFS= read -r id; do
	[ -n "$id" ] || continue
	vendor=${id%%:*}
	product=${id##*:}
	# shellcheck disable=SC2016  # these expansions are for the device's shell
	# The trailing `:` is what makes the reading the assertion: the loop's own
	# status is that of the last device it looked at, which is whichever one
	# happens to be plugged in last and says nothing about the one being
	# searched for.
	probe=$(printf 'for v in /sys/bus/usb/devices/*/idVendor; do d=${v%%/idVendor}; [ "$(cat "$v")" = %s ] && [ "$(cat "$d/idProduct")" = %s ] && stat -c "%%a %%G" "/dev/bus/usb/$(printf %%03d "$(cat "$d/busnum")")/$(printf %%03d "$(cat "$d/devnum")")"; done; :' \
		"$vendor" "$product")
	dev_eq "USB device ${id} is present and reachable by its group" \
		"$probe" "${EXPECT_USB_AUDIO_MODE#0} ${EXPECT_USB_AUDIO_GROUP}"
done <<<"$EXPECT_USB_AUDIO_IDS"

t_done
