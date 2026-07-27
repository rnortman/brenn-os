#!/usr/bin/env bash
#
# Changing configuration on a running device, as a transaction.
#
# A candidate generation is installed, tried for one boot, and kept only if the
# device reaches the health gate — the same gate an operating-system update
# commits on. What the programs of that transaction do is asserted by running
# them, off the device, in tests/host. What is left for an image to answer is
# what running them cannot reach: the commit is gated on the health target
# rather than merely ordered after it, both ends of the transaction are skipped
# on a boot that is not trying anything, the timer that gives up on a candidate
# is actually part of the boot, and the programs are installed where each
# other's relative lookups find them.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system

for prog in "$EXPECT_APPLY_EXEC" "$EXPECT_CONFIG_COMMIT_EXEC" "$EXPECT_CONFIG_DEADMAN_EXEC"; do
	t_eq "${prog} is installed" "$(img_ext4_type "$IMG_SPEC" "$prog")" regular
	t_eq "${prog} is executable" "$(img_ext4_mode "$IMG_SPEC" "$prog")" 755
done

# The apply program names the checker, the writer and the contract relative to
# its own directory, so that a copy running from a source tree runs that tree's
# siblings rather than the device's. That only resolves on the device if all
# four are installed in one place — the one thing about this arrangement an
# image can answer, and the one the host lane cannot.
#
# What those programs then do with a candidate is asserted by running them, in
# tests/host/050.
apply_dir=$(dirname "$EXPECT_APPLY_EXEC")
for sibling in "$EXPECT_VALIDATE_EXEC" "$EXPECT_INSTALL_EXEC" "$EXPECT_CONFIG_LIB"; do
	t_eq "${sibling} is installed beside the apply program" \
		"$(dirname "$sibling")" "$apply_dir"
	t_eq "and is there to be found" \
		"$(img_ext4_type "$IMG_SPEC" "$sibling")" regular
done

# --- committing --------------------------------------------------------------

commit="${units}/${EXPECT_CONFIG_COMMIT_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$commit"); then
	t_eq "the commit runs the transaction's own program" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_CONFIG_COMMIT_EXEC"

	# Requires, not Wants. With Wants a boot that never became healthy would
	# commit anyway, which is the whole failure the trial exists to catch —
	# and the failure is silent, because the device that cannot be reached is
	# the one that cannot report it.
	t_contains "the commit requires the health gate" \
		"$(img_ini_values "$content" Requires | tr ' ' '\n')" "$EXPECT_HEALTH_TARGET"
	t_contains "and is ordered after it" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_HEALTH_TARGET"

	# And only on a boot that is running a candidate. Without the condition
	# the unit runs on every boot and commits whatever happens to be staged,
	# unbooted.
	t_contains "the commit is skipped unless this boot is trying a candidate" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"$EXPECT_CONFIG_TRIAL_FLAG"
else
	t_fail "the configuration commit is installed" "no unit at ${commit}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_CONFIG_COMMIT_UNIT}"); then
	t_eq "the commit is part of the boot" "$link" "../${EXPECT_CONFIG_COMMIT_UNIT}"
else
	t_fail "the commit is part of the boot" "nothing wants it"
fi

# --- giving up ---------------------------------------------------------------

deadman="${units}/${EXPECT_CONFIG_DEADMAN_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$deadman"); then
	t_eq "the deadman runs the transaction's own program" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_CONFIG_DEADMAN_EXEC"
	t_contains "the deadman is skipped unless this boot is trying a candidate" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"$EXPECT_CONFIG_TRIAL_FLAG"
else
	t_fail "the configuration deadman is installed" "no unit at ${deadman}"
fi

timer="${units}/${EXPECT_CONFIG_DEADMAN_TIMER}"
if content=$(img_ext4_cat "$IMG_SPEC" "$timer"); then
	t_eq "the deadman fires once, well after the gate could have been reached" \
		"$(img_ini_value "$content" OnBootSec)" "$EXPECT_CONFIG_DEADMAN_ONBOOT"
else
	t_fail "the configuration deadman has a timer" "no unit at ${timer}"
fi

# A timer nothing pulls into the boot never fires, and a candidate that leaves
# the device unreachable then stays selected forever.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/timers.target.wants/${EXPECT_CONFIG_DEADMAN_TIMER}"); then
	t_eq "the deadman timer is part of the boot" "$link" "../${EXPECT_CONFIG_DEADMAN_TIMER}"
else
	t_fail "the deadman timer is part of the boot" "nothing wants it"
fi

t_done
