#!/usr/bin/env bash
#
# How the device gets on a network, and what it needs from outside itself to
# do it.
#
# Two things are being defended here. The first is that the image contains no
# network identity at all: no name, no passphrase, no country. The supplicant
# is pointed at a provisioned file and conditioned on it, so an image is the
# same image everywhere and an unconfigured device is quietly offline rather
# than guessing. The second is that the generic configuration the device layer
# generates has actually been replaced — it makes every link required, which
# on a device with one cable and one radio means waiting out a timeout on
# every boot.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system
networkdir=/etc/systemd/network

# Both links: an address by DHCP, and either of them counts as being online.
# RequiredForOnline is the tell that these are our files and not the generated
# ones, which carry no [Link] section.
for file in $EXPECT_LINK_FILES; do
	link=${file#*-}
	link=${link%.network}
	if content=$(img_ext4_cat "$IMG_SPEC" "${networkdir}/${file}"); then
		t_eq "${file} configures ${link}" "$(img_ini_value "$content" Name)" "$link"
		t_eq "${link} takes an address by DHCP" "$(img_ini_value "$content" DHCP)" yes
		t_eq "${link} counts towards being online" \
			"$(img_ini_value "$content" RequiredForOnline)" yes
	else
		t_fail "${link} is configured" "no ${networkdir}/${file}"
	fi
done

# ...and one of them is enough. The default is every managed link, so this is
# an override, and an override that silently stopped applying would cost a
# minute and a half of every boot.
dropin="${units}/systemd-networkd-wait-online.service.d/10-brenn-any.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	execs=$(img_ini_values "$content" ExecStart)
	t_eq "the packaged wait-online command line is discarded" \
		"$(printf '%s\n' "$execs" | head -n1)" ""
	cmd=$(printf '%s\n' "$execs" | tail -n1)
	case "$cmd" in
		"${EXPECT_WAIT_ONLINE_BIN} "*"${EXPECT_WAIT_ONLINE_ARG}"*)
			t_pass "any link online is online"
			;;
		*)
			t_fail "any link online is online" \
				"expected: ${EXPECT_WAIT_ONLINE_BIN} … ${EXPECT_WAIT_ONLINE_ARG}" \
				"actual:   ${cmd}"
			;;
	esac
else
	t_fail "any link online is online" "no drop-in at ${dropin}"
fi

t_eq "the wait-online program is installed at the path the drop-in names" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_WAIT_ONLINE_BIN")" regular

# The supplicant. Its entire configuration — network name, passphrase,
# regulatory domain — is one provisioned file, and the unit is conditioned on
# that file so an unprovisioned device comes up without wireless instead of
# failing a service.
dropin="${units}/${EXPECT_SUPPLICANT_UNIT}.d/10-brenn-provisioned.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	execs=$(img_ini_values "$content" ExecStart)
	t_eq "the packaged supplicant command line is discarded" \
		"$(printf '%s\n' "$execs" | head -n1)" ""
	cmd=$(printf '%s\n' "$execs" | tail -n1)
	case "$cmd" in
		"${EXPECT_SUPPLICANT_BIN} "*"${EXPECT_SUPPLICANT_CONF}"*)
			t_pass "the supplicant reads the provisioned configuration"
			;;
		*)
			t_fail "the supplicant reads the provisioned configuration" \
				"expected: ${EXPECT_SUPPLICANT_BIN} … ${EXPECT_SUPPLICANT_CONF}" \
				"actual:   ${cmd}"
			;;
	esac

	t_eq "no configuration means no supplicant" \
		"$(img_ini_value "$content" ConditionPathExists)" "$EXPECT_SUPPLICANT_CONF"
	t_contains "the supplicant waits for the generation to be selected" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_SELECT_UNIT"
	t_eq "a supplicant that exits is started again" \
		"$(img_ini_value "$content" Restart)" always
	t_eq "and is never given up on" \
		"$(img_ini_value "$content" StartLimitIntervalSec)" 0
else
	t_fail "the supplicant is configured" "no drop-in at ${dropin}"
fi

t_eq "the supplicant program is installed at the path the drop-in names" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_SUPPLICANT_BIN")" regular
t_eq "the supplicant template unit the instance comes from is installed" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_SUPPLICANT_TEMPLATE")" regular

# One supplicant, on the interface this device has. The packaged system-wide
# service would start a second one with no configuration and no interface.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_SUPPLICANT_UNIT}"); then
	t_eq "the supplicant instance for the onboard radio is enabled" \
		"$link" "$EXPECT_SUPPLICANT_TEMPLATE"
else
	t_fail "the supplicant instance for the onboard radio is enabled" \
		"no link in multi-user.target.wants"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/${EXPECT_SUPPLICANT_MASKED}"); then
	t_eq "the packaged system-wide supplicant is masked" "$link" /dev/null
else
	t_fail "the packaged system-wide supplicant is masked" \
		"nothing at ${units}/${EXPECT_SUPPLICANT_MASKED}"
fi

# The resolver answers nothing. Both of these open a listener on every link,
# and sshd is meant to be the only listener on the device.
dropin=/etc/systemd/resolved.conf.d/10-brenn-quiet.conf
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	t_eq "link-local name resolution is off" "$(img_ini_value "$content" LLMNR)" no
	t_eq "multicast DNS is off" "$(img_ini_value "$content" MulticastDNS)" no
else
	t_fail "the resolver answers no queries" "no drop-in at ${dropin}"
fi

# Wireless needs the regulatory database installed, and needs no country baked
# into the image: which one applies is a property of where the device is.
if installed=$(img_installed_packages "$IMG_SPEC"); then
	for pkg in $EXPECT_NET_PACKAGES; do
		if printf '%s\n' "$installed" | grep -q "^${pkg} "; then
			t_pass "${pkg} is installed"
		else
			t_fail "${pkg} is installed" "not in the package database"
		fi
	done
else
	t_fail "read the package database"
fi

if img_ext4_exists "$IMG_SPEC" "$EXPECT_REGDOM_ABSENT"; then
	t_fail "no regulatory domain is baked into the image" \
		"found ${EXPECT_REGDOM_ABSENT}"
else
	t_pass "no regulatory domain is baked into the image"
fi

t_done
