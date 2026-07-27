#!/usr/bin/env bash
#
# The update mechanism, as it ships.
#
# None of this can be exercised without hardware — the firmware's slot
# selection is the one part of the system no image reader can run. What an
# image can hold is everything the mechanism would be wrong about *before* it
# ever runs: a slot pointing at the wrong partition installs an update over the
# system that is running, a keyring baked into the image is a device that
# trusts whoever built it, and a commit that is not gated on a health check is
# an update with no way back.
#
# It ships in the first image on purpose, untested, so that every OS change
# after the first flash travels as a bundle instead of a cable.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system

# --- what RAUC is told about this device ------------------------------------

if ! conf=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_RAUC_SYSTEM_CONF"); then
	t_fail "the update mechanism is configured" "nothing at ${EXPECT_RAUC_SYSTEM_CONF}"
	t_done
fi

t_eq "the bundles this device accepts are its own" \
	"$(img_ini_section_value "$conf" system compatible)" "$EXPECT_RAUC_COMPATIBLE"
t_eq "slot selection is delegated to the backend" \
	"$(img_ini_section_value "$conf" system bootloader)" "$EXPECT_RAUC_BOOTLOADER"

# The legacy bundle format is unsigned-payload-shaped: the manifest is signed
# but the images are only verified after they have been written. Naming the
# format the device accepts is what refuses one.
t_eq "only the verified bundle format is accepted" \
	"$(img_ini_section_value "$conf" system bundle-formats)" "$EXPECT_RAUC_BUNDLE_FORMATS"

# The record of which slot is trusted is the one thing about an update that has
# to survive a reboot, so it is the one thing written to the writable
# partition. Anywhere else and it is in RAM, or it is in a slot that an update
# overwrites.
t_eq "the outcome of an update is recorded on the writable partition" \
	"$(img_ini_section_value "$conf" system statusfile)" "$EXPECT_RAUC_STATUSFILE"

# Nothing signs anything without a trust anchor, and this image has none: it
# reads the one the provisioning generation carries, through the published
# path, like every other credential on the device.
t_eq "bundles are judged against the provisioned keyring" \
	"$(img_ini_section_value "$conf" keyring path)" "$EXPECT_RAUC_KEYRING"
t_eq "the backend is the one in this image" \
	"$(img_ini_section_value "$conf" handlers bootloader-custom-backend)" \
	"$EXPECT_RAUC_BACKEND"

# An update and a configuration change are judged by the same health gate, so
# only one of them may be on trial at a time. This is the half that refuses the
# update; the other half refuses the configuration change, and both have to be
# there or the pair can still be interleaved from one side.
t_eq "an update is checked before anything is written" \
	"$(img_ini_section_value "$conf" handlers pre-install)" \
	"$EXPECT_RAUC_PREINSTALL"

# Every slot, in full. A wrong device here is the worst failure the update path
# has: an install onto the pair that is running, with no trial and nothing to
# roll back to.
while IFS= read -r spec; do
	section=${spec%%|*}
	settings=${spec#*|}
	IFS=, read -r -a wanted <<<"$settings"
	for setting in "${wanted[@]}"; do
		key=${setting%%=*}
		value=${setting#*=}
		t_eq "${section} ${key}" \
			"$(img_ini_section_value "$conf" "$section" "$key")" "$value"
	done
done <<<"$EXPECT_RAUC_SLOTS"

# The devices are labels, and a label is only a label if the partition table
# carries it. Cross-checked against the table rather than against a list, so a
# rename on either side is a failure here and not on a device that then has no
# second slot.
table=$(printf '%s\n' "${IMG_PART_NAME[@]}")
while IFS= read -r spec; do
	section=${spec%%|*}
	device=$(img_ini_section_value "$conf" "$section" device)
	t_contains "${section} names a partition that exists" "$table" "${device##*/}"
done <<<"$EXPECT_RAUC_SLOTS"

# Both halves of a pair flip together or neither does: the kernel and the root
# filesystem of one slot are one update, and a boot slot without a parent would
# be installed and committed on its own.
t_eq "each boot slot belongs to its system slot" \
	"$(img_ini_section_value "$conf" slot.boot.0 parent):$(img_ini_section_value "$conf" slot.boot.1 parent)" \
	"rootfs.0:rootfs.1"

# The keyring is read through the published path, so the service must not be
# activated before the selection that publishes it. It is started on demand,
# long after that point in an ordinary boot, which is exactly why the ordering
# has to be written down: a dependency that holds by luck is one that stops
# holding on the boot where somebody installs early.
dropin="${units}/rauc.service.d/10-brenn-provisioned.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	t_contains "the update service waits for the generation to be selected" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_SELECT_UNIT"
else
	t_fail "the update service waits for the generation to be selected" \
		"no drop-in at ${dropin}"
fi

# --- the backend and its helpers --------------------------------------------

for prog in "$EXPECT_RAUC_BACKEND" "$EXPECT_TRYBOOT_CHECK" "$EXPECT_DEADMAN_EXEC" \
	"$EXPECT_RAUC_PREINSTALL"; do
	t_eq "${prog} is installed" "$(img_ext4_type "$IMG_SPEC" "$prog")" regular
	t_eq "${prog} is executable" "$(img_ext4_mode "$IMG_SPEC" "$prog")" 755
done

# --- what makes a boot worth keeping ----------------------------------------

health="${units}/${EXPECT_HEALTH_TARGET}"
if content=$(img_ext4_cat "$IMG_SPEC" "$health"); then
	requires=$(img_ini_values "$content" Requires | tr ' ' '\n')
	after=$(img_ini_values "$content" After | tr ' ' '\n')
	for want in $EXPECT_HEALTH_REQUIRES; do
		t_contains "being healthy requires ${want}" "$requires" "$want"
		t_contains "and waits for it" "$after" "$want"
	done
else
	t_fail "the health gate is defined" "no unit at ${health}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_HEALTH_TARGET}"); then
	t_eq "the health gate is part of the boot" "$link" "../${EXPECT_HEALTH_TARGET}"
else
	t_fail "the health gate is part of the boot" "nothing wants it"
fi

# --- committing, and giving up ----------------------------------------------

mark_good="${units}/${EXPECT_MARK_GOOD_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$mark_good"); then
	t_eq "the commit runs rauc" "$(img_ini_value "$content" ExecStart)" \
		"$EXPECT_MARK_GOOD_EXEC"

	# Requires, not Wants: a gate that was not reached has to leave this
	# unstarted. With Wants it would run anyway and commit a boot that had
	# proved nothing.
	t_contains "the commit requires the health gate" \
		"$(img_ini_values "$content" Requires | tr ' ' '\n')" "$EXPECT_HEALTH_TARGET"
	t_contains "and is ordered after it" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_HEALTH_TARGET"

	# And only on a boot that has something to commit. Without this the
	# statusfile is rewritten on the writable partition once per boot, forever,
	# on a device whose whole point is that it does not write to flash.
	t_eq "the commit runs only on a trial boot" \
		"$(img_ini_value "$content" ExecCondition)" "$EXPECT_TRYBOOT_CHECK"
else
	t_fail "the commit is wired" "no unit at ${mark_good}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_MARK_GOOD_UNIT}"); then
	t_eq "the commit is part of the boot" "$link" "../${EXPECT_MARK_GOOD_UNIT}"
else
	t_fail "the commit is part of the boot" "nothing wants it"
fi

deadman="${units}/${EXPECT_DEADMAN_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$deadman"); then
	t_eq "giving up runs the deadman" "$(img_ini_value "$content" ExecStart)" \
		"$EXPECT_DEADMAN_EXEC"
	t_eq "and only on a trial boot" \
		"$(img_ini_value "$content" ExecCondition)" "$EXPECT_TRYBOOT_CHECK"

	# The timer fires once. Without a retry a single transient failure — the
	# selector partition mounted the other way round by the commit running at
	# the same moment — is the end of the only thing that would have rescued a
	# candidate nobody can reach.
	t_eq "a deadman that failed tries again" \
		"$(img_ini_value "$content" Restart)" "$EXPECT_DEADMAN_RESTART"
	t_eq "and soon" \
		"$(img_ini_value "$content" RestartSec)" "$EXPECT_DEADMAN_RESTART_SEC"
	t_eq "with no start limit to turn the retry into a permanent failure" \
		"$(img_ini_value "$content" StartLimitIntervalSec)" 0
else
	t_fail "the deadman is wired" "no unit at ${deadman}"
fi

# The one-shot flag covers a candidate that fails loudly. This covers the one
# that comes up and is useless, which the firmware has no opinion about.
timer="${units}/${EXPECT_DEADMAN_TIMER}"
if content=$(img_ext4_cat "$IMG_SPEC" "$timer"); then
	t_eq "the deadman fires once, well into the boot" \
		"$(img_ini_value "$content" OnBootSec)" "$EXPECT_DEADMAN_ONBOOT"
else
	t_fail "the deadman has a timer" "no unit at ${timer}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/timers.target.wants/${EXPECT_DEADMAN_TIMER}"); then
	t_eq "the deadman timer is part of the boot" "$link" "../${EXPECT_DEADMAN_TIMER}"
else
	t_fail "the deadman timer is part of the boot" "nothing wants it"
fi

# --- where an update lands --------------------------------------------------

# A bundle is loop-mounted where it lies, so it cannot be staged in RAM; and
# the status file needs a directory before RAUC can write it. Both are created
# by the same rule, on the only partition that survives an update.
#
# Their modes are part of it. A staged bundle and the record of which slot is
# trusted are the update mechanism's own state, and a directory anyone can
# write is somewhere to leave a bundle the operator did not put there.
if content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_RAUC_TMPFILES"); then
	while IFS=: read -r path mode owner; do
		line=$(printf '%s\n' "$content" | awk -v p="$path" '$1 == "d" && $2 == p')
		if [ -z "$line" ]; then
			t_fail "${path} is created before anything needs it" "no rule for it"
			continue
		fi
		t_eq "${path} is mode ${mode}" "$(printf '%s' "$line" | awk '{print $3}')" "$mode"
		t_eq "${path} belongs to ${owner}" "$(printf '%s' "$line" | awk '{print $4}')" "$owner"
	done <<<"$EXPECT_RAUC_TMPFILES_DIRS"
else
	t_fail "the update's directories are created" "no rule at ${EXPECT_RAUC_TMPFILES}"
fi

# --- and nothing else -------------------------------------------------------

# The image carries no trust anchor of its own. One here would be a fleet whose
# every device trusts whatever this build trusted, published in a public repo.
t_eq_text "the image ships nothing under /etc/rauc but the configuration" \
	"$(img_ext4_ls "$IMG_SPEC" /etc/rauc | sort)" "$EXPECT_RAUC_ETC_CONTENTS"

installed=$(img_installed_packages "$IMG_SPEC" | cut -d' ' -f1)
for pkg in $EXPECT_RAUC_PACKAGES; do
	t_contains "${pkg} is installed" "$installed" "$pkg"
done

t_done
