#!/usr/bin/env bash
#
# The clock, and the thing that resets a device nobody can reach.
#
# The clock matters because there is no battery: a device that has just been
# powered on believes it is 1970, and every certificate it is shown is either
# not valid yet or expired. So the time client is wired to the provisioning
# generation — a site with a local time server names it there — a pinned floor
# raises a cold clock before the client starts, and everything that opens a TLS
# connection is ordered after the clock is set.
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

# The boot-clock floor. A unit with no battery boots at the image's epoch, which
# is earlier than a public certificate's notBefore; the floor raises it before
# the time client starts. The date is the pin file's content, because content is
# the one thing the ext4 build does not clamp: every file mtime later than
# SOURCE_DATE_EPOCH is lowered to it. So the built image's pin is held to the
# shipped one byte for byte, and what that content means — the floor the script
# reads out of it — is the host lane's question (tests/host/027-clock-floor).
pin_src="${BRENN_REPO_ROOT}/image/layer/brenn/time.rootfs-overlay${EXPECT_CLOCK_FLOOR_FILE}"
t_eq "the clock floor is pinned in the image" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_CLOCK_FLOOR_FILE")" regular
if content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_CLOCK_FLOOR_FILE"); then
	t_eq "the image carries the shipped pin unchanged" "$content" "$(cat "$pin_src")"
else
	t_fail "the image carries the shipped pin unchanged" \
		"nothing at ${EXPECT_CLOCK_FLOOR_FILE}"
fi

t_eq "the program that applies the floor is installed" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_CLOCK_FLOOR_EXEC")" regular
t_eq "and is executable" \
	"$(img_ext4_mode "$IMG_SPEC" "$EXPECT_CLOCK_FLOOR_EXEC")" 755

# Ahead of the time client, so the client's own step to its recorded timestamp
# finds the clock already past it, and ahead of sysinit.target, which every TLS
# consumer on the image is ordered after — and so without the default
# dependencies, which would order it after the targets it has to precede.
if content=$(img_ext4_cat "$IMG_SPEC" "${units}/${EXPECT_CLOCK_FLOOR_UNIT}"); then
	t_eq "the floor unit runs the floor program" \
		"$(img_ini_value "$content" ExecStart)" "$EXPECT_CLOCK_FLOOR_EXEC"
	before=$(img_ini_values "$content" Before | tr ' ' '\n')
	for want in $EXPECT_CLOCK_FLOOR_BEFORE; do
		t_contains "the floor is applied before ${want}" "$before" "$want"
	done
	t_eq "the floor unit runs ahead of the default dependencies" \
		"$(img_ini_value "$content" DefaultDependencies)" no
else
	t_fail "the floor unit is installed" "nothing at ${units}/${EXPECT_CLOCK_FLOOR_UNIT}"
fi

# A guard on the trap the floor was built around. systemd would take the mtime
# of /usr/lib/clock-epoch as its boot epoch, but a file whose mtime is the floor
# is a file whose mtime is SOURCE_DATE_EPOCH once mke2fs has copied it in — so
# its presence means someone has reached for a timestamp again, and the floor it
# was meant to carry is silently the epoch.
if img_ext4_exists "$IMG_SPEC" /usr/lib/clock-epoch; then
	t_fail "no boot epoch is carried as a file timestamp" \
		"found /usr/lib/clock-epoch; its mtime is clamped to SOURCE_DATE_EPOCH"
else
	t_pass "no boot epoch is carried as a file timestamp"
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
