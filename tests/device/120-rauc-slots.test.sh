#!/usr/bin/env bash
#
# The update mechanism knows which slot it is running from.
#
# This is the one assertion that has to hold before an update is ever attempted,
# and the reason it is written now rather than with the rest of the update
# tests: RAUC decides which pair to write by deciding which pair is running, and
# if it gets that backwards the first install lands on the system performing it.
# There is no recovering from that over the network — it is the way to spend a
# reflash.
#
# Both slots ship byte-identical, with identical filesystem UUIDs, so the usual
# answers are unavailable: nothing may be addressed by filesystem UUID, and the
# kernel command line is one template shared by both slots. What is left is the
# command line's slot link, which resolves to whichever partition the firmware
# actually handed over, and the firmware's own report of that partition in the
# device tree. This test asserts that RAUC's answer, the backend's answer and
# the firmware's report are all the same one.
#
# It is numbered after the flash-budget measurement deliberately: reaching RAUC
# activates its service, which writes its status file to the persistent
# partition — a deliberate write class, and not one to have running inside a
# window that is measuring writes.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# One reading, parsed here. The shell form is stable output meant for exactly
# this, and taking it once keeps every assertion below about the same instant.
#
# The suite's idiom for a captured exit status is a local called `status`;
# this variable cannot use that name without shadowing it.
dev_capture 'rauc status --output-format=shell'
report=$DEV_OUT
if ! printf '%s\n' "$report" | grep -q '^RAUC_SYSTEM_COMPATIBLE='; then
	t_fail "the update mechanism answers" \
		"rauc status did not report a system" \
		"output: ${report:-<nothing>}"
	t_done
fi
t_pass "the update mechanism answers"

rauc_value() {
	dev_rauc_value "$report" "$1"
}

t_eq "the device accepts bundles built for this product" \
	"$(rauc_value RAUC_SYSTEM_COMPATIBLE)" "$EXPECT_RAUC_COMPATIBLE"

# This device depends on the running slot resolving through the command-line
# token it shipped, stated as an assertion rather than merely reading the
# reported value.
#
# RAUC canonicalises that token before matching it to a slot and reports what it
# resolved, so the expectation is resolved on the device too. The assertion still
# says the running slot came from the command line we shipped, and it says it on
# either slot — which a partition path written down here could not.
#
# Both sides have to be read before they can be compared, because they fail
# empty for one and the same cause: a by-slot link that is missing or dangling
# resolves to nothing here and leaves RAUC unable to name the slot it booted, so
# comparing the two readings as they come would report the assertion this file
# exists for as passing in exactly the case where slot resolution is broken.
root_token=$(printf '%s\n' "$EXPECT_CMDLINE" | tr ' ' '\n' | sed -n 's/^root=//p')
status=0
dev_capture "readlink -f $(dev_quote "$root_token")" || status=$?
resolved_token=$DEV_OUT
reported_bootname=$(rauc_value RAUC_SYSTEM_BOOTED_BOOTNAME)
if [ "$status" -ne 0 ] || [ -z "$resolved_token" ] || [ -z "$reported_bootname" ]; then
	t_fail "the running slot was resolved through the command line we shipped" \
		"${root_token} resolves to: ${resolved_token:-<nothing>} (status ${status})" \
		"rauc reports booted bootname: ${reported_bootname:-<nothing>}"
else
	t_eq "the running slot was resolved through the command line we shipped" \
		"$reported_bootname" "$resolved_token"
fi

# Exactly one slot is the booted one. Two would mean the resolution matched
# both bit-identical slots; none means it matched neither, and RAUC would refuse
# to install at all.
booted_indices=$(dev_rauc_slot_indices "$report" STATE booted)
booted_count=$(printf '%s' "$booted_indices" | grep -c . || true)
t_eq "exactly one slot is running" "$booted_count" 1
if [ "$booted_count" != "1" ]; then
	t_done
fi

booted_bootname=$(rauc_value "RAUC_SLOT_BOOTNAME_${booted_indices}")

# The backend's answer, from the firmware's device-tree report. Agreement with
# RAUC's own resolution confirms both independent paths identify the same slot.
dev_eq "the backend and RAUC agree on which slot is running" \
	"$(dev_quote "$EXPECT_RAUC_BACKEND") get-current" "$booted_bootname"

# And the partition itself. The slot RAUC believes it is running is configured
# on some partition; the firmware said which partition it booted. Resolved
# through the GPT labels the configuration names, they have to be the same one.
slot_field() {
	printf '%s\n' "$EXPECT_RAUC_SLOTS" | awk -F'|' -v s="$1" -v k="$2" '
		$1 == s {
			n = split($2, kv, ",")
			for (i = 1; i <= n; i++) {
				split(kv[i], p, "=")
				if (p[1] == k) print p[2]
			}
		}'
}
slot_named_by() {
	printf '%s\n' "$EXPECT_RAUC_SLOTS" | awk -F'|' -v k="$1" -v v="$2" '
		{
			n = split($2, kv, ",")
			for (i = 1; i <= n; i++) {
				split(kv[i], p, "=")
				if (p[1] == k && p[2] == v) { print $1; exit }
			}
		}'
}

booted_slot=$(slot_named_by bootname "$booted_bootname")
booted_boot_slot=$(slot_named_by parent "${booted_slot#slot.}")
booted_boot_device=$(slot_field "$booted_boot_slot" device)

firmware_partition=""
dev_firmware_partition && firmware_partition=$DEV_PARTITION
dev_capture "readlink -f $(dev_quote "$booted_boot_device")"
configured_device=$DEV_OUT
configured_partition=$(dev_partition_number "$configured_device")

if [ -n "$firmware_partition" ] && [ "${configured_partition:-x}" = "$firmware_partition" ]; then
	t_pass "the running slot is configured on the partition the firmware booted (${configured_device})"
else
	t_fail "the running slot is configured on the partition the firmware booted" \
		"firmware booted partition: ${firmware_partition:-<nothing>}" \
		"${booted_boot_slot} resolves to: ${configured_device:-<nothing>}"
fi

# The committed pair is the pair running. Before any update this is simply true;
# after one it is what says the update was committed rather than left on trial.
# A device sitting in an uncommitted trial fails here, which is a thing worth
# being told before running anything else against it.
primary_slot=$(rauc_value RAUC_BOOT_PRIMARY)
primary_index=$(printf '%s\n' "$(rauc_value RAUC_SYSTEM_SLOTS)" |
	awk -v want="$primary_slot" '{ for (i = 1; i <= NF; i++) if ($i == want) { print i; exit } }')
t_eq "the committed pair is the pair that is running" \
	"$(rauc_value "RAUC_SLOT_BOOTNAME_${primary_index:-0}")" "$booted_bootname"
dev_eq "and the backend commits to the same one" \
	"$(dev_quote "$EXPECT_RAUC_BACKEND") get-primary" "$booted_bootname"

# Neither pair has been refused. A refusal is a marker on the persistent
# partition, and one that exists before any update ever ran means something
# marked a slot bad that nobody installed.
#
# The slots are counted before they are checked. This assertion is a loop over
# whatever the report called a rootfs slot, and a loop over nothing prints
# nothing and passes: a report that stopped spelling the class the way this
# expects would retire the marker assertion in silence, which is the one
# outcome a check for a bad-slot marker must not have.
mapfile -t rootfs_indices < <(dev_rauc_slot_indices "$report" CLASS rootfs)
if [ "${#rootfs_indices[@]}" -eq 0 ]; then
	t_fail "neither pair has been refused" \
		"the report names no rootfs slot, so no slot was checked" \
		"output: ${report:-<nothing>}"
else
	for index in "${rootfs_indices[@]}"; do
		t_eq "slot $(rauc_value "RAUC_SLOT_BOOTNAME_${index}") has not been refused" \
			"$(rauc_value "RAUC_SLOT_BOOT_STATUS_${index}")" \
			"$EXPECT_RAUC_SLOT_STATUS_GOOD"
	done
fi

# The deadman is loaded and waiting. It is what ends a trial boot that came up
# and never became healthy, and a timer that is not running is a candidate that
# can sit there unreachable forever.
dev_eq "the trial deadman timer is waiting" \
	"systemctl is-active $(dev_quote "$EXPECT_DEADMAN_TIMER")" active

t_done
