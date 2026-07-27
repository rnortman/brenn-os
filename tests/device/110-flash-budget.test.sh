#!/usr/bin/env bash
#
# The two budgets: writes to the flash, and room in memory.
#
# The flash on this device is soldered down and has a finite write budget, and
# every architectural decision in this repository — the read-only root, the
# memory-backed /var, the volatile journal that is uploaded instead of stored,
# the application that lives in RAM and is fetched at every boot — exists to
# make the steady-state number zero. This is the assertion that says whether it
# is. Everything else about flash wear is a design intention; this is a
# measurement.
#
# It is a measurement of an *idle* device, which is the state a deployed unit is
# in almost all of the time. The deliberate write classes are all events —
# provisioning, staging an update bundle, committing a slot — and none of them
# is happening while this runs.
#
# A nonzero reading is a finding, not a number to widen the limit to: it means
# something is writing that nobody decided should. The failure names the
# partition, because "the persistent partition" and "a system slot" are very
# different findings.
#
# The memory budget is the other side of the same architecture. The application
# store is a capped memory-backed filesystem, so the system has to be able to
# leave that much unused; a device that cannot is a device whose payload will
# not fit.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

disk=$EXPECT_FLASH_STAT_DIR
window=$EXPECT_IDLE_WINDOW_SECONDS

# Both readings in one session, with the wait on the device: the window is then
# exactly the window, and the measurement does not include whatever a second
# login costs. Field seven of each stat file is sectors written.
#
# The whole disk and each of its partitions are read together, so that a
# surprise can be attributed rather than only noticed.
snapshot="for f in $(dev_quote "${disk}/stat") $(dev_quote "$disk")/*/stat; do printf '%s %s\\n' \"\$f\" \"\$(awk '{print \$7}' \"\$f\")\"; done"
status=0
dev_capture "${snapshot}; echo ---; sleep ${window}; ${snapshot}" || status=$?

# A counter nobody read is not a counter that stayed still, and the difference
# between the two is the whole value of this measurement. The session is the
# longest-held connection in the suite and it runs over the same radio a
# previous test dropped on purpose, so it losing the device partway is an
# ordinary event — and a transcript with no readings in it subtracts to zero as
# readily as an idle device does. So the reading is asserted before it is
# judged: one number for the whole disk on each side of the window.
readings=$(printf '%s\n' "$DEV_OUT" | awk -v p="${disk}/stat" '
	/^---$/ { after = 1; next }
	$1 == p && $2 ~ /^[0-9]+$/ { if (after) a++; else b++ }
	END { printf "%d %d\n", b, a }
')

if [ "$status" -ne 0 ] || [ "$readings" != "1 1" ]; then
	t_fail "the flash write counters were read across the window" \
		"session status: ${status}" \
		"readings of ${disk}/stat, before and after: ${readings}" \
		"output: ${DEV_OUT:-<nothing>}"
else
	deltas=$(printf '%s\n' "$DEV_OUT" | awk '
		/^---$/ { after = 1; next }
		!after { before[$1] = $2; next }
		$1 in before {
			d = $2 - before[$1]
			if (d != 0) printf "%s %d\n", $1, d
		}
	')
	# Absent from the deltas means the two readings were equal, which is the
	# answer this test wants; that they exist at all is settled above.
	total=$(printf '%s\n' "$deltas" | awk -v p="${disk}/stat" '$1 == p { print $2 }')
	total=${total:-0}

	if [ "$total" -le "$EXPECT_IDLE_WRITE_SECTORS_MAX" ]; then
		t_pass "nothing was written to the flash in ${window}s (${total} sectors)"
	else
		mapfile -t attribution < <(printf '%s\n' "$deltas" | sed 's/^/  /')
		t_fail "nothing was written to the flash in ${window}s" \
			"sectors written: ${total}" \
			"limit:           ${EXPECT_IDLE_WRITE_SECTORS_MAX}" \
			"deltas, by device:" \
			"${attribution[@]}"
	fi
fi

# Room for the payload. The store is capped at a size the profile chose, so the
# system has to leave at least that much available, plus a margin for the
# application that will be running out of it.
dev_capture "awk '/^MemTotal:/ { total = \$2 } /^MemAvailable:/ { avail = \$2 } END { print total, avail }' /proc/meminfo"
read -r mem_total mem_available <<<"$DEV_OUT"

budget=$((EXPECT_APP_MOUNT_SIZE_K + EXPECT_MEM_HEADROOM_MARGIN_K))
if [ -z "${mem_available:-}" ]; then
	t_fail "memory is available for the application store" \
		"could not read /proc/meminfo: ${DEV_OUT:-<nothing>}"
else
	t_ge "memory is available for the application store and its margin (of ${mem_total} kB total)" \
		"$mem_available" "$budget"
fi

t_done
