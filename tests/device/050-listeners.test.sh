#!/usr/bin/env bash
#
# What is listening.
#
# The invariant is one line of the charter: no listener other than sshd and the
# multicast-DNS responder, which answers only for the device itself. It is
# an invariant precisely because it decays silently — a package installed for
# one of its programs brings a daemon, the daemon is enabled by its own
# maintainer scripts, and nothing about the device looks different until
# something is found on the network that nobody meant to publish.
#
# So the assertion is the whole set, sorted, compared as text. Adding an
# expected listener is a deliberate edit to the expectations file with a
# reviewer looking at it, which is the point.
#
# Both transports are counted. UDP has no listening state to filter on, so the
# census there is every socket bound to a service port — the responder that
# answers the device's name is one of those, and an exception nobody can hold to
# its exact shape is an exception that grows. Where the line between a service
# port and a client's ephemeral one is drawn, and why, is at that census below.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

# "address:port program", one per line, sorted. The program name is the first
# one ss attributes the socket to; a socket with no program attributed reads as
# "-", which is a finding rather than a parse failure.
census() {
	printf '%s\n' "$1" | awk '
		NF == 0 { next }
		{
			prog = "-"
			if (match($0, /users:\(\("[^"]+"/)) {
				prog = substr($0, RSTART + 9, RLENGTH - 10)
			}
			print $4, prog
		}
	' | sort -u
}

dev_open

# Sockets in the LISTEN state, with the program holding each one. Numeric
# throughout: a resolved service name is a name that can change under us.
dev_capture 'ss -Hltnp'
raw=$DEV_OUT
if [ -z "$raw" ]; then
	t_fail "read the listening sockets" "ss reported nothing at all"
	t_done
fi

listening=$(census "$raw")

t_eq_text "the listening TCP sockets are exactly the expected set" \
	"$listening" \
	"$(printf '%s\n' "$EXPECT_LISTEN_TCP" | sort -u)"

# The same census over UDP, narrowed. `-l` there cannot mean what it means for
# TCP: a datagram socket has no LISTEN state, so `-l` is "not connected to a
# peer" — which is also every outbound client socket that happens to be waiting
# for a reply when ss runs. The resolver's own upstream queries are exactly that,
# so a whole-set compare over the raw output would go red at random, on the first
# hardware runs, while these expectations are still being measured.
#
# What is left is what an invariant can actually pin: every socket on a port a
# client would not have been given. The line is the kernel's own ephemeral floor,
# read from the device rather than assumed, because that is precisely the range
# the flapping sockets come from and nothing below it is handed out by accident. A
# service that chose a port in the thousands — the range a discovery agent or a
# debug listener lands in — is inside the census, where a 1024 line would have
# left it invisible by construction.
dev_capture 'cat /proc/sys/net/ipv4/ip_local_port_range'
ephemeral_floor=$(printf '%s' "$DEV_OUT" | awk '{ print $1 + 0 }')
if [ -z "$ephemeral_floor" ] || [ "$ephemeral_floor" -le 1024 ]; then
	# The reading is the assertion's own boundary, so an unusable one is said out
	# loud and the stock floor is used rather than silently narrowing the census.
	t_fail "the kernel reports where its ephemeral ports start" \
		"read: '${DEV_OUT}'" "using 32768, the stock floor"
	ephemeral_floor=32768
else
	t_pass "the ephemeral port range starts at ${ephemeral_floor}"
fi

dev_capture 'ss -Hlunp'
raw_udp=$DEV_OUT
if [ -z "$raw_udp" ]; then
	t_fail "read the bound UDP sockets" "ss reported nothing at all"
	t_done
fi

# EXPECT_LISTEN_UDP_HIGH_PORTS is what pulls a socket at or above that floor into
# the census anyway: a service that pinned itself to an ephemeral-range port.
# Nothing on this device does today, and the list is empty; adding to it is the
# deliberate edit this file is built around.
service_udp=$(printf '%s\n' "$raw_udp" |
	awk -v high="$EXPECT_LISTEN_UDP_HIGH_PORTS" -v floor="$ephemeral_floor" '
	BEGIN {
		n = split(high, ports, /[[:space:]]+/)
		for (i = 1; i <= n; i++) {
			if (ports[i] != "") allow[ports[i]] = 1
		}
	}
	{
		port = $4
		sub(/.*:/, "", port)
		if (port + 0 < floor + 0 || (port in allow)) print
	}
')

t_eq_text "the bound UDP service sockets are exactly the expected set" \
	"$(census "$service_udp")" \
	"$(printf '%s\n' "$EXPECT_LISTEN_UDP" | sort -u)"

# The UDP half's own backstop, and the reason it is spelled out here rather than
# in the expectations file: the set above is only as strict as a file someone can
# widen, and widening it is exactly what a careless "make the census see this new
# socket" edit does. So, independent of every expectation: whatever port it chose
# and whichever address it bound, a UDP socket on this device belongs to the
# resolver or to the network manager. Programs, not ports, because a client's
# ephemeral socket belongs to a program that is already known — which makes this
# stable where a port list is not — and because a daemon nobody meant to install
# fails it wherever it decided to listen.
udp_programs=$(census "$raw_udp" | awk '{ print $2 }' | sort -u)
unexpected_udp=$(printf '%s\n' "$udp_programs" | awk '
	$0 == "systemd-resolve" { next }
	$0 == "systemd-network" { next }
	NF == 0 { next }
	{ print }
')
if [ -z "$unexpected_udp" ]; then
	t_pass "every bound UDP socket belongs to the resolver or the network manager"
else
	t_fail "every bound UDP socket belongs to the resolver or the network manager" \
		"also holding one:" "$unexpected_udp"
fi

# The half of the assertion that survives an expectations file someone widened
# without thinking: whatever else is listening, nothing but sshd may accept a
# connection from the network. Loopback addresses are excluded by address, not
# by program, so a daemon that binds 127.0.0.1 is out of scope here and a
# daemon that binds everything is not.
offnet=$(printf '%s\n' "$listening" | awk '
	{
		addr = $1
		sub(/:[^:]*$/, "", addr)
		gsub(/[][]/, "", addr)
		if (addr == "127.0.0.1" || addr == "::1") next
		if (addr ~ /^127\./) next
		if ($2 == "sshd") next
		print
	}
')
if [ -z "$offnet" ]; then
	t_pass "sshd is the only TCP listener reachable from the network"
else
	t_fail "sshd is the only TCP listener reachable from the network" \
		"also listening:" "$offnet"
fi

t_done
