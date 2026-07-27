#!/usr/bin/env bash
#
# The device is running the configuration it was provisioned with.
#
# Every unit-specific thing about this device — its name, its identity, the
# credentials it uses and the ones it accepts — comes from one generation
# directory chosen at boot and published at a single path. The image suite
# asserts that every consumer reads that path. This asserts the other half: on
# a running device the path resolves to a committed generation, and the two
# identity values that must survive a reflash came out of it rather than being
# invented at first boot.
#
# The degraded case — no provisioning at all — is deliberately not here: it is
# a property of the unit conditions, which the image suite reads directly.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

link=$EXPECT_PROVISIONING_LINK
store=$EXPECT_PROVISIONING_STORE

dev_eq "the generation selector ran and succeeded" \
	"systemctl show -p Result --value $(dev_quote "$EXPECT_SELECT_UNIT")" \
	"$EXPECT_SELECT_RESULT"

dev_capture "readlink -f $(dev_quote "$link")"
selected=$DEV_OUT
if [ "${selected#"$EXPECT_GENERATION_PREFIX"}" != "$selected" ]; then
	t_pass "the published selection is a generation in the store (${selected})"
else
	t_fail "the published selection is a generation in the store" \
		"expected a path under ${EXPECT_GENERATION_PREFIX}" \
		"resolved: ${selected:-<nothing>}"
fi

# A committed generation, not one on trial. An operator running this suite
# during a configuration trial gets told so rather than getting assertions
# about a configuration that may be gone in ten minutes.
dev_eq "the selection is the committed generation" \
	"readlink -f $(dev_quote "${store}/active")" "$selected"
dev_absent "no configuration change is on trial" "${store}/trial"
dev_absent "this boot is not running a candidate" "$EXPECT_CONFIG_TRIAL_FLAG"

# Identity. Both of these are what a fleet uses to tell one device from
# another; both are generated on the fly by a stock Debian, and a device that
# did so has lost the identity that a reflash is supposed to preserve.
dev_eq "the machine id is the provisioned one" \
	"cmp -s /etc/machine-id $(dev_quote "${link}/machine-id") && echo same" same
dev_eq "the host name is the provisioned one" \
	"test \"\$(hostname)\" = \"\$(cat $(dev_quote "${link}/hostname"))\" && echo same" same

# The credentials the generation carries, in place and readable through the
# published path. sshd resolves its host key through this path, so a broken
# link here is a device that stops answering after a reboot.
for f in ssh/ssh_host_ed25519_key ssh/authorized_keys ca/brenn-ca.pem rauc/keyring.pem; do
	dev_exists "the generation provides ${f}" "${link}/${f}"
done

# What sshd resolved, not what the configuration file says: the image suite
# reads the files, and this reads the daemon's own answer.
expected_hostkey=$(printf '%s\n' "$EXPECT_SSHD_SETTINGS" |
	awk -F= '$1 == "HostKey" { print $2 }')
dev_eq "sshd offers the provisioned host key" \
	"sshd -T | awk '\$1 == \"hostkey\" { print \$2 }'" \
	"$expected_hostkey"

t_done
