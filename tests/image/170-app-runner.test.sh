#!/usr/bin/env bash
#
# The application runner, as the image ships it.
#
# What the runner's programs do with a payload is asserted by running them, in
# tests/host. What is left for an image to answer is everything around them:
# that the payload lands in RAM and not on flash, that the entry point runs
# unprivileged, that a boot which cannot obtain a payload cannot commit an
# update, and that the address a payload comes from is nowhere in the image.
#
# None of this has run on hardware. It ships in the first flash anyway, because
# the alternative is a second flash to add it — so the image is where it is
# held to account until the device can be.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system

# --- the payload lives in RAM -------------------------------------------------

mount_unit="${units}/${EXPECT_APP_MOUNT_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$mount_unit"); then
	t_eq "the payload store is a tmpfs" "$(img_ini_value "$content" Type)" tmpfs
	t_eq "at the path the contract names" \
		"$(img_ini_value "$content" Where)" "$EXPECT_APP_MOUNT_WHERE"

	# The cap is the whole reason this is a mount of its own rather than a
	# directory under /run: a payload that pulls a model too large for the
	# budget has to fail here, where it is a failed unit, rather than against
	# the memory the rest of the system needs.
	t_eq "capped, and executable because the entry point is executed from it" \
		"$(img_ini_value "$content" Options)" "$EXPECT_APP_MOUNT_OPTIONS"
else
	t_fail "the payload store is mounted" "no unit at ${mount_unit}"
fi

# A mount unit nothing pulls in is a directory on the read-only root, and the
# first thing to write to it fails.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/local-fs.target.wants/${EXPECT_APP_MOUNT_UNIT}"); then
	t_eq "the payload store is part of the boot" "$link" "../${EXPECT_APP_MOUNT_UNIT}"
else
	t_fail "the payload store is part of the boot" "nothing wants it"
fi

# --- the programs -------------------------------------------------------------

for prog in "$EXPECT_APP_FETCH_EXEC" "$EXPECT_APP_ACTIVATE_EXEC" "$EXPECT_APP_RESYNC_EXEC" \
	"$EXPECT_APP_STAGE_EXEC" "$EXPECT_APP_BAKE_EXEC" "$EXPECT_APP_UNBAKE_EXEC"; do
	t_eq "${prog} is installed" "$(img_ext4_type "$IMG_SPEC" "$prog")" regular
	t_eq "${prog} is executable" "$(img_ext4_mode "$IMG_SPEC" "$prog")" 755
	t_eq "${prog} is beside the fetch" "$(dirname "$prog")" "$(dirname "$EXPECT_APP_FETCH_EXEC")"
done

t_eq "the payload library is installed" "$(img_ext4_type "$IMG_SPEC" "$EXPECT_APP_LIB")" regular
t_eq "and is a library, not a program" "$(img_ext4_mode "$IMG_SPEC" "$EXPECT_APP_LIB")" 644
t_eq "beside the programs that source it" \
	"$(dirname "$EXPECT_APP_LIB")" "$(dirname "$EXPECT_APP_FETCH_EXEC")"

# The programs find each other by their own directory, so an operator's copy
# runs its own siblings; that only resolves on a device if they are installed
# together.
t_eq "the runner's programs are installed in one place" \
	"$(dirname "$EXPECT_APP_ACTIVATE_EXEC")" "$(dirname "$EXPECT_APP_FETCH_EXEC")"

# The fetch reads the provisioning generation through the contract library, and
# finds it the same way — beside itself. The two come from different layers, so
# nothing but this says they land in the same directory.
t_eq "the contract library the fetch sources is beside it" \
	"$(dirname "$EXPECT_CONFIG_LIB")" "$(dirname "$EXPECT_APP_FETCH_EXEC")"
t_eq "and is installed" "$(img_ext4_type "$IMG_SPEC" "$EXPECT_CONFIG_LIB")" regular

# The documented way to resync or to apply a configuration change is a command
# over SSH, which means the shell has to be able to find it by name.
for path in $EXPECT_APP_PATH_LINKS; do
	if target=$(img_ext4_link "$IMG_SPEC" "$path"); then
		t_eq "${path} is on the path and resolves into /usr/lib/brenn" \
			"$(basename "$(dirname "$target")")" brenn
	else
		t_fail "${path} is reachable by name" "no link at ${path}"
	fi
done

# --- obtaining a payload -------------------------------------------------------

fetch="${units}/${EXPECT_APP_FETCH_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$fetch"); then
	t_eq "the fetch runs the runner's own program" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_APP_FETCH_EXEC"

	after=$(img_ini_values "$content" After | tr ' ' '\n')
	for dep in $EXPECT_APP_FETCH_AFTER; do
		t_contains "the fetch waits for ${dep}" "$after" "$dep"
	done

	# An unprovisioned device has nowhere to fetch from and must not spend
	# its boot discovering that.
	t_contains "the fetch is skipped when the device was never provisioned" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"$EXPECT_APP_FETCH_CONDITION"

	# The half of the health gate this layer contributes: ordered before it
	# here, required by it through the gate's own .requires directory.
	t_contains "the fetch is part of what the health gate waits for" \
		"$(img_ini_values "$content" Before | tr ' ' '\n')" "$EXPECT_APP_FETCH_BEFORE"

	# The retry is inside the program, which only works if systemd is willing
	# to wait: a start timeout would kill it mid-outage, and a start limit
	# would turn a long outage into a permanent failure.
	t_eq "the fetch is allowed to take as long as the outage does" \
		"$(img_ini_value "$content" TimeoutStartSec)" "$EXPECT_APP_FETCH_TIMEOUT"
	t_eq "and no start limit ever ends the retry" \
		"$(img_ini_value "$content" StartLimitIntervalSec)" "$EXPECT_APP_FETCH_START_LIMIT"

	# The store, before the fetch writes to it, and the persistent
	# partition, before the baked condition is read from it.
	mounts=$(img_ini_values "$content" RequiresMountsFor | tr ' ' '\n')
	for mnt in $EXPECT_APP_OBTAIN_MOUNTS; do
		t_contains "${mnt} is mounted before the fetch runs" "$mounts" "$mnt"
	done

	# Offline autonomy is what baking is for, so a baked device does not
	# fetch at boot even when its generation names a payload.
	t_contains "the fetch is skipped on a baked device" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"$EXPECT_APP_FETCH_BAKED_CONDITION"
else
	t_fail "the fetch is installed" "no unit at ${fetch}"
fi

# Requires, not Wants. A gate that would be reached without a payload is a gate
# that commits an update onto a device which cannot run the application, and
# the device would then have no way of being told to try again.
requires="${units}/${EXPECT_APP_FETCH_BEFORE}.requires/${EXPECT_APP_FETCH_UNIT}"
if link=$(img_ext4_link "$IMG_SPEC" "$requires"); then
	t_eq "a boot with no payload does not reach the health gate" \
		"$link" "../${EXPECT_APP_FETCH_UNIT}"
else
	t_fail "a boot with no payload does not reach the health gate" \
		"nothing at ${requires}"
fi

# The baked door: the payload on the persistent partition, staged into RAM.
stage="${units}/${EXPECT_APP_STAGE_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$stage"); then
	t_eq "the stage runs the runner's own program" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_APP_STAGE_EXEC"
	t_contains "the stage runs only on a baked device" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"$EXPECT_APP_BAKED_CONDITION"
	mounts=$(img_ini_values "$content" RequiresMountsFor | tr ' ' '\n')
	for mnt in $EXPECT_APP_OBTAIN_MOUNTS; do
		t_contains "${mnt} is mounted before the stage runs" "$mounts" "$mnt"
	done
	t_contains "the stage is part of what the health gate waits for" \
		"$(img_ini_values "$content" Before | tr ' ' '\n')" "$EXPECT_APP_FETCH_BEFORE"
	t_eq "the stage has time to unpack a large payload from flash" \
		"$(img_ini_value "$content" TimeoutStartSec)" "$EXPECT_APP_STAGE_TIMEOUT"

	# A store that fails its digest fails it again; retrying would only
	# hide the failure the gate is meant to see.
	t_eq "the stage is one attempt" "$(img_ini_values "$content" Restart)" ""
else
	t_fail "the stage is installed" "no unit at ${stage}"
fi

requires="${units}/${EXPECT_APP_FETCH_BEFORE}.requires/${EXPECT_APP_STAGE_UNIT}"
if link=$(img_ext4_link "$IMG_SPEC" "$requires"); then
	t_eq "a baked boot that cannot stage its payload does not reach the health gate" \
		"$link" "../${EXPECT_APP_STAGE_UNIT}"
else
	t_fail "a baked boot that cannot stage its payload does not reach the health gate" \
		"nothing at ${requires}"
fi

# --- running it ----------------------------------------------------------------

app="${units}/${EXPECT_APP_UNIT}"
if content=$(img_ext4_cat "$IMG_SPEC" "$app"); then
	t_eq "the entry point is the one the contract publishes" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_APP_EXEC"
	t_eq "and it runs with the payload as its working directory" \
		"$(img_ini_value "$content" WorkingDirectory)" "$EXPECT_APP_WORKDIR"

	# Unprivileged, with no opt-in anywhere. A payload arriving over the
	# network with root would make the application channel a channel into the
	# operating system, which is the one thing the split between them exists
	# to prevent.
	t_eq "the payload runs as the unprivileged account" \
		"$(img_ini_value "$content" User)" "$EXPECT_APP_USER"
	t_eq "and cannot acquire privilege it was not given" \
		"$(img_ini_value "$content" NoNewPrivileges)" yes

	# What the contract publishes about a payload that returns, held
	# against what the unit actually does. A payload author reads the
	# document and gets this wrong exactly once, on a device.
	t_eq "a payload that fails is put back, and one that exits cleanly is not" \
		"$(img_ini_value "$content" Restart)" "$EXPECT_APP_RESTART"

	t_eq_text "the payload is told exactly what the contract says it is told" \
		"$(img_ini_values "$content" Environment)" "$EXPECT_APP_ENVIRONMENT"

	# A read-only root, and three exceptions: scratch in RAM, and the two
	# places on flash a payload may deliberately write.
	t_eq "the payload sees a read-only system" \
		"$(img_ini_value "$content" ProtectSystem)" strict
	t_eq "with only the places the contract allows writable" \
		"$(img_ini_value "$content" ReadWritePaths)" "$EXPECT_APP_READWRITE"

	t_contains "nothing runs until a payload is current" \
		"$(img_ini_values "$content" ConditionPathExists | tr ' ' '\n')" \
		"${EXPECT_APP_EXEC}"

	# Neither door is pulled in or waited for by the application. A pull
	# would re-read the doors' conditions on every restart and could stage
	# or fetch over whatever an operator put in place; an ordering would hold
	# an offline baked boot behind a fetch waiting for the network. The
	# health gate pulls both in, and the activation's restart starts this.
	for key in Requires Wants After; do
		deps=$(img_ini_values "$content" "$key" | tr ' ' '\n')
		for unit in "$EXPECT_APP_FETCH_UNIT" "$EXPECT_APP_STAGE_UNIT"; do
			t_lacks "the application's ${key}= does not name ${unit}" "$deps" "$unit"
		done
	done
else
	t_fail "the application unit is installed" "no unit at ${app}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_APP_UNIT}"); then
	t_eq "the application is part of the boot" "$link" "../${EXPECT_APP_UNIT}"
else
	t_fail "the application is part of the boot" "nothing wants it"
fi

# --- the directories it needs ---------------------------------------------------

if content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_APP_TMPFILES"); then
	while IFS=: read -r path mode owner; do
		line=$(printf '%s\n' "$content" | awk -v p="$path" '$1 == "d" && $2 == p')
		if [ -z "$line" ]; then
			t_fail "${path} is created before anything needs it" "no rule for it"
			continue
		fi
		t_eq "${path} belongs to ${owner}" "$(printf '%s' "$line" | awk '{print $4}')" "$owner"

		# The mode, not only the owner: what makes an activated payload
		# immutable is that the account running it cannot write the
		# directory it came out of, and a release store gone
		# group-writable would be the application rewriting what the
		# operating system activated.
		t_eq "${path} is mode ${mode}" "$(printf '%s' "$line" | awk '{print $3}')" "$mode"
	done <<<"$EXPECT_APP_TMPFILES_DIRS"
else
	t_fail "the runner's directories are created" "no rules at ${EXPECT_APP_TMPFILES}"
fi

# --- nothing site-specific -------------------------------------------------------

installed=$(img_installed_packages "$IMG_SPEC" | awk '{print $1}')
for pkg in $EXPECT_APP_PACKAGES; do
	t_contains "${pkg} is installed, because turning a URL into a payload needs it" \
		"$installed" "$pkg"
done

# The address a payload comes from arrives with the provisioning generation. An
# image naming one would be an image for one deployment, published.
#
# A path that cannot be read is a failure and not a pass: a sweep that read
# nothing is the green result that checked nothing, and this is the only thing
# in the app layer looking for an address.
offenders=""
for path in "$mount_unit" "$fetch" "$stage" "$app" "$EXPECT_APP_FETCH_EXEC" \
	"$EXPECT_APP_ACTIVATE_EXEC" "$EXPECT_APP_RESYNC_EXEC" "$EXPECT_APP_STAGE_EXEC" \
	"$EXPECT_APP_BAKE_EXEC" "$EXPECT_APP_UNBAKE_EXEC" "$EXPECT_APP_LIB"; do
	if ! content=$(img_ext4_cat "$IMG_SPEC" "$path"); then
		t_fail "no application server is named in ${path}" "it could not be read"
		continue
	fi
	if printf '%s' "$content" | grep -Eq '://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]'; then
		offenders="${offenders}${path} "
	fi
done
t_eq "no application server is named anywhere in the image" "$offenders" ""

t_done
