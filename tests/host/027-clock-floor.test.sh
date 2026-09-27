#!/usr/bin/env bash
#
# The boot-clock floor, run against a clock this test controls.
#
# brenn-clock-floor is the program that raises a cold unit's clock to the
# image's pinned date. What it decides is ordinary: whether the clock is behind
# the pin, and whether the pin can be read at all. That is exercised here by
# running the real script with a `date` first on the path that answers "now"
# with a chosen value, converts every other time by handing it to the real
# `date`, and records any attempt to set the clock instead of making it.
#
# Then the shipped pin, as the script reads it, is held to the values around
# it: EXPECT_CLOCK_FLOOR, which the device lane compares the unit's journal line
# with, and the image's epoch, which the floor must be later than to be a floor
# at all.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/time.rootfs-overlay"
script="${overlay}/usr/lib/brenn/brenn-clock-floor"
pin="${overlay}/usr/lib/brenn/clock-floor"
image_env="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env"
common="${BRENN_REPO_ROOT}/image/config/brenn-common.yaml"

for f in "$script" "$pin" "$image_env" "$common"; do
	if [ ! -f "$f" ]; then
		t_fail "the clock floor's inputs exist" "nothing at ${f}"
		t_done
	fi
done

real_date=$(command -v date) || t_skip "requires date, which is not installed"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The stub answers the three shapes of call the script makes. `-s` is recorded
# and not performed, and fails when SET_FAILS is set, as it does for a process
# without the right to set the clock; `-d` is a conversion and goes to the real
# `date`; a bare `+%s` is "now". Anything else is a change to the script this
# file does not cover yet, and says so rather than answering it.
bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/date" <<STUB
#!/bin/sh
for a in "\$@"; do
	case \$a in
		-s)
			printf '%s\n' "\$*" >>"\${SET_LOG}"
			if [ -n "\${SET_FAILS:-}" ]; then
				echo "date: cannot set date: Operation not permitted" >&2
				exit 1
			fi
			exit 0
			;;
	esac
done
for a in "\$@"; do
	case \$a in
		-d) exec "${real_date}" "\$@" ;;
	esac
done
if [ "\$*" = "-u +%s" ]; then
	echo "\${FAKE_NOW}"
	exit 0
fi
echo "stub date: unexpected call: \$*" >&2
exit 99
STUB
chmod 0755 "${bin}/date"

set_log="${work}/set.log"

# Runs the script against pin $1 with the clock at epoch second $2, and with
# every attempt to set the clock failing if $3 is non-empty. The script's
# output lands in $out, its status in $status, and every clock-setting call in
# $sets.
run_floor() {
	: >"$set_log"
	status=0
	out=$(PATH="${bin}:${PATH}" FAKE_NOW=$2 SET_LOG=$set_log SET_FAILS=${3:-} \
		BRENN_CLOCK_FLOOR_FILE=$1 sh "$script" 2>&1) || status=$?
	sets=$(cat "$set_log")
}

# A synthetic pin, so the cases below do not move when the real one is bumped.
test_pin="${work}/pin"
cat >"$test_pin" <<'PIN'
# a comment

  # an indented comment
2026-09-27T00:00:00Z

PIN
floor=$("$real_date" -u -d 2026-09-27T00:00:00Z +%s)

# Behind the floor: one step, to exactly the floor, and a line naming both ends.
run_floor "$test_pin" $((floor - 86400))
t_ok "a clock behind the floor is raised" "$status" "$out"
t_eq "the clock is set once, to the floor" "$sets" "-u -s @${floor}"
t_eq "and the step is reported in the pin's form" "$out" \
	"clock-floor: advanced from 2026-09-26T00:00:00Z to 2026-09-27T00:00:00Z (floor 2026-09-27T00:00:00Z)"

# At the floor: nothing to do. The comparison is strict, so a clock that is
# already exactly right is not stepped onto itself.
run_floor "$test_pin" "$floor"
t_ok "a clock at the floor is accepted" "$status" "$out"
t_eq "and is not set" "$sets" ""
t_eq "and is reported as kept" "$out" \
	"clock-floor: kept 2026-09-27T00:00:00Z (floor 2026-09-27T00:00:00Z)"

# Past the floor — a unit with a clock of its own, or a later boot epoch.
run_floor "$test_pin" $((floor + 3600))
t_ok "a clock past the floor is accepted" "$status" "$out"
t_eq "and is not set" "$sets" ""
t_eq "and is reported as kept" "$out" \
	"clock-floor: kept 2026-09-27T01:00:00Z (floor 2026-09-27T00:00:00Z)"

# A pin that cannot be read is a failed unit, which the device lane sees, and
# never a clock set from a guess.
refuses() {
	local desc=$1 content=$2 needle=$3
	printf '%s' "$content" >"${work}/bad-pin"
	run_floor "${work}/bad-pin" $((floor - 86400))
	t_fails "${desc} is refused" "$status" "$out"
	t_eq "${desc} leaves the clock alone" "$sets" ""
	t_has "${desc} is named in the refusal" "$out" "$needle"
}

refuses "a pin with no value" $'# only a comment\n\n' "no floor in ${work}/bad-pin"
refuses "a pin with two values" \
	$'2026-09-27T00:00:00Z\n2026-10-27T00:00:00Z\n' "2 values in ${work}/bad-pin"
refuses "a pin with an unparseable value" $'not-a-date\n' \
	"unparseable floor in ${work}/bad-pin: not-a-date"

run_floor "${work}/no-such-pin" $((floor - 86400))
t_fails "a missing pin is refused" "$status" "$out"
t_eq "a missing pin leaves the clock alone" "$sets" ""

# A clock that cannot be set is a failed unit, not a line claiming the step
# happened: the device lane reads that line as the record of the boot clock.
run_floor "$test_pin" $((floor - 86400)) fail
t_fails "a clock that cannot be set fails the unit" "$status" "$out"
t_eq "the set was attempted" "$sets" "-u -s @${floor}"
t_lacks "and no advance is reported" "$out" "advanced"

# A clock reading that is not a number cannot be compared with the floor, so
# nothing is decided from it.
run_floor "$test_pin" "not-a-number"
t_fails "an unreadable clock is refused" "$status" "$out"
t_eq "an unreadable clock is left alone" "$sets" ""
t_has "and is named in the refusal" "$out" "unreadable clock: not-a-number"

# The shipped pin, read through the script rather than a second copy of its
# grammar. The value the script applies is the one it reports as `(floor …)`,
# the part of the line the device lane reads out of the journal and compares
# with EXPECT_CLOCK_FLOOR.
run_floor "$pin" 0
t_ok "the script reads the shipped pin" "$status" "$out"
shipped=$(printf '%s\n' "$out" | sed -n 's/.*(floor \([^)]*\))$/\1/p')
expected=$(sed -n 's/^EXPECT_CLOCK_FLOOR=//p' "$image_env")
t_eq "the shipped pin is the floor the image lane expects" "$shipped" "$expected"

# Later than the image's epoch. timesyncd already steps a cold clock to the
# epoch's timestamp, so a floor at or before it would raise nothing.
epoch=$(sed -n 's/^[[:space:]]*SOURCE_DATE_EPOCH:[[:space:]]*//p' "$common" | head -n1)
if shipped_s=$("$real_date" -u -d "$shipped" +%s 2>/dev/null) && [ -n "$epoch" ]; then
	if [ "$shipped_s" -gt "$epoch" ]; then
		t_pass "the floor is later than SOURCE_DATE_EPOCH (${shipped_s} > ${epoch})"
	else
		t_fail "the floor is later than SOURCE_DATE_EPOCH" \
			"floor: ${shipped_s} (${shipped})" "epoch: ${epoch}"
	fi
else
	t_fail "the floor is later than SOURCE_DATE_EPOCH" \
		"floor: ${shipped:-<nothing>}" "epoch: ${epoch:-<nothing>}"
fi

t_done
