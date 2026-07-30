#!/usr/bin/env bash
#
# The unit is there, it is ours, and it came up clean.
#
# This is the one test in the suite that fails rather than skips when the
# device cannot be reached: reachability is its subject. Everything after it
# skips instead, so a powered-off unit produces one diagnosis rather than a
# screenful of consequences.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_load_expectations
dev_load_target

if ! dev_run true >/dev/null 2>&1; then
	t_fail "the unit answers SSH" \
		"target: ${DEV_USER}@${DEV_HOST}" \
		"nothing else in this suite can run until it does"
	t_done
fi
t_pass "the unit answers SSH at ${DEV_USER}@${DEV_HOST}"

# Who we are once in. sshd's AllowUsers admits one account; logging in as
# anything else means the configuration on the device is not ours.
dev_eq "the session runs as ${EXPECT_ADMIN_USER}" 'id -un' "$EXPECT_ADMIN_USER"

# Which system this is. A vendor image left on the eMMC after a failed flash
# answers SSH too.
dev_eq "the architecture is ${EXPECT_ARCH}" 'uname -m' "$EXPECT_ARCH"
# The device's shell is what expands these; the single quotes are what stops
# this one from doing it first.
# shellcheck disable=SC2016
dev_eq "the distribution is ${EXPECT_OS_ID}" \
	'. /etc/os-release && printf %s "$ID"' "$EXPECT_OS_ID"
# shellcheck disable=SC2016
dev_eq "the suite is ${EXPECT_OS_CODENAME}" \
	'. /etc/os-release && printf %s "$VERSION_CODENAME"' "$EXPECT_OS_CODENAME"

# The running kernel against the version the build pinned. The image suite
# asserts the pin was honoured by apt; this asserts the device is running what
# apt installed, which is a different claim — a kernel can be installed and not
# be the one the firmware loaded.
#
# The pin carries an epoch and a Debian revision; what uname reports is the
# upstream version the package was built from plus the vendor's flavour suffix,
# so the pin is reduced to the upstream version and what follows it on the
# device has to start somewhere that is not part of a version number. A plain
# prefix match would accept 6.12.34 for a pin of 6.12.3, which is the reading a
# version bump produces and the last one that should pass.
pinfile="${BRENN_REPO_ROOT}/image/layer/brenn/apt/preferences.rpi-pin"
pinned=$(awk '
	/^Package:/ { want = ($0 ~ /linux-image-/) }
	want && /^Pin: version/ { print $3; exit }
' "$pinfile")
upstream=${pinned#*:}
upstream=${upstream%%-*}

if [ -z "$upstream" ]; then
	t_fail "read the pinned kernel version" "no linux-image pin in ${pinfile}"
else
	dev_capture 'uname -r'
	case "$DEV_OUT" in
		"$upstream" | "$upstream"[!0-9.]*)
			t_pass "the running kernel is the pinned ${upstream} (${DEV_OUT})"
			;;
		*)
			t_fail "the running kernel is the pinned ${upstream}" \
				"uname -r: ${DEV_OUT}"
			;;
	esac
fi

# Nothing failed to start. On an appliance with a fixed unit set this is a
# total assertion rather than a heuristic: any failed unit is either a bug or a
# unit that should not have been enabled.
dev_capture 'systemctl is-system-running'
state=$DEV_OUT
if [ "$state" = "$EXPECT_SYSTEM_STATE" ]; then
	t_pass "the boot completed and nothing failed (${state})"
else
	failed=$(dev_run 'systemctl list-units --state=failed --no-legend --plain' 2>&1)
	t_fail "the boot completed and nothing failed" \
		"state: ${state}" \
		"expected: ${EXPECT_SYSTEM_STATE}" \
		"failed units:" \
		"${failed:-<none reported>}"
fi

# ...which does not cover a target that was never attempted. `running` means no
# unit failed, and a unit pulled in by a Wants whose dependencies cannot be
# assembled is not a failure: systemd drops that whole subtree out of the
# transaction and logs nothing. local-fs.target is pulled in exactly that way and
# everything mounted from fstab hangs off it, so this is the assertion that
# notices a boot in which the firmware partition never mounted and the root never
# took its fstab options — while the device reports a clean start.
dev_eq "and the local filesystem target was reached" \
	"systemctl is-active $(dev_quote "$EXPECT_LOCAL_FS_TARGET")" active

t_done
