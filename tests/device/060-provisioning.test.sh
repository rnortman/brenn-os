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
# link here is a device that stops answering after a reboot. The update keyring
# is here too: a device that can verify no bundle can only be changed by being
# taken apart.
for f in ssh/ssh_host_ed25519_key ssh/authorized_keys rauc/keyring.pem; do
	dev_exists "the generation provides ${f}" "${link}/${f}"
done

# The HTTPS trust anchor, which is required exactly when something on this device
# makes an HTTPS connection — the mirror, on a running device, of the check the
# contract makes on a candidate. The image carries no distribution certificate
# store, so an endpoint provisioned without the anchor is an endpoint that can
# never be reached.
dev_capture "if test -e $(dev_quote "${link}/journal/upload.conf") ||
	test -e $(dev_quote "${link}/app/fetch.conf"); then echo consumed; else echo unused; fi"
anchor_use=$DEV_OUT

case $anchor_use in
	consumed)
		dev_exists "an HTTPS endpoint is provisioned, so the generation provides ca/brenn-ca.pem" \
			"${link}/ca/brenn-ca.pem"
		;;
	unused)
		# Not asserted absent: an anchor staged ahead of the endpoint that will
		# use it is a legitimate generation, and refusing it here would make the
		# suite stricter than the contract. What is asserted is that the reading
		# was taken and said so.
		t_pass "no HTTPS endpoint is provisioned, so the trust anchor is optional on this device"
		;;
	*)
		t_fail "whether anything consumes the trust anchor can be read" \
			"expected consumed or unused" "read: ${anchor_use:-<nothing>}"
		;;
esac

# What sshd resolved, not what the configuration file says: the image suite
# reads the files, and this reads the daemon's own answer.
expected_hostkey=$(printf '%s\n' "$EXPECT_SSHD_SETTINGS" |
	awk -F= '$1 == "HostKey" { print $2 }')
dev_eq "sshd offers the provisioned host key" \
	"sshd -T | awk '\$1 == \"hostkey\" { print \$2 }'" \
	"$expected_hostkey"

t_done
