#!/usr/bin/env bash
#
# What is listening.
#
# The invariant is one line of the charter: no listener other than sshd. It is
# an invariant precisely because it decays silently — a package installed for
# one of its programs brings a daemon, the daemon is enabled by its own
# maintainer scripts, and nothing about the device looks different until
# something is found on the network that nobody meant to publish.
#
# So the assertion is the whole set, sorted, compared as text. Adding an
# expected listener is a deliberate edit to the expectations file with a
# reviewer looking at it, which is the point.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# Sockets in the LISTEN state, with the program holding each one. Numeric
# throughout: a resolved service name is a name that can change under us.
dev_capture 'ss -Hltnp'
raw=$DEV_OUT
if [ -z "$raw" ]; then
	t_fail "read the listening sockets" "ss reported nothing at all"
	t_done
fi

# "address:port program", one per line. The program name is the first one ss
# attributes the socket to; a socket with no program attributed reads as "-",
# which is a finding rather than a parse failure.
listening=$(printf '%s\n' "$raw" | awk '
	{
		prog = "-"
		if (match($0, /users:\(\("[^"]+"/)) {
			prog = substr($0, RSTART + 9, RLENGTH - 10)
		}
		print $4, prog
	}
' | sort -u)

t_eq_text "the listening TCP sockets are exactly the expected set" \
	"$listening" \
	"$(printf '%s\n' "$EXPECT_LISTEN_TCP" | sort -u)"

# The half of the assertion that survives an expectations file someone widened
# without thinking: whatever else is listening, nothing but sshd may be
# reachable from the network. Loopback addresses are excluded by address, not
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
	t_pass "sshd is the only listener reachable from the network"
else
	t_fail "sshd is the only listener reachable from the network" \
		"also listening:" "$offnet"
fi

t_done
