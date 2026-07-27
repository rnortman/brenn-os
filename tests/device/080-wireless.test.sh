#!/usr/bin/env bash
#
# The radio: associated, operating under the right law, and able to come back.
#
# This device is deployed on wireless, so the association is the whole
# connection to it — an update, a configuration change and every log line all
# ride on it. Two properties matter beyond "it worked once at boot". The first
# is that the regulatory domain came from the provisioned configuration and not
# from something baked into the image, because a device operating under the
# wrong domain is a device transmitting where it may not. The second is that a
# lost association is recovered without anyone present, which is the one
# failure that is guaranteed to happen and the one nobody can reach the device
# to fix.
#
# The recovery assertion deliberately runs the disconnection detached and polls
# from outside: on a unit reached over the radio, the command that breaks the
# association also breaks the session issuing it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

wlan=$EXPECT_WLAN_INTERFACE
state_cmd="wpa_cli -i $(dev_quote "$wlan") status | sed -n 's/^wpa_state=//p'"

dev_eq "the supplicant for the onboard radio is running" \
	"systemctl is-active $(dev_quote "$EXPECT_SUPPLICANT_UNIT")" active

dev_eq "the radio is associated" "$state_cmd" "$EXPECT_WPA_STATE"

dev_capture "ip -o -4 addr show dev $(dev_quote "$wlan") scope global | wc -l"
if [ "${DEV_OUT:-0}" -ge 1 ] 2>/dev/null; then
	t_pass "the radio holds a routable address"
else
	t_fail "the radio holds a routable address" \
		"addresses in global scope: ${DEV_OUT:-<nothing>}"
fi

# Nothing was baked. The module parameter is the mechanism the vendor image
# used, and the world domain is what it reports when nobody set it — which is
# the state that lets the provisioned country be the only source.
dev_eq "no regulatory domain is compiled into the kernel's view" \
	"cat $(dev_quote "$EXPECT_REGDOM_MODULE_PARAM")" "$EXPECT_REGDOM_MODULE_VALUE"

# ...and the domain in force is the one the generation asked for. Both sides of
# this comparison are read from the device: the country is site configuration
# and does not appear in this repository, so what is asserted is that the two
# readings agree rather than that either equals a value written here.
dev_capture "sed -n 's/^[[:space:]]*country=\\([A-Za-z][A-Za-z]\\).*/\\1/p' $(dev_quote "${EXPECT_SUPPLICANT_CONF}") | head -n1"
provisioned=$(printf '%s' "$DEV_OUT" | tr '[:lower:]' '[:upper:]')

dev_capture "journalctl -k -b --grep 'Regulatory domain changed' -o cat | tail -n1"
applied=$(printf '%s' "$DEV_OUT" | sed -n 's/.*country: \([A-Z][A-Z]\).*/\1/p')

if [ -z "$provisioned" ]; then
	t_fail "the provisioned configuration names a regulatory domain" \
		"no country= in ${EXPECT_SUPPLICANT_CONF}"
elif [ -z "$applied" ]; then
	t_fail "the kernel applied the provisioned regulatory domain" \
		"no regulatory change in this boot's kernel log" \
		"last line: ${DEV_OUT:-<nothing>}"
else
	t_eq "the kernel applied the provisioned regulatory domain" "$applied" "$provisioned"
fi

# Recovery. The association is dropped and told to come back, and what is
# asserted is that the device gets itself back: through a scan, an association,
# a lease, and — when this lane is running over the radio — an SSH session that
# had to be re-established to observe any of it.
#
# The drop has to be shown to have happened, and it cannot be watched while it
# is happening: the command that breaks the association also breaks the session
# issuing it, so it is fired detached and its status is unobservable, and on a
# unit reached over the radio nothing can be asked of the device for as long as
# the association is down. That leaves "it recovered" and "it never went down"
# looking identical from out here — a wrong interface name takes out the
# disconnection and every in-band way of noticing at once, and the recovery
# assertions would then pass against an association that was never disturbed. So
# the evidence is the supplicant's own record of the event, read against a mark
# taken in the device's clock because that is the clock the journal is read in.
#
# Order matters as much as the evidence does. The evidence wait goes first,
# immediately after the drop is fired, so that the recovery waits behind it
# start from a device that has been shown to be disconnected; asked before the
# disconnection has landed they answer from the association still in place and
# pass having observed nothing. Going first costs the evidence wait its window:
# on a unit reached over the radio the journal cannot be read until the radio is
# back, so this wait rides the whole outage and is given the time the drop and
# the reconnection together are allowed to take.
status=0
dev_capture "date '+%Y-%m-%d %H:%M:%S'" || status=$?
since=$DEV_OUT
if [ "$status" -ne 0 ] || [ -z "$since" ]; then
	t_fail "the device's clock can be marked before the association is dropped" \
		"command failed (status ${status}): ${DEV_OUT:-<nothing>}"
else
	# The detached command is assembled first and quoted once, as the single
	# argument it is: quoting the interface name inside a quoted argument would
	# end the quoting of the argument that contains it, and the result would
	# parse only for values that contain no whitespace.
	drop="sleep 1; wpa_cli -i $(dev_quote "$wlan") disconnect"
	drop="${drop}; sleep ${EXPECT_WIFI_DROP_SECONDS}"
	drop="${drop}; wpa_cli -i $(dev_quote "$wlan") reconnect"
	dev_run "setsid sh -c $(dev_quote "$drop") >/dev/null 2>&1 </dev/null &" >/dev/null 2>&1

	# There was something to come back from. The supplicant announces the
	# disassociation, so its journal since the mark is what says the experiment
	# ran at all: this is the assertion that fails when the drop misfired, and
	# without it the two waits below are a report on a radio nobody touched.
	if dev_wait "the supplicant records the disassociation it was told to make" \
		"journalctl -u $(dev_quote "$EXPECT_SUPPLICANT_UNIT") --since $(dev_quote "$since") -o cat 2>/dev/null | grep -q -F $(dev_quote "$EXPECT_WPA_DISCONNECT_EVENT") && echo dropped" \
		dropped "$((EXPECT_WIFI_DROP_SECONDS + EXPECT_WIFI_RECONNECT_SECONDS))"; then

		dev_wait "and the radio re-associates after being disconnected" \
			"$state_cmd" "$EXPECT_WPA_STATE" "$EXPECT_WIFI_RECONNECT_SECONDS"

		dev_wait "and holds a routable address again" \
			"ip -o -4 addr show dev $(dev_quote "$wlan") scope global | wc -l | grep -q '^[1-9]' && echo yes" \
			yes "$EXPECT_WIFI_RECONNECT_SECONDS"
	else
		# Reporting recovery against an association that was never disturbed is
		# the failure this block is arranged to avoid, so it is not reported.
		t_fail "and the radio re-associates after being disconnected" \
			"no disassociation was recorded, so no recovery was observed"
		t_fail "and holds a routable address again" \
			"no disassociation was recorded, so no recovery was observed"
	fi
fi

t_done
