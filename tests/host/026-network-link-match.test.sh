#!/usr/bin/env bash
#
# Which link names the image's two .network files claim.
#
# The wired file matches a class of link, not one name: the onboard port and a
# USB Ethernet adapter both get it, under whatever name the kernel chooses. The
# kernel's choice is not something this lane can produce, so what is exercised
# is the pattern: each representative name is put to the file's `Name=` globs
# with the shell's own `case`, which is the shell-style globbing
# systemd.network(5) specifies for that key. A name no glob covers is a link
# networkd leaves unmanaged — no address, no route, no time server.
#
# The names are representatives, not readings: eth<N> is what the image names
# an Ethernet-class device while it masks the .link files that would rename it,
# enx<MAC> is predictable naming if those masks go, and usb0 is a driver that
# names itself.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

networkdir="${BRENN_REPO_ROOT}/image/layer/brenn/net.rootfs-overlay/etc/systemd/network"
wired="${networkdir}/01-wired.network"
wlan="${networkdir}/02-wlan0.network"

# Whether any of the space-separated globs in $1 matches the name $2. The
# glob is deliberately unquoted inside `case`: that is what makes it a pattern.
glob_matches() {
	local globs=$1 name=$2 glob
	local -a list
	read -r -a list <<<"$globs"
	for glob in "${list[@]}"; do
		# shellcheck disable=SC2254  # the pattern is the point
		case $name in
			$glob) return 0 ;;
		esac
	done
	return 1
}

for f in "$wired" "$wlan"; do
	if [ ! -f "$f" ]; then
		t_fail "the link file exists" "nothing at ${f}"
		t_done
	fi
done

# Every `Name=` in [Match], merged the way networkd merges them.
wired_globs=$(img_ini_section_list "$(cat "$wired")" Match Name)
wlan_globs=$(img_ini_section_list "$(cat "$wlan")" Match Name)

if [ -z "$wired_globs" ]; then
	t_fail "the wired file names the links it matches" "no Name= in [Match] of ${wired}"
fi
if [ -z "$wlan_globs" ]; then
	t_fail "the wireless file names the link it matches" "no Name= in [Match] of ${wlan}"
fi

for name in eth0 eth1 enx0123456789ab usb0; do
	if glob_matches "$wired_globs" "$name"; then
		t_pass "the wired file manages ${name}"
	else
		t_fail "the wired file manages ${name}" "Name=${wired_globs}"
	fi
	if glob_matches "$wlan_globs" "$name"; then
		t_fail "the wireless file leaves ${name} alone" "Name=${wlan_globs}"
	else
		t_pass "the wireless file leaves ${name} alone"
	fi
done

# The radio and the loopback are not wired links. A wired glob that caught the
# radio would put two policies on one link, and one that caught the loopback
# would have networkd running DHCP on it.
for name in wlan0 lo; do
	if glob_matches "$wired_globs" "$name"; then
		t_fail "the wired file leaves ${name} alone" "Name=${wired_globs}"
	else
		t_pass "the wired file leaves ${name} alone"
	fi
done

if glob_matches "$wlan_globs" wlan0; then
	t_pass "the wireless file manages wlan0"
else
	t_fail "the wireless file manages wlan0" "Name=${wlan_globs}"
fi

# The matcher itself, against patterns whose answer is known, so that a
# helper that matched everything or nothing cannot pass the cases above.
if glob_matches "eth*" lo; then
	t_fail "the matcher refuses a name no glob covers" "eth* matched lo"
else
	t_pass "the matcher refuses a name no glob covers"
fi
if glob_matches "wlan0 usb*" usb3; then
	t_pass "the matcher tries every glob in the list"
else
	t_fail "the matcher tries every glob in the list" "wlan0 usb* did not match usb3"
fi

t_done
