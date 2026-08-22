#!/usr/bin/env bash
#
# The one question this device answers: where it is.
#
# On a network the operator runs, the DHCP lease registers the provisioned name
# and that is the whole of discovery. Off it — a phone hotspot, somebody else's
# wifi — the lease table is behind an admin page nobody here can open, and the
# address the device took is knowable by nothing. The multicast-DNS responder is
# the answer to that, and it is the only listener the charter admits besides
# sshd, so what it does has to be held exactly: it answers for this host and
# advertises no service.
#
# What is asserted here is the responder's state on every link the image
# configures, and then the thing that state is for: the name, asked for from the
# host running this suite. That last one is an end-to-end property of two machines
# on one segment, which this lane cannot promise it has — so it is attempted and,
# where the answer cannot be got, said out loud as the gap it is. Silence there
# would read as coverage, and the operator's pre-trip check from a laptop
# (docs/provisioning.md) is what stands in for it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# The responder is a job of the resolver, and the resolver is also this device's
# stub. Dead, the device loses its name and its ability to resolve one, and the
# two failures look different from a distance.
dev_eq "the resolver is running" \
	"systemctl is-active $(dev_quote "$EXPECT_RESOLVED_UNIT")" active

# Enabled on every link, not only the one this run came in over. `resolvectl mdns`
# prints "Link N (name): value", and the value is what is asserted: the global
# setting in the resolver's configuration is a gate, not a guarantee, and a
# per-link default that landed the other way would leave the gate open onto
# nothing. The wired link is asserted for the same reason as the wireless one —
# it is how a unit on the bench is reached, and a drop-in that regressed for it
# alone would be a device nobody can find on a cable.
#
# LLMNR is read here too, on each link. It is the other half of the same knob: the
# charter admits one responder, and enabling mDNS puts LLMNR in play. A file the
# image lane reads is not a reading off the device.
for iface in $EXPECT_LINK_INTERFACES; do
	dev_eq "the responder is enabled on ${iface}" \
		"resolvectl mdns $(dev_quote "$iface") | sed -n 's/.*: *//p'" yes
	dev_eq "and LLMNR is still off on ${iface}" \
		"resolvectl llmnr $(dev_quote "$iface") | sed -n 's/.*: *//p'" no
done

# The resolver's socket on 5353 is asserted by the listener census
# (050-listeners.test.sh), which owns the whole UDP service-socket set.
# Duplicating it here would mean two places to reconcile on the first hardware
# run.

# That the name is the provisioned one — not a fallback to what the image carries
# — is asserted by 060-provisioning.test.sh, which compares it against the
# selected generation's own hostname file. Comparing the kernel host name with
# /etc/hostname here would agree on a device that fell back to both, so what is
# taken here is the reading, for the question below.
dev_capture "hostname"
announced=$DEV_OUT
if [ -z "$announced" ]; then
	t_fail "the device has a host name to answer for" "hostname printed nothing"
	t_done
fi

# The one assertion that is about the responder answering rather than about its
# preconditions: ask, from here, for the name and see whether the device says
# where it is. Everything above can hold on a unit whose responder never replies —
# a name it declines to claim, a socket bound on the family nobody asks over — and
# that unit is a green suite and a robot nobody can find.
#
# The answer is checked, not merely counted: an address that is not one of the
# device's own is another host answering to this name, which breaks resolution for
# both and is worth more than a pass.
dev_capture "ip -o addr show | awk '\$2 != \"lo\" { print \$4 }'"
device_addrs=$(printf '%s\n' "$DEV_OUT" | sed 's,/.*,,' | sort -u)

query_tool=""
for cmd in resolvectl avahi-resolve; do
	if command -v "$cmd" >/dev/null 2>&1; then
		query_tool=$cmd
		break
	fi
done

if [ -z "$query_tool" ]; then
	# This host cannot ask the question, so the feature is unverified on this
	# run; the operator's pre-trip check from a laptop is what stands in for it.
	echo "SKIP  the responder answering its name: no resolvectl or avahi-resolve on this host"
else
	case $query_tool in
		resolvectl) answer=$(resolvectl query --legend=no "${announced}.local" 2>&1) ;;
		avahi-resolve) answer=$(avahi-resolve -n "${announced}.local" 2>&1) ;;
	esac
	answered=$(printf '%s\n' "$answer" | tr -s '[:blank:]' '\n' | sed 's/%.*//' |
		grep -E '^(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]*:[0-9a-fA-F:]+)$' |
		sort -u)
	if [ -z "$answered" ]; then
		# Two causes, and this host cannot tell them apart: a responder that is
		# not answering, or a host that is not on the device's segment at all —
		# multicast does not cross a router.
		echo "SKIP  the responder answering its name: no mDNS answer for ${announced}.local from this host (not on the device's segment, or the responder is silent)"
	else
		stranger=$(comm -23 <(printf '%s\n' "$answered") <(printf '%s\n' "$device_addrs"))
		if [ -z "$stranger" ]; then
			t_pass "the responder answers ${announced}.local with the device's own addresses"
		else
			t_fail "the responder answers ${announced}.local with the device's own addresses" \
				"answered, and not this device's:" "$stranger" \
				"the device holds:" "$device_addrs"
		fi
	fi
fi

# Nothing is advertised. The responder answers questions about this host and
# publishes no service catalogue, which is the difference between the listener
# that was argued for and a browseable directory of what the device runs. avahi is
# what would bring the latter; the package-set test
# (tests/image/140-package-set.test.sh) already asserts the full installed
# manifest at build time, so a `command -v` here would be a weaker duplicate on a
# lane that only runs when a device is on the bench.

t_done
