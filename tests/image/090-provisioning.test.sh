#!/usr/bin/env bash
#
# Where site configuration comes from, and how early it is settled.
#
# The image is generic: it carries no credentials, no keys, no endpoints and no
# identity. All of that arrives as a provisioning generation on the writable
# partition, and one generation is selected per boot and published at a single
# runtime path. Two things have to hold for that to be a transaction rather
# than a set of files: the selection happens before anything reads its result,
# and no service reaches past it into the partition.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system
select_unit="${units}/${EXPECT_SELECT_UNIT}"

# The selector and the unit that runs it.
t_eq "the generation selector is installed" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_SELECT_EXEC")" regular
t_eq "the generation selector is executable" \
	"$(img_ext4_mode "$IMG_SPEC" "$EXPECT_SELECT_EXEC")" 755

# The contract check and the write, which the device applies to every
# configuration change made after the first. They are the same programs the
# flash-time tool runs, so an image without them is a device that would take a
# generation the bench refused, or write one the bench would not have.
for prog in "$EXPECT_VALIDATE_EXEC" "$EXPECT_INSTALL_EXEC"; do
	t_eq "${prog} is installed" "$(img_ext4_type "$IMG_SPEC" "$prog")" regular
	t_eq "${prog} is executable" "$(img_ext4_mode "$IMG_SPEC" "$prog")" 755
done

# And the contract they both read. It is sourced rather than run, so it is not
# executable — and every program that touches a generation fails without it,
# which is why its absence is asserted here rather than discovered at a boot.
t_eq "the contract itself is installed" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_CONFIG_LIB")" regular
t_eq "the contract is data, not a program" \
	"$(img_ext4_mode "$IMG_SPEC" "$EXPECT_CONFIG_LIB")" 644

if unit=$(img_ext4_cat "$IMG_SPEC" "$select_unit"); then
	t_eq "the selector runs from its unit" \
		"$(img_ini_value "$unit" ExecStart)" "$EXPECT_SELECT_EXEC"

	# Ordering is the load-bearing part. Selection has to be finished before
	# the journal opens (it files entries under the provisioned machine id)
	# and before every consumer of a provisioned file.
	after=$(img_ini_values "$unit" After | tr ' ' '\n')
	for want in $EXPECT_SELECT_AFTER; do
		t_contains "selection waits for ${want}" "$after" "$want"
	done

	before=$(img_ini_values "$unit" Before | tr ' ' '\n')
	for want in $EXPECT_SELECT_BEFORE; do
		t_contains "selection is settled before ${want}" "$before" "$want"
	done

	# A passive target is in the boot only if something asks for it, and an
	# ordering against a unit that is not in the boot orders nothing. The
	# Before= above is therefore only half of the edge to the network stack.
	wants=$(img_ini_values "$unit" Wants | tr ' ' '\n')
	for want in $EXPECT_SELECT_WANTS; do
		t_contains "selection pulls in ${want}" "$wants" "$want"
	done
else
	t_fail "${EXPECT_SELECT_UNIT} is installed"
fi

# A unit nothing pulls in never runs, and this one failing to run means every
# service that needs configuration finds none.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/sysinit.target.wants/${EXPECT_SELECT_UNIT}"); then
	t_eq "selection is wanted by sysinit.target" "$link" "../${EXPECT_SELECT_UNIT}"
else
	t_fail "selection is wanted by sysinit.target" "no link in sysinit.target.wants"
fi

# The A/B layout syncs a machine id to and from the writable partition, which
# both loses the provisioned identity and writes to flash. Its unit is created
# during image assembly, so it is emptied out rather than removed.
#
# The whole value list is compared, not its head: an empty first ExecStart= is
# also what a drop-in that lost its [Service] section altogether looks like, and
# that one leaves the layout's sync running.
dropin="${units}/machine-id-sync.service.d/10-brenn-provisioned.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	t_eq_text "the layout's machine-id sync is reset and replaced" \
		"$(img_ini_values "$content" ExecStart)" "$EXPECT_MACHINE_ID_SYNC_EXEC"
else
	t_fail "the layout's machine-id sync is overridden" "no drop-in at ${dropin}"
fi

# The provisioned id is written to /run/machine-id, and that is the id the
# system reads only because init has bind-mounted a transient one over
# /etc/machine-id — which it does only for an image whose /etc/machine-id is
# absent, empty, or the literal "uninitialized". Bake a real id into the image
# and the write lands in a file nothing reads, silently, with the whole fleet
# then sharing one identity in the collector's index.
if img_ext4_exists "$IMG_SPEC" /etc/machine-id; then
	case "$(img_ext4_cat "$IMG_SPEC" /etc/machine-id | tr -d '[:space:]')" in
		"" | uninitialized)
			t_pass "the image carries no machine id of its own"
			;;
		*)
			t_fail "the image carries no machine id of its own" \
				"/etc/machine-id holds a value, so no transient id is mounted over it"
			;;
	esac
else
	t_pass "the image carries no machine id of its own"
fi

# The same identity, by its other name. The baked /var is a copy of a configured
# /var, and the copy is taken after the packages that write an id there have been
# configured, so the legacy path has to be turned back into a reference.
dbus_id="${EXPECT_VAR_LOWERDIR}/lib/dbus/machine-id"
if img_ext4_exists "$IMG_SPEC" "$dbus_id"; then
	t_eq "the baked /var holds no identity of its own" \
		"$(img_ext4_type "$IMG_SPEC" "$dbus_id")" symlink
	t_eq "it defers to the one place an id is resolved from" \
		"$(img_ext4_link "$IMG_SPEC" "$dbus_id")" /etc/machine-id
else
	t_pass "the baked /var holds no identity of its own"
fi

# Nothing may read the store directly: a service that did would pick up
# whichever generation was committed at the moment it looked, which is exactly
# what the published path exists to prevent.
#
# One sweep over every directory this image writes configuration into, driven
# from a list, rather than a check in each test over the directory that test
# happened to care about — a sampled sweep only defends the places somebody
# thought to name, and a new consumer lands wherever it lands. The selector
# itself is the one thing allowed to name the store, and it is not swept.
offenders=""
for entry in $EXPECT_STORE_SWEEP_DIRS; do
	dir=${entry%:*}
	depth=${entry##*:}
	img_ext4_exists "$IMG_SPEC" "$dir" || continue
	found=$(img_sweep_for_string "$dir" "$EXPECT_PROVISIONING_STORE" "$depth")
	[ -z "$found" ] || offenders="${offenders}${found}"$'\n'
done

if [ -z "${offenders//[$'\n' ]/}" ]; then
	t_pass "nothing in the image reads ${EXPECT_PROVISIONING_STORE} directly"
else
	t_fail "nothing in the image reads ${EXPECT_PROVISIONING_STORE} directly" \
		"files naming it: $(printf '%s' "$offenders" | tr '\n' ' ')"
fi

# The published path is the contract every later consumer is held to, so it is
# asserted here rather than left implicit in the selector.
if content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_SELECT_EXEC"); then
	if printf '%s' "$content" | grep -qF "$EXPECT_PROVISIONING_LINK"; then
		t_pass "the selection is published at ${EXPECT_PROVISIONING_LINK}"
	else
		t_fail "the selection is published at ${EXPECT_PROVISIONING_LINK}" \
			"the selector does not name that path"
	fi
else
	t_fail "read the generation selector"
fi

# And the image ships none of it. Provisioning data in an image is an image
# that belongs to one device.
for path in /persistent/provisioning /run/brenn; do
	if img_ext4_exists "$IMG_SPEC" "$path"; then
		t_fail "the image ships nothing at ${path}" "found in the root filesystem"
	else
		t_pass "the image ships nothing at ${path}"
	fi
done

t_done
