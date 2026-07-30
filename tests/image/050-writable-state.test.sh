#!/usr/bin/env bash
#
# What the running system may write to, and where those writes land.
#
# The A/B image layout's own answer is to put /var, /home and the journal on
# the persistent partition. This product's answer is that steady-state eMMC
# writes are zero: /var is an overlay with RAM on top of the baked filesystem,
# and the mounts that would put state on flash never run. Both answers are
# expressed as unit files, and the layout's answer wins by default, so this
# test is what stops a builder bump from quietly restoring it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system

# /data is the name every contract in this product uses. The layout mounts the
# writable partition at /persistent, so /data is a link to it.
if link=$(img_ext4_link "$IMG_SPEC" /data); then
	t_eq "/data points at the persistent partition" "$link" "$EXPECT_DATA_LINK"
else
	t_fail "/data is a symlink" "nothing found at /data in the root filesystem"
fi

# ...and it has to be mounted. The layout leaves that to fstab entries whose
# units this image holds back, so the requirement is stated separately.
if content=$(img_ext4_cat "$IMG_SPEC" "${units}/local-fs.target.d/10-brenn-persistent.conf"); then
	t_eq "the persistent partition is mounted at boot" \
		"$(img_ini_value "$content" RequiresMountsFor)" "/${EXPECT_DATA_LINK}"
else
	t_fail "the persistent partition is mounted at boot" \
		"no local-fs.target drop-in requiring it"
fi

# The /var overlay: RAM store, the unit that creates its directories, and the
# overlay itself.
if content=$(img_ext4_cat "$IMG_SPEC" "${units}/run-brenn-var.mount"); then
	t_eq "the /var RAM store is a tmpfs" "$(img_ini_value "$content" Type)" tmpfs
	t_eq "the /var RAM store mounts at ${EXPECT_VAR_UPPER_MOUNT}" \
		"$(img_ini_value "$content" Where)" "$EXPECT_VAR_UPPER_MOUNT"
else
	t_fail "run-brenn-var.mount is installed"
fi

t_eq "the overlay directories are created before /var is mounted" \
	"$(img_ext4_type "$IMG_SPEC" "${units}/brenn-var-prepare.service")" regular

if content=$(img_ext4_cat "$IMG_SPEC" "${units}/var.mount"); then
	t_eq "/var is an overlay" "$(img_ini_value "$content" Type)" overlay
	options=$(img_ini_value "$content" Options)
	for want in \
		"lowerdir=${EXPECT_VAR_LOWERDIR}" \
		"upperdir=${EXPECT_VAR_UPPERDIR}" \
		"workdir=${EXPECT_VAR_WORKDIR}"; do
		if printf '%s' "$options" | tr ',' '\n' | grep -qxF -- "$want"; then
			t_pass "the /var overlay sets ${want}"
		else
			t_fail "the /var overlay sets ${want}" "options: ${options}"
		fi
	done
else
	t_fail "var.mount is installed"
fi

# A mount unit nothing pulls in never runs, and /var not being mounted is not
# loud on a read-only root — it just fails everything downstream.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/local-fs.target.wants/var.mount"); then
	t_eq "/var is mounted as part of local-fs.target" "$link" ../var.mount
else
	t_fail "var.mount is wanted by local-fs.target" "no link in local-fs.target.wants"
fi

# The lower half of the overlay is a real filesystem, not an empty directory.
# The dpkg database standing in for it is deliberate: if that is readable the
# copy was taken after the packages were installed.
t_eq "the baked /var carries the package database" \
	"$(img_ext4_type "$IMG_SPEC" "${EXPECT_VAR_LOWERDIR}/lib/dpkg/status")" regular

# And it carries no journal directory. journald reads the existence of one as the
# instruction to store logs on the flash, so the systemd package's empty
# directory is removed from the copy at build time; an existing directory is a
# standing invitation for a later configuration change to persist logs without
# anything saying so. Asserted here as well as on a device because the condition
# is fully visible in the image, and a dropped or reordered removal should not
# have to wait for a build, a flash and a boot to be heard about.
#
# The directory holding it is read first, because the reader answers a path it
# cannot see and a path that is not there with the same empty string: without
# something present to bracket it, a copy that moved would leave the absence
# below asserting nothing and passing forever.
t_eq "the factory copy keeps the directory the journal would go in" \
	"$(img_ext4_type "$IMG_SPEC" "${EXPECT_VAR_LOWERDIR}/log")" directory
t_eq "and no directory journald would read as permission to persist logs" \
	"$(img_ext4_type "$IMG_SPEC" "${EXPECT_VAR_LOWERDIR}/log/journal")" ""

# And /var in the root filesystem itself is the empty skeleton the layout
# leaves behind, so nothing is being read from underneath the overlay.
if entries=$(img_ext4_ls "$IMG_SPEC" /var); then
	t_eq "/var in the image is only the mount-point skeleton" \
		"$(printf '%s\n' "$entries" | sort | tr '\n' ' ' | sed 's/ *$//')" \
		"$EXPECT_VAR_SKELETON"
else
	t_fail "read /var from the root filesystem"
fi

# The generated fstab, whole. The drop-ins below neutralise the three entries in
# it that would put state on flash, but a list of known-bad units only defends
# against those three coming back: a fourth entry from a builder bump would
# mount something writable and pass every other assertion here. Comparing the
# entry set turns the drop-ins into a closed statement about what was generated.
if content=$(img_ext4_cat "$IMG_SPEC" /etc/fstab); then
	entries=$(printf '%s\n' "$content" |
		sed -e 's/#.*//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' |
		awk 'NF >= 4 { print $1, $2, $3, $4 }')
	t_eq_text "the generated fstab is exactly the expected entry set" \
		"$entries" "$EXPECT_FSTAB_ENTRIES"

	# Stated separately because it is the invariant, not a detail of the set:
	# the root filesystem is mounted read-only, and an image whose fstab says
	# otherwise is a different product.
	root_options=$(printf '%s\n' "$entries" | awk '$2 == "/" { print $4 }')
	if printf '%s' "$root_options" | tr ',' '\n' | grep -qx ro; then
		t_pass "fstab mounts the root filesystem read-only"
	else
		t_fail "fstab mounts the root filesystem read-only" \
			"root options: ${root_options:-<no entry for />}"
	fi
else
	t_fail "read /etc/fstab from the root filesystem"
fi

# The three mount units generated from those entries, held back. Each carries a
# drop-in with a condition no device meets, which is how a unit generated from
# fstab during image assembly is told never to run. Masking them — the obvious
# instrument — must not be used, and the brenn-state layer's state.yaml carries
# why: it costs the whole local-fs.target start job, silently.
#
# So the drop-in is asserted for, and the unit path itself is asserted to be
# empty. Nothing may sit there: a /dev/null symlink is the mask, and a regular
# file or directory shadows the generated unit outright — /etc outranks the
# generator's directory, so an inline unit would replace the [Mount] section
# these drop-ins are written against and the drop-in assertion above would still
# pass.
for unit in $EXPECT_NEUTRALIZED_MOUNT_UNITS; do
	dropin="${units}/${unit}.d/${EXPECT_NEVER_MOUNT_DROPIN}"
	if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
		t_eq "${unit} is held back by a condition it cannot meet" \
			"$(img_ini_value "$content" ConditionPathExists)" \
			"$EXPECT_NEVER_MOUNT_CONDITION"
	else
		t_fail "${unit} is held back by a condition it cannot meet" \
			"no drop-in at ${dropin}"
	fi

	# ...which is only true while nothing on the image is at that path. The
	# condition is met by the file existing, so a layer that creates it — a
	# brenn configuration directory with an unlucky name, a rename left half
	# done — starts all three of these mounts instead of holding them back, and
	# every other assertion here stays true. Read inside this loop so the drop-in
	# above stands as the evidence that the reader can see this image at all.
	t_eq "and nothing on the image meets ${unit}'s condition" \
		"$(img_ext4_type "$IMG_SPEC" "$EXPECT_NEVER_MOUNT_CONDITION")" ""

	shadow=$(img_ext4_type "$IMG_SPEC" "${units}/${unit}")
	if [ -z "$shadow" ]; then
		t_pass "and nothing shadows the generated ${unit}"
	else
		detail="${units}/${unit} is a ${shadow}"
		if [ "$shadow" = symlink ]; then
			detail="${detail} to $(img_ext4_link "$IMG_SPEC" "${units}/${unit}")"
		fi
		t_fail "and nothing shadows the generated ${unit}" "$detail"
	fi
done

t_done
