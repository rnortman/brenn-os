#!/usr/bin/env bash
#
# The device lane's own plumbing.
#
# The device suite cannot run without a device, so the part of it that is
# ordinary logic — where the target comes from, what precedence the two sources
# have, what actually gets handed to ssh — is exercised here instead, against a
# stub that records its arguments. What is asserted is everything that would
# otherwise only be discovered at the bench: a lane pointed at the wrong host,
# a lane that quietly passes when nothing is configured, an option string that
# arrives as one argument instead of several.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

argv_log="${work}/argv"
stub="${work}/ssh-stub"
cat >"$stub" <<'STUB'
#!/bin/sh
: >"$SSH_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$SSH_ARGV_LOG"; done
if [ "${SSH_STUB_UNREACHABLE:-0}" = 1 ]; then
	echo "ssh: connect to host port 22: No route to host" >&2
	exit 255
fi
echo "${SSH_STUB_OUT:-remote-ok}"
exit "${SSH_STUB_STATUS:-0}"
STUB
chmod 0755 "$stub"

# The lane, driven by a script rather than in-process, because the thing under
# test decides whether to skip — and skipping is an exit, which would take this
# test with it.
driver="${work}/driver"
cat >"$driver" <<'DRIVER'
set -uo pipefail
# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

case "${DRIVE:-run}" in
	run)
		dev_load_target
		dev_run 'true; echo marker'
		;;
	open)
		dev_open
		echo "opened"
		;;
	expectations)
		dev_load_expectations
		printf '%s %s\n' "$EXPECT_ARCH" "$EXPECT_ADMIN_USER"
		;;
	wait)
		dev_load_target
		DEV_POLL_INTERVAL=1
		dev_wait "settled" 'echo probe' "${WAIT_EXPECT}" "${WAIT_SECONDS}"
		;;
	partition)
		for node in /dev/mmcblk0p2 /dev/mmcblk0p12 /dev/loop; do
			printf '%s %s\n' "$node" "$(dev_partition_number "$node")"
		done
		;;
	assert)
		dev_load_target
		dev_eq "eq" 'probe' "${STUB_TEXT:-remote-ok}"
		dev_eq_text "eq_text" 'probe' "${STUB_TEXT:-remote-ok}"
		dev_succeeds "succeeds" 'probe'
		dev_refuses "refuses" 'probe'
		dev_exists "exists" /a/path
		dev_absent "absent" /a/path
		;;
	quote)
		dev_load_target
		dev_run "cat $(dev_quote "$QUOTE_VALUE")" >/dev/null
		;;
	firmware)
		dev_load_expectations
		dev_load_target
		if dev_firmware_partition; then
			echo "read ${DEV_PARTITION}"
		else
			echo "unreadable ${DEV_PARTITION:-<nothing>}"
		fi
		;;
esac
DRIVER

# Every run points the lane at a conf path of its own, and every knob the lane
# reads from the environment is cleared before each run: a developer with a real
# device configured must not be able to change what this test does. The list is
# every BRENN_DEVICE_* name dev_load_target looks at and this function does not
# set itself, and it has to grow when that function learns another one.
conf="${work}/device.conf"
: >"$conf"

drive() {
	env -u BRENN_DEVICE_HOST -u BRENN_DEVICE_USER -u BRENN_DEVICE_SSH_OPTS \
		-u BRENN_DEVICE_SSH_MULTIPLEX -u BRENN_DEVICE_CONNECT_TIMEOUT \
		BRENN_REPO_ROOT="$BRENN_REPO_ROOT" \
		BRENN_TESTS_LIB="$BRENN_TESTS_LIB" \
		BRENN_PROFILE="$BRENN_PROFILE" \
		BRENN_DEVICE_CONF="$conf" \
		BRENN_DEVICE_SSH="$stub" \
		SSH_ARGV_LOG="$argv_log" \
		"$@" bash "$driver" 2>&1
}

argv() {
	cat "$argv_log" 2>/dev/null
}

# Nothing configured: the lane skips, and says how to configure it. A device
# suite that reported success here would be reporting on a device that does not
# exist.
out=$(drive DRIVE=run)
status=$?
t_eq "an unconfigured lane skips" "$status" 77
case "$out" in
	*BRENN_DEVICE_HOST*) t_pass "the skip names the variable to set" ;;
	*) t_fail "the skip names the variable to set" "output: ${out}" ;;
esac

# Configured from the environment.
out=$(drive DRIVE=run BRENN_DEVICE_HOST=unit.invalid)
t_eq "a configured lane runs the command" "$out" "remote-ok"
t_contains "the target is the configured host, as root by default" \
	"$(argv)" "root@unit.invalid"
t_contains "the command reaches ssh verbatim" "$(argv)" "true; echo marker"
t_contains "the connection is non-interactive" "$(argv)" "BatchMode=yes"
if argv | grep -q '^ConnectTimeout='; then
	t_pass "the connection has a timeout"
else
	t_fail "the connection has a timeout" "argv: $(argv | tr '\n' ' ')"
fi

# Configured from the local overlay, which is where a workstation keeps it.
cat >"$conf" <<'CONF'
BRENN_DEVICE_HOST=from-conf.invalid
BRENN_DEVICE_USER=admin
CONF
drive DRIVE=run >/dev/null
t_contains "the local overlay supplies the target" "$(argv)" "admin@from-conf.invalid"

# An exported value is the more specific statement and wins, so that a one-off
# run against a second unit needs no edit to the overlay.
drive DRIVE=run BRENN_DEVICE_HOST=override.invalid BRENN_DEVICE_USER=someone >/dev/null
t_contains "the environment overrides the overlay" "$(argv)" "someone@override.invalid"
: >"$conf"

# ssh options arrive as separate arguments; a whole option string handed over
# as one would be rejected by ssh, at the bench, with a confusing message.
drive DRIVE=run BRENN_DEVICE_HOST=unit.invalid \
	BRENN_DEVICE_SSH_OPTS='-p 2222 -i /dev/null' >/dev/null
t_contains "an option string is split into arguments" "$(argv)" "-p"
t_contains "an option string keeps its values" "$(argv)" "2222"

# One connection, shared by the whole run. Each assertion in the device suite is
# its own ssh command, so on a radio the handshakes cost more than the
# assertions do; and because one of those assertions drops the association on
# purpose, the shared connection has to be one that notices it died.
drive DRIVE=run BRENN_DEVICE_HOST=unit.invalid >/dev/null
if argv | grep -q '^ControlPath='; then
	t_pass "assertions share one connection"
else
	t_fail "assertions share one connection" "argv: $(argv | tr '\n' ' ')"
fi
if argv | grep -q '^ServerAliveInterval='; then
	t_pass "the shared connection is retired when the device stops answering"
else
	t_fail "the shared connection is retired when the device stops answering" \
		"argv: $(argv | tr '\n' ' ')"
fi

drive DRIVE=run BRENN_DEVICE_HOST=unit.invalid BRENN_DEVICE_SSH_MULTIPLEX=0 >/dev/null
if argv | grep -q '^ControlPath='; then
	t_fail "sharing can be switched off" "argv: $(argv | tr '\n' ' ')"
else
	t_pass "sharing can be switched off"
fi

# A partition number is a number. The device lane compares the partition the
# firmware booted against the one the slot links and the update mechanism name,
# and a suffix comparison would call partition 12 a match for partition 2 — an
# agreement that does not hold, in the one place the whole flash budget rests on
# it holding.
out=$(drive DRIVE=partition BRENN_DEVICE_HOST=unit.invalid)
t_contains "a partition number is read from a device node" "$out" "/dev/mmcblk0p2 2"
t_contains "and it is the whole number, not the last digit" "$out" "/dev/mmcblk0p12 12"
t_contains "a node with no partition number yields none" "$out" "/dev/loop "

# The remote status is the lane's status: an assertion about what a command
# does on the device has to be able to see it fail.
out=$(drive DRIVE=run BRENN_DEVICE_HOST=unit.invalid SSH_STUB_STATUS=3)
t_eq "the remote exit status is reported" "$?" 3

# The assertion helpers, in both polarities. Every device test is built out of
# these — the read-only root, the masked mount points and the refusals that go
# with them are thirty assertions resting on dev_refuses alone — and one of them
# inverted or defanged would leave the whole suite passing against a device that
# does not hold. Nothing at the bench would find that either, because the
# failure mode is a pass.
out=$(drive DRIVE=assert BRENN_DEVICE_HOST=unit.invalid)
t_contains "a matching value passes" "$out" "PASS  eq"
t_contains "and so does the multi-line form" "$out" "PASS  eq_text"
t_contains "a command that exits zero is a success" "$out" "PASS  succeeds"
t_contains "and is not a refusal" "$out" "FAIL  refuses"
t_contains "a path the device has is present" "$out" "PASS  exists"
t_contains "and is not absent" "$out" "FAIL  absent"

out=$(drive DRIVE=assert BRENN_DEVICE_HOST=unit.invalid STUB_TEXT=something-else)
t_contains "a value that differs fails" "$out" "FAIL  eq"
t_contains "and so does the multi-line form" "$out" "FAIL  eq_text"

# A command that could not run at all is a different finding from a command
# that answered wrong, and the status is what distinguishes them: "the file was
# empty" and "the tool is not installed" must not read the same.
out=$(drive DRIVE=assert BRENN_DEVICE_HOST=unit.invalid SSH_STUB_STATUS=3)
t_contains "a command that failed is not a value" "$out" "FAIL  eq"
case "$out" in
	*"command failed (status 3)"*) t_pass "and the failure reports the status" ;;
	*) t_fail "and the failure reports the status" "output: ${out}" ;;
esac
t_contains "a command that exits nonzero is not a success" "$out" "FAIL  succeeds"
t_contains "and is a refusal" "$out" "PASS  refuses"
t_contains "a path the device lacks is not present" "$out" "FAIL  exists"
t_contains "and is absent" "$out" "PASS  absent"

# Quoting. Nearly every remote command in the suite is assembled around a value
# that goes through this, and one with whitespace in it arriving as two
# arguments is a command that asks the device something else.
drive DRIVE=quote BRENN_DEVICE_HOST=unit.invalid QUOTE_VALUE="it's a file" >/dev/null
t_contains "a value with a space and a quote in it reaches the device whole" \
	"$(argv)" "cat 'it'\\''s a file'"

# Which partition the firmware booted. It is a device-tree property read as
# bytes, and an error message has digits in it too — so the reading is only a
# reading when the status that came with it was zero. The slot identity the
# update mechanism is checked against rests on this one.
out=$(drive DRIVE=firmware BRENN_DEVICE_HOST=unit.invalid SSH_STUB_OUT="        2")
t_eq "the booted partition is the number the firmware reported" "$out" "read 2"
out=$(drive DRIVE=firmware BRENN_DEVICE_HOST=unit.invalid SSH_STUB_STATUS=1 \
	SSH_STUB_OUT="od: cannot open the property: error 2")
t_eq "digits in a failure are not a partition number" "$out" "unreadable 2"

# A device that is configured and cannot be reached skips the suite rather than
# failing every assertion in it. 010 is what fails in that case, and it is the
# only test that opens the lane itself.
out=$(drive DRIVE=open BRENN_DEVICE_HOST=unit.invalid SSH_STUB_UNREACHABLE=1)
t_eq "an unreachable device skips" "$?" 77
case "$out" in
	*"cannot reach"*unit.invalid*) t_pass "the skip names the host it could not reach" ;;
	*) t_fail "the skip names the host it could not reach" "output: ${out}" ;;
esac

out=$(drive DRIVE=open BRENN_DEVICE_HOST=unit.invalid)
t_eq "a reachable device opens the lane" "$out" "opened"

# Waiting for a device to settle. The assertions about recovery run while the
# device is on its way back, so a command that fails or answers wrong is a
# retry — and the window has to actually end, or a device that never recovers
# hangs the lane instead of failing it.
out=$(drive DRIVE=wait BRENN_DEVICE_HOST=unit.invalid WAIT_EXPECT=remote-ok WAIT_SECONDS=5)
case "$out" in
	PASS*) t_pass "a value that is already right passes without waiting" ;;
	*) t_fail "a value that is already right passes without waiting" "output: ${out}" ;;
esac

started=$SECONDS
out=$(drive DRIVE=wait BRENN_DEVICE_HOST=unit.invalid WAIT_EXPECT=never WAIT_SECONDS=2)
elapsed=$((SECONDS - started))
case "$out" in
	FAIL*) t_pass "a value that never arrives fails" ;;
	*) t_fail "a value that never arrives fails" "output: ${out}" ;;
esac
case "$out" in
	*"last: "*remote-ok*) t_pass "the failure reports what the device last said" ;;
	*) t_fail "the failure reports what the device last said" "output: ${out}" ;;
esac
if [ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 15 ]; then
	t_pass "the wait ends when its window does (${elapsed}s)"
else
	t_fail "the wait ends when its window does" "elapsed: ${elapsed}s, window: 2s"
fi

# A device that cannot be reached at all is retried rather than treated as an
# answer: on a unit reached over the radio, the transport is part of what is
# recovering.
out=$(drive DRIVE=wait BRENN_DEVICE_HOST=unit.invalid WAIT_EXPECT=remote-ok WAIT_SECONDS=2 \
	SSH_STUB_UNREACHABLE=1)
case "$out" in
	FAIL*) t_pass "an unreachable device is waited on, not skipped" ;;
	*) t_fail "an unreachable device is waited on, not skipped" "output: ${out}" ;;
esac

# Both halves of the profile's expectations are loaded, and the image half is
# the same file the image suite reads.
out=$(drive DRIVE=expectations BRENN_DEVICE_HOST=unit.invalid)
t_eq "the device and image expectations are both in scope" "$out" "aarch64 root"

t_done
