#!/usr/bin/env bash
#
# The application was obtained the way this device is set up to obtain it.
#
# A device obtains its payload through one of two doors at boot: it fetches the
# archive its generation names, or — when the baked store's link on the
# persistent partition resolves — it stages the archive it was baked with. The
# image suite reads the units that encode that choice; this reads what the
# service manager did with them on the boot that is running.
#
# It is a measurement in whichever mode the device is in, not a skip, and it is
# meant to be run at three points on the same device: before the first bake,
# after it on the same boot, and after the reboot that follows. The link alone
# does not say which of those this is — after a bake on a fetched boot the link
# resolves, but the stage was skipped at boot and the fetch is what ran — so
# the case is picked from two readings: whether the link resolves, and whether
# the stage unit is active, which it is only on a boot that staged.
#
# One measurement is common to every case in which the application is running:
# restarting it pulls in neither obtaining unit. That is what keeps a restart —
# an activation, a crash — from reopening the question of which door the
# payload comes through, and it is only observable on a running device.
#
# States an operator makes by hand — a development payload pushed over a baked
# one, an application stopped with systemctl — are not what this is for; run in
# one, it fails naming what it found.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

active_link=$EXPECT_APP_BAKED_CONDITION
stage=$EXPECT_APP_STAGE_UNIT
fetch=$EXPECT_APP_FETCH_UNIT
app=$EXPECT_APP_UNIT
current="${EXPECT_APP_DIR}/current"

# A unit's condition verdict and state on one line, with whether the condition
# has been evaluated at all: a unit whose start job is still waiting reports
# `no` and `inactive` exactly as one that was skipped, and only a nonzero
# condition timestamp tells them apart.
obtain_reading() {
	local u
	u=$(dev_quote "$1")
	printf '%s' "printf '%s %s %s\\n' \
		\"\$(systemctl show -p ConditionResult --value ${u})\" \
		\"\$(systemctl show -p ActiveState --value ${u})\" \
		\"\$(if [ \"\$(systemctl show -p ConditionTimestampMonotonic --value ${u})\" = 0 ]; then echo pending; else echo evaluated; fi)\""
}

unit_state() {
	printf '%s' "systemctl show -p ActiveState --value $(dev_quote "$1")"
}

skipped="no inactive evaluated"

# The store exists on every device, and is root's.
while IFS= read -r dir; do
	dev_eq "${dir} is root's and not writable by anyone else" \
		"stat -L -c '%U %a' $(dev_quote "$dir")" "$EXPECT_APP_BAKED_STORE_OWNER_MODE"
done <<<"$EXPECT_APP_BAKED_STORE_DIRS"

# The two readings that pick the case. The release name is the last element of
# where the link points, which is also the name its tree has in RAM.
dev_capture "if test -d $(dev_quote "$active_link"); then basename \"\$(readlink -f $(dev_quote "$active_link"))\"; fi"
baked_name=$DEV_OUT
dev_capture "$(unit_state "$stage")"
stage_state=$DEV_OUT

# Whenever the link resolves, the release it names is intact: the archive's
# digest is the one stored beside it, whatever is running from RAM.
if [ -n "$baked_name" ]; then
	dev_eq "the active baked release ${baked_name} matches its stored digest" \
		"cd $(dev_quote "$active_link") && test -f payload.tar && test -f sha256 &&
			test \"\$(sha256sum payload.tar | cut -d' ' -f1)\" = \"\$(cat sha256)\" && echo intact" \
		intact
fi

if [ -z "$baked_name" ] && [ "$stage_state" != active ]; then
	echo "NOTE  not baked"
	dev_eq "the stage was skipped at boot" "$(obtain_reading "$stage")" "$skipped"
	# The fetch runs whenever the generation names a payload: finished, or still
	# retrying through an outage. With no payload named it is skipped.
	dev_capture "if test -e $(dev_quote "$EXPECT_APP_FETCH_CONDITION"); then echo named; fi"
	if [ "$DEV_OUT" = named ]; then
		dev_capture "$(unit_state "$fetch")"
		case $DEV_OUT in
			active | activating) t_pass "the generation names a payload, and the fetch ran (${DEV_OUT})" ;;
			*) t_fail "the generation names a payload, and the fetch ran" \
				"expected active or activating" "state: ${DEV_OUT:-<nothing>}" ;;
		esac
	else
		dev_eq "the generation names no payload, and the fetch was skipped" \
			"$(obtain_reading "$fetch")" "$skipped"
	fi
elif [ -n "$baked_name" ] && [ "$stage_state" = active ]; then
	echo "NOTE  baked boot (${baked_name})"
	dev_eq "the running payload is the baked release" \
		"readlink $(dev_quote "$current")" "releases/${baked_name}"
	dev_eq "the application is running" "$(unit_state "$app")" active
	# Asserted over a window: on a device with no network the fetch's condition
	# is evaluated only when the wait for one gives up.
	dev_wait "the fetch was skipped" "$(obtain_reading "$fetch")" "$skipped" \
		"$EXPECT_APP_FETCH_SKIP_SECONDS"
elif [ -n "$baked_name" ]; then
	echo "NOTE  baked since boot (${baked_name})"
	# Skipped at boot, not failed: a stage that ran and failed leaves the link
	# resolving and the unit not active, and is a finding, not this case.
	dev_eq "the stage was skipped at boot" "$(obtain_reading "$stage")" "$skipped"
	dev_eq "the running payload is the baked release" \
		"readlink $(dev_quote "$current")" "releases/${baked_name}"
	dev_eq "the bake left the application running" "$(unit_state "$app")" active
	dev_capture "if test -e $(dev_quote "$EXPECT_APP_FETCH_CONDITION"); then echo named; fi"
	if [ "$DEV_OUT" = named ]; then
		# A fetch that finished before the bake is already active; one that was
		# retrying ends itself on its next attempt, which is where it looks at
		# the store.
		dev_wait "the fetch ended once the device was baked" \
			"$(unit_state "$fetch")" active "$EXPECT_APP_FETCH_LOOP_END_SECONDS"
	else
		# Skipped at boot, and nothing in a bake starts it.
		dev_eq "the generation names no payload, and the fetch was skipped" \
			"$(obtain_reading "$fetch")" "$skipped"
	fi
else
	echo "NOTE  unbaked since boot"
	dev_capture "readlink $(dev_quote "$current")"
	if [ "${DEV_OUT#releases/baked-}" != "$DEV_OUT" ]; then
		t_pass "the running payload is the one the stage materialised (${DEV_OUT})"
	else
		t_fail "the running payload is the one the stage materialised" \
			"expected releases/baked-*" "current: ${DEV_OUT:-<nothing>}"
	fi
	dev_eq "the application is running" "$(unit_state "$app")" active
	dev_eq "the fetch was skipped, and nothing since has started it" \
		"$(obtain_reading "$fetch")" "$skipped"
fi

# The restart step. A start job dispatched for either obtaining unit moves its
# condition timestamp, and a run moves its invocation id, so all of them and
# the running payload are read on either side of a restart of the application.
restart_reading="for u in $(dev_quote "$stage") $(dev_quote "$fetch"); do
	systemctl show -p ConditionTimestampMonotonic --value \"\$u\"
	systemctl show -p InvocationID --value \"\$u\"
done
readlink $(dev_quote "$current")"

dev_capture "$(unit_state "$app")"
if [ "$DEV_OUT" != active ]; then
	echo "NOTE  the application is not running (${DEV_OUT:-<nothing>}); the restart step does not apply"
else
	status=0
	dev_capture "$restart_reading" || status=$?
	before=$DEV_OUT
	if [ "$status" -ne 0 ]; then
		t_fail "the obtaining units were read before the restart" \
			"status: ${status}" "output: ${before:-<nothing>}"
	else
		dev_succeeds "the application can be restarted" "systemctl restart $(dev_quote "$app")"
		dev_wait "the application is running again" "$(unit_state "$app")" active \
			"$EXPECT_APP_RESTART_SECONDS"
		dev_capture "$restart_reading" || true
		t_eq_text "a restart of the application pulled in neither obtaining unit, nor changed its payload" \
			"$DEV_OUT" "$before"
	fi
fi

t_done
