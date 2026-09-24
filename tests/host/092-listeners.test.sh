#!/usr/bin/env bash
#
# The listener census, run against synthetic socket tables.
#
# The census is a device test, and most of what it decides is ordinary parsing:
# which UDP rows are a DHCP client and which are held to the fixed set, and
# whether a capture that failed can still pass. Those decisions are exercised
# here by running the real device test against a stub that answers each of its
# commands from a fixture, with the real profile expectations loaded.
#
# Every address below is made up: documentation-range IPv4, synthetic
# link-local IPv6, and representatives of the classes that must not qualify.
# None of it is a reading from a unit. The cases marked as parser checks are
# shapes the host-side recognizer must refuse, not shapes hardware has shown.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

census_test="${BRENN_REPO_ROOT}/tests/device/050-listeners.test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixture="${work}/fixture"
mkdir -p "$fixture"

# The stub answers the four commands the census sends and nothing else: an
# unexpected command is a change to the test this file does not cover yet, and
# says so rather than answering it.
stub="${work}/ssh-stub"
cat >"$stub" <<'STUB'
#!/bin/sh
for a in "$@"; do cmd=$a; done
case $cmd in
	true) exit 0 ;;
	'ss -Hltnp') f=tcp ;;
	'ss -Hlunp') f=udp ;;
	'cat /proc/sys/net/ipv4/ip_local_port_range') f=range ;;
	*)
		echo "stub: unexpected command: ${cmd}" >&2
		exit 99
		;;
esac
cat "${FIXTURE_DIR}/${f}"
if [ -f "${FIXTURE_DIR}/${f}.status" ]; then
	echo "stub: connection closed" >&2
	exit "$(cat "${FIXTURE_DIR}/${f}.status")"
fi
exit 0
STUB
chmod 0755 "$stub"

# An ssh on the path that only records being run, so that the census reaching
# for the real client instead of the stub is a failure here rather than a
# connection attempt.
shim_dir="${work}/bin"
mkdir -p "$shim_dir"
real_ssh_marker="${work}/real-ssh-ran"
cat >"${shim_dir}/ssh" <<SHIM
#!/bin/sh
: >"${real_ssh_marker}"
exit 99
SHIM
chmod 0755 "${shim_dir}/ssh"

conf="${work}/device.conf"
: >"$conf"

# A second repository root whose device expectations are the real ones with
# lines appended, for the cases that need expectations production does not
# carry. Everything else in it is the real file.
alt_root="${work}/root"
mkdir -p "${alt_root}/tests/image" "${alt_root}/tests/device" "${alt_root}/scripts/lib"
ln -s "${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env" \
	"${alt_root}/tests/image/expected-${BRENN_PROFILE}.env"
ln -s "${BRENN_REPO_ROOT}/scripts/lib/overlay-conf.sh" \
	"${alt_root}/scripts/lib/overlay-conf.sh"

# ss rows as the census reads them: state, queues, local, peer, process.
tcp_row() {
	printf 'LISTEN 0 4096 %s %s users:(("%s",pid=100,fd=3))\n' "$1" "${3:-0.0.0.0:*}" "$2"
}
udp_row() {
	if [ "$2" = - ]; then
		printf 'UNCONN 0 0 %s %s\n' "$1" "${3:-0.0.0.0:*}"
	else
		printf 'UNCONN 0 0 %s %s users:(("%s",pid=200,fd=12))\n' "$1" "${3:-0.0.0.0:*}" "$2"
	fi
}

base_tcp() {
	tcp_row 0.0.0.0:22 sshd
	tcp_row '127.0.0.53%lo:53' systemd-resolve
	tcp_row 127.0.0.54:53 systemd-resolve
	tcp_row '[::]:22' sshd '[::]:*'
}

base_udp() {
	udp_row 0.0.0.0:5353 systemd-resolve
	udp_row '*:5353' systemd-resolve '*:*'
	udp_row 127.0.0.53:53 systemd-resolve
	udp_row 127.0.0.54:53 systemd-resolve
}

# Reset the fixture to a device that passes: the measured fixed sockets, no DHCP
# client, the stock range, every command succeeding.
reset_fixture() {
	rm -f "${fixture}"/*
	base_tcp >"${fixture}/tcp"
	base_udp >"${fixture}/udp"
	printf '32768\t60999\n' >"${fixture}/range"
	root=$BRENN_REPO_ROOT
}

# Use the alternative root, with these lines appended to the device
# expectations.
with_expectations() {
	cat "${BRENN_REPO_ROOT}/tests/device/expected-${BRENN_PROFILE}.env" >"${alt_root}/tests/device/expected-${BRENN_PROFILE}.env"
	printf '%s\n' "$@" >>"${alt_root}/tests/device/expected-${BRENN_PROFILE}.env"
	root=$alt_root
}

run_census() {
	rm -f "$real_ssh_marker"
	out=$(t_env_scrubbed BRENN_DEVICE_ \
		PATH="${shim_dir}:${PATH}" \
		BRENN_REPO_ROOT="$root" \
		BRENN_TESTS_LIB="$BRENN_TESTS_LIB" \
		BRENN_PROFILE="$BRENN_PROFILE" \
		BRENN_DEVICE_CONF="$conf" \
		BRENN_DEVICE_HOST=unit.invalid \
		BRENN_DEVICE_SSH="$stub" \
		BRENN_DEVICE_SSH_MULTIPLEX=0 \
		FIXTURE_DIR="$fixture" \
		bash "$census_test" 2>&1)
	status=$?
	if [ -e "$real_ssh_marker" ]; then
		t_fail "the census ran the stub, never a real ssh" "output:" "$(census_output)"
	fi
}

UDP_SET="the UDP service sockets other than recognized DHCP clients are exactly the expected set"
UDP_OWNERS="every bound UDP socket belongs to the resolver or the network manager"
TCP_SET="the listening TCP sockets are exactly the expected set"
TCP_OFFNET="sshd is the only TCP listener reachable from the network"
FLOOR="the kernel reports where its ephemeral ports start"

# The census's own output, indented so that its lines read as detail under this
# test's failure rather than as failures of their own.
census_output() {
	printf '%s\n' "$out" | sed 's/^/    | /'
}

fail_titles() {
	printf '%s\n' "$out" | sed -n 's/^FAIL  //p' | sort
}

expect_pass() {
	local desc=$1
	run_census
	if [ "$status" -eq 0 ] && [ -z "$(fail_titles)" ]; then
		t_pass "$desc"
	else
		t_fail "$desc" "status: ${status}" "output:" "$(census_output)"
	fi
}

# The run failed, on exactly the named assertions and no others, and the
# failure output carries every given detail. Details follow a lone `--`.
expect_fail() {
	local desc=$1 titles=() details=() seen_sep=0 d missing=()
	shift
	for d in "$@"; do
		if [ "$d" = -- ]; then
			seen_sep=1
		elif [ "$seen_sep" = 1 ]; then
			details+=("$d")
		else
			titles+=("$d")
		fi
	done
	run_census
	local want
	want=$(printf '%s\n' "${titles[@]}" | sort)
	for d in "${details[@]}"; do
		case $out in
			*"$d"*) ;;
			*) missing+=("$d") ;;
		esac
	done
	if [ "$status" -eq 1 ] && [ "$(fail_titles)" = "$want" ] && [ ${#missing[@]} -eq 0 ]; then
		t_pass "$desc"
	else
		t_fail "$desc" "status: ${status}" "wanted failures: ${want}" \
			"missing details: ${missing[*]:-none}" "output:" "$(census_output)"
	fi
}

# A UDP fixture of the fixed sockets plus these rows, as "endpoint owner" pairs;
# an owner of "-" is a socket with no program attributed.
udp_plus() {
	base_udp >"${fixture}/udp"
	while [ $# -gt 0 ]; do
		udp_row "$1" "$2" >>"${fixture}/udp"
		shift 2
	done
}

# A DHCP-port row the census must not take for a client, and so holds against
# the fixed set, where its original endpoint and owner are in the diff.
refused() {
	local desc=$1 ep=$2 owner=$3
	reset_fixture
	udp_plus "$ep" "$owner"
	expect_fail "$desc" "$UDP_SET" -- "+${ep} ${owner}"
}


reset_fixture
expect_pass "the measured fixed sockets with no DHCP client pass"

reset_fixture
udp_plus 192.0.2.10:68 systemd-network
expect_pass "a v4 client on its lease alone passes"

reset_fixture
udp_plus '192.0.2.10%wlan0:68' systemd-network
expect_pass "a v4 client bound to its device passes"

reset_fixture
udp_plus '[fe80::1234:5678:9abc:def0]:546' systemd-network
expect_pass "a v6 client on a link-local address alone passes"

reset_fixture
udp_plus '[fe80::1234:5678:9abc:def0]%wlan0:546' systemd-network
expect_pass "a v6 client with its interface suffix outside the brackets passes"

reset_fixture
udp_plus 192.0.2.10:68 systemd-network '[fe80::1234:5678:9abc:def0]:546' systemd-network
expect_pass "one v4 and v6 client pair passes"

reset_fixture
udp_plus 192.0.2.10:68 systemd-network 203.0.113.7:68 systemd-network \
	'[fe80::1234:5678:9abc:def0]:546' systemd-network \
	'[fe80::aa:bbff:fecc:dd01]%eth0:546' systemd-network
expect_pass "several clients on differing addresses pass"

reset_fixture
udp_plus 198.51.100.20:68 systemd-network 198.51.100.21:68 systemd-network
expect_pass "v4 clients need no v6 partner"

reset_fixture
udp_plus '[fe80:1:2:3:4:5:6:7]:546' systemd-network
expect_pass "a full eight-hextet link-local address passes"

reset_fixture
udp_plus '[febf:ffff::1]:546' systemd-network
expect_pass "the top of fe80::/10 passes"

reset_fixture
udp_plus '[fe80::1]%if7:546' systemd-network
expect_pass "an interface index fallback suffix is an ordinary label"


refused "a v4 client on the wildcard fails" 0.0.0.0:68 systemd-network
refused "a v6 client on the wildcard fails" '[::]:546' systemd-network
refused "a v4 client on loopback fails" 127.0.0.1:68 systemd-network
refused "a v4 client on a multicast address fails" 224.0.0.251:68 systemd-network
refused "a v4 client on a reserved address fails" 240.0.0.1:68 systemd-network
refused "a v4 client on the limited broadcast fails" 255.255.255.255:68 systemd-network
refused "a v6 client on a global address fails" '[2001:db8::1]:546' systemd-network
refused "a v6 client on loopback fails" '[::1]:546' systemd-network
refused "a v6 client on a multicast address fails" '[ff02::1:2]:546' systemd-network
refused "the address above fe80::/10 fails" '[fec0::1]:546' systemd-network
refused "the address below fe80::/10 fails" '[fe7f::1]:546' systemd-network
refused "a v6 address on the v4 client port fails" '[fe80::1]:68' systemd-network
refused "a v4 address on the v6 client port fails" 192.0.2.10:546 systemd-network
refused "the resolver on the v4 client port fails" 192.0.2.10:68 systemd-resolve
refused "the resolver on the v6 client port fails" '[fe80::1]:546' systemd-resolve

reset_fixture
udp_plus 192.0.2.10:68 -
expect_fail "an unattributed socket on the v4 client port fails" \
	"$UDP_SET" "$UDP_OWNERS" -- "+192.0.2.10:68 -"

reset_fixture
udp_plus 192.0.2.10:67 systemd-network
expect_fail "the network manager on another service port fails" \
	"$UDP_SET" -- "+192.0.2.10:67 systemd-network"

# Host parser checks: envelopes ss does not produce, which must not qualify.
refused "parser: a suffix inside the brackets fails" '[fe80::1%wlan0]:546' systemd-network
refused "parser: an empty v6 suffix fails" '[fe80::1]%:546' systemd-network
refused "parser: an empty v4 suffix fails" '192.0.2.10%:68' systemd-network
refused "parser: uppercase hex fails" '[FE80::1]:546' systemd-network
refused "parser: a dotted v4 tail fails" '[fe80::192.0.2.1]:546' systemd-network
refused "parser: an unfamiliar v6 character fails" '[fe80::1g]:546' systemd-network
refused "parser: an unfamiliar v4 character fails" '192.0.2.1a:68' systemd-network


while IFS= read -r fixed; do
	reset_fixture
	base_udp | grep -vF " ${fixed%% *} " >"${fixture}/udp"
	expect_fail "a missing ${fixed%% *} fails" "$UDP_SET" -- "-${fixed}"
done <<'FIXED'
0.0.0.0:5353 systemd-resolve
*:5353 systemd-resolve
127.0.0.53:53 systemd-resolve
127.0.0.54:53 systemd-resolve
FIXED

reset_fixture
udp_plus 0.0.0.0:5355 systemd-resolve
expect_fail "an extra resolver service socket fails" \
	"$UDP_SET" -- "+0.0.0.0:5355 systemd-resolve"

reset_fixture
base_udp | sed 's/127\.0\.0\.53:53/127.0.0.53%lo:53/' >"${fixture}/udp"
expect_fail "the UDP main stub spelled with %lo fails" \
	"$UDP_SET" -- "+127.0.0.53%lo:53 systemd-resolve" "-127.0.0.53:53 systemd-resolve"

reset_fixture
base_udp | sed 's/^UNCONN 0 0 \*:5353 \*:\*/UNCONN 0 0 [::]:5353 [::]:*/' >"${fixture}/udp"
expect_fail "the responder's second socket spelled [::]:5353 fails" \
	"$UDP_SET" -- "+[::]:5353 systemd-resolve" "-*:5353 systemd-resolve"

reset_fixture
base_udp | sed 's/^\(UNCONN 0 0 127\.0\.0\.54:53 0\.0\.0\.0:\*\).*/\1/' >"${fixture}/udp"
expect_fail "an unattributed fixed socket fails both UDP checks" \
	"$UDP_SET" "$UDP_OWNERS" -- "+127.0.0.54:53 -"


reset_fixture
udp_plus 0.0.0.0:45123 systemd-resolve 192.0.2.10:45124 systemd-resolve
expect_pass "the resolver's ephemeral sockets pass"

reset_fixture
udp_plus 0.0.0.0:45125 avahi-daemon
expect_fail "another program on an ephemeral port fails the owner check alone" \
	"$UDP_OWNERS" -- "avahi-daemon"

reset_fixture
# shellcheck disable=SC2016  # expanded when the expectations file is sourced
with_expectations 'EXPECT_LISTEN_UDP_HIGH_PORTS="45000"' \
	'EXPECT_LISTEN_UDP="${EXPECT_LISTEN_UDP}
0.0.0.0:45000 systemd-resolve"'
udp_plus 0.0.0.0:45000 systemd-resolve
expect_pass "a listed high port's socket is in the exact comparison"

reset_fixture
# shellcheck disable=SC2016  # expanded when the expectations file is sourced
with_expectations 'EXPECT_LISTEN_UDP_HIGH_PORTS="45000"' \
	'EXPECT_LISTEN_UDP="${EXPECT_LISTEN_UDP}
0.0.0.0:45000 systemd-resolve"'
expect_fail "a listed high port's socket missing fails" \
	"$UDP_SET" -- "-0.0.0.0:45000 systemd-resolve"


reset_fixture
tcp_row 127.0.0.1:631 cupsd >>"${fixture}/tcp"
expect_fail "an unexpected loopback TCP listener fails the TCP set alone" \
	"$TCP_SET" -- "+127.0.0.1:631 cupsd"

reset_fixture
tcp_row 0.0.0.0:8080 python3 >>"${fixture}/tcp"
expect_fail "an unexpected TCP listener on the network fails both TCP checks" \
	"$TCP_SET" "$TCP_OFFNET" -- "+0.0.0.0:8080 python3"

reset_fixture
# shellcheck disable=SC2016  # expanded when the expectations file is sourced
with_expectations 'EXPECT_LISTEN_TCP="${EXPECT_LISTEN_TCP}
0.0.0.0:8080 python3"'
tcp_row 0.0.0.0:8080 python3 >>"${fixture}/tcp"
expect_fail "the off-network check holds when the TCP set was widened" \
	"$TCP_OFFNET" -- "0.0.0.0:8080 python3"

reset_fixture
base_tcp | sed 's/^\(LISTEN 0 4096 0\.0\.0\.0:22 0\.0\.0\.0:\*\).*/\1/' >"${fixture}/tcp"
expect_fail "an unattributed TCP listener fails both TCP checks" \
	"$TCP_SET" "$TCP_OFFNET" -- "+0.0.0.0:22 -"


reset_fixture
echo 255 >"${fixture}/tcp.status"
expect_fail "a failed TCP capture with complete rows fails at the capture" \
	"read the listening sockets" -- "command failed (status 255): ss -Hltnp"

reset_fixture
echo 255 >"${fixture}/udp.status"
expect_fail "a failed UDP capture with the fixed rows fails at the capture" \
	"read the bound UDP sockets" -- "command failed (status 255): ss -Hlunp"

reset_fixture
echo 1 >"${fixture}/range.status"
expect_fail "a failed range capture with a usable floor fails at the capture" \
	"read the ephemeral port range" \
	-- "command failed (status 1): cat /proc/sys/net/ipv4/ip_local_port_range"

reset_fixture
: >"${fixture}/tcp"
expect_fail "an empty TCP capture fails" \
	"read the listening sockets" -- "ss reported nothing at all"

reset_fixture
: >"${fixture}/udp"
expect_fail "an empty UDP capture fails" \
	"read the bound UDP sockets" -- "ss reported nothing at all"

reset_fixture
echo 'unreadable' >"${fixture}/range"
expect_fail "an unusable floor is reported and the stock floor used" \
	"$FLOOR" -- "using 32768, the stock floor" "PASS  ${UDP_SET}"

t_done
