#!/usr/bin/env bash
#
# The clock, and the thing that resets a device nobody can reach.
#
# The clock matters because there is no battery: a device that has just been
# powered on believes it is 1970, and every certificate it is shown is either
# not valid yet or expired. So the time client is wired to the provisioning
# generation — a site with a local time server names it there — and everything
# that opens a TLS connection is ordered after the clock is set.
#
# The watchdog matters because a hang has to become a reset. It is what turns
# "the update boots but wedges" into "the previous system is running again",
# and nothing in the update path works without it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system
confdir=$(dirname "$EXPECT_NTP_DROPIN")

# The provisioned time configuration is reached through a link into the
# published path, so it follows whichever generation this boot selected, and
# resolves to nothing at all on a device that was never given one.
t_eq "the provisioned time configuration is a drop-in" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_NTP_DROPIN")" symlink
if target=$(img_ext4_link "$IMG_SPEC" "$EXPECT_NTP_DROPIN"); then
	t_eq "it reads the selected generation" "$target" "$EXPECT_NTP_SOURCE"
else
	t_fail "the provisioned time configuration is a link into the generation" \
		"nothing at ${EXPECT_NTP_DROPIN}"
fi

# No time server is named by the image. Naming one would be site configuration
# baked into a generic artefact, and it would also take precedence over the
# provisioned one, which is the opposite of the intent.
baked=""
check_no_ntp() {
	local path=$1 content
	content=$(img_ext4_cat "$IMG_SPEC" "$path") || return 0
	if printf '%s\n' "$content" | grep -Eq '^[[:space:]]*NTP='; then
		baked="${baked} ${path}"
	fi
}

check_no_ntp "$EXPECT_TIMESYNCD_CONF"
while IFS= read -r name; do
	[ "${confdir}/${name}" = "$EXPECT_NTP_DROPIN" ] && continue
	check_no_ntp "${confdir}/${name}"
done < <(img_ext4_ls "$IMG_SPEC" "$confdir")

if [ -z "$baked" ]; then
	t_pass "the image names no time server of its own"
else
	t_fail "the image names no time server of its own" "NTP= in:${baked}"
fi

# Both the time client and the generation selector run before sysinit.target,
# where nothing orders them relative to each other. The client reads its
# configuration once, at start, so the order is the whole point.
dropin="${units}/systemd-timesyncd.service.d/10-brenn-provisioned.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	t_contains "the clock starts after the generation is selected" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_SELECT_UNIT"
else
	t_fail "the clock starts after the generation is selected" \
		"no drop-in at ${dropin}"
fi

# The watchdog. Off by default, and its absence is invisible until the day a
# device hangs and stays hung.
if content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_WATCHDOG_DROPIN"); then
	t_eq "the hardware watchdog is armed" \
		"$(img_ini_value "$content" RuntimeWatchdogSec)" "$EXPECT_WATCHDOG_RUNTIME"
	t_eq "and keeps counting across a reboot" \
		"$(img_ini_value "$content" RebootWatchdogSec)" "$EXPECT_WATCHDOG_REBOOT"
else
	t_fail "the hardware watchdog is armed" "no drop-in at ${EXPECT_WATCHDOG_DROPIN}"
fi

t_done
