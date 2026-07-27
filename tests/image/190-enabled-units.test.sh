#!/usr/bin/env bash
#
# What the image was configured to start on its own.
#
# The rest of the suite asserts that the units it knows about are wanted, which
# is an assertion about the units somebody thought to name. What arrives
# alongside them is the problem: a package's systemd preset enables its units
# when it is installed, so a layer bump or a new dependency can put a service on
# every boot with nothing in this repository asking for it — an updater that
# rewrites flash, a timer that runs a package manager, a job writing into a /var
# that is RAM.
#
# So the enabled set is read whole and compared against a reviewed list. A unit
# appearing is a finding, and so is one vanishing: the links are how this image
# starts its own services too, and a layer that stopped shipping one would
# otherwise leave a device that boots to nothing in particular.
#
# The set read is the one under /etc/systemd/system, which is where enablement
# by preset lands and therefore where installing a package can change what boots.
# It is not everything that starts: a package may also ship a static .wants link
# in /usr/lib/systemd/system, and this image carries about fifty of them from the
# Debian base. Those are part of the packaging rather than of what was enabled
# here, and reviewing them is TODO(vendor-enabled-units).

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

dir=$EXPECT_ENABLED_UNITS_DIR

if ! enabled=$(img_enabled_units "$IMG_SPEC" "$dir"); then
	t_fail "the image enables exactly the units this profile declares" \
		"no ${dir} in the image"
	t_done
fi

t_eq_text "the image enables exactly the units this profile declares" \
	"$(printf '%s\n' "$enabled" | sort)" \
	"$(printf '%s\n' "$EXPECT_ENABLED_UNITS" | sort)"

# A link is only an enablement if it resolves to a unit. Read from the observed
# listing rather than from the expectation, so that a file arriving from
# somewhere else is examined as well — the assertion above is what says there
# should not be one, this is what says whether it would have started anything.
while IFS= read -r entry; do
	[ -n "$entry" ] || continue
	path="${dir}/${entry}"
	if ! target=$(img_ext4_link "$IMG_SPEC" "$path"); then
		t_fail "${entry} is a link to a unit" "not a symlink"
		continue
	fi

	# Relative targets point at a sibling of the .wants directory, which is
	# this directory; absolute ones at the packaged unit.
	case "$target" in
		/*) resolved=$target ;;
		*) resolved="${dir}/${target#*/}" ;;
	esac

	if [ "$(img_ext4_type "$IMG_SPEC" "$resolved")" = regular ]; then
		t_pass "${entry} resolves to a unit file"
	else
		t_fail "${entry} resolves to a unit file" "dangling: ${target}"
	fi
done <<<"$enabled"

t_done
