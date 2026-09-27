#!/usr/bin/env bash
#
# The clock is right and the logs leave the device.
#
# These two belong together because one depends on the other: the upload is TLS
# to a private certificate authority, and a device that thinks it is 1970
# rejects every certificate it is shown. So what only a running device can show
# is the pair of them together — the clock was set, and the logs went somewhere.
#
# Where they go is site information and does not appear in this repository, so
# nothing here compares an address to a value written down. What is asserted is
# the shape of the arrangement: the collector is the one the provisioning
# generation named, the connection to it is TLS, and — the part that no
# configuration file can promise — records this test just wrote were accepted.
#
# The journal itself is the reason all of this matters: it is held in RAM and
# is gone at the next boot, so an upload that silently fails is a device with
# no history at all.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

# --- the clock --------------------------------------------------------------

dev_eq "the time synchronisation service is running" \
	"systemctl is-active $(dev_quote "$EXPECT_TIMESYNCD_UNIT")" active

# time-sync.target is deliberately not asserted. With plain timesyncd it is a
# passive target that nothing pulls, so it stays inactive on a device whose clock
# is perfectly well set — and it would be reached at service start rather than at
# synchronisation even if something did pull it. Only systemd-time-wait-sync
# gives it the reached-when-set meaning, and that unit blocks the target until
# the clock is synchronised with no timeout: on an appliance that has to come up
# with its network absent, that holds startup jobs open indefinitely.
#
# What covers the cold clock instead is the two TLS consumers ordered after the
# target — the journal uploader and the application fetch — both of which retry
# for as long as the device is up, so a first handshake against a 1970 clock costs
# retries rather than correctness. If that ever proves insufficient, enabling
# systemd-time-wait-sync and having those units want the target is the mechanism,
# at the availability cost above.

dev_eq "the clock is synchronised to the network" \
	'timedatectl show -p NTPSynchronized --value' "$EXPECT_NTP_SYNCHRONIZED"

# Whether a time server a DHCP lease names reaches the time client. networkd
# writes each link's lease-supplied servers into its per-link state, which is
# what timesyncd reads them from, so the two readings — the union over every
# link, and the servers the client reports as per-link — must be the same set.
# That is the whole of the wiring for a unit whose only network is a cable to a
# host acting as its time server, and it is the same path whether the cable was
# up at boot or plugged in afterwards.
#
# When no lease names a server and the client holds none there is nothing to
# compare, and two empty sets agreeing would be a pass that checked nothing, so
# it is said out loud as the gap it is. One side empty and the other not is a
# disagreement, and is compared like any other. The assertion is live on any
# network whose lease offers one.
#
# A failed read also comes back with no servers in it, and would take that SKIP
# branch, so each reading's status is checked first. networkd writes a state
# file for every link it knows, loopback included, so there is always one to
# read: none at all means the state is not where this looks, which fails here
# rather than reading as a lease that named nothing.
#
# read_servers VAR DESC CMD — the set of servers CMD prints, one per line, into
# VAR; or a failure under DESC, VAR left empty, and a nonzero return.
read_servers() {
	local var=$1 desc=$2 cmd=$3 status=0 found
	dev_capture "$cmd" || status=$?
	if [ "$status" -ne 0 ]; then
		t_fail "$desc" "command failed (status ${status}): ${cmd}" "output: ${DEV_OUT}"
		printf -v "$var" '%s' ''
		return 1
	fi
	# `|| true` is for grep, which fails on a good reading that names no server.
	found=$(printf '%s\n' "$DEV_OUT" | tr ' ' '\n' | grep . | sort -u || true)
	printf -v "$var" '%s' "$found"
}
servers_read=yes
read_servers lease_servers "networkd's per-link state can be read" \
	"sed -n 's/^NTP=//p' /run/systemd/netif/links/*" || servers_read=no
read_servers link_servers "the time client's per-link servers can be read" \
	'timedatectl show-timesync -p LinkNTPServers --value' || servers_read=no
if [ "$servers_read" = no ]; then
	: # Already failed above; there is no pair of readings to compare.
elif [ -z "$lease_servers" ] && [ -z "$link_servers" ]; then
	echo "SKIP  DHCP-supplied time: no lease on this bench carries an NTP server; unverified here"
else
	t_eq_text "the time client takes the servers the leases name" \
		"$link_servers" "$lease_servers"
fi

# Which server it used. The time server is one the provisioned drop-in names or
# one a link's DHCP lease names, both of which rank above the fallback, and the
# distribution's public pool otherwise — so every side of this comparison is
# read from the device, as it is for the regulatory domain, and what is asserted
# is that they agree.
#
# Which way round they have to agree is decided by what is configured. If the
# generation or a lease names servers, one of them is the answer; which one,
# when both do, is the client's policy and not this test's. Synchronising to the
# pool instead means an override that did not take — a drop-in in the wrong
# place, or wiring lost on an update — or a lease's server that never reached
# the client. That is the likeliest way this breaks, so it is the one thing here
# that fails.
dev_capture 'timedatectl show-timesync -p ServerName --value'
server=$DEV_OUT
ntp_servers="sed -n 's/^[[:space:]]*NTP=//p' $(dev_quote "$EXPECT_NTP_SOURCE") 2>/dev/null | tr ' ' '\n'"
dev_capture "${ntp_servers} | grep -c . || true"
provisioned=$DEV_OUT
dev_capture "${ntp_servers} | grep -c -x $(dev_quote "$server") || true"
named=$DEV_OUT
from_lease=no
if [ -n "$server" ] && printf '%s\n' "$link_servers" | grep -qxF -- "$server"; then
	from_lease=yes
fi

case "${provisioned}:${named}" in
	*[!0-9:]* | :* | *:)
		# Neither reading is a number, so neither branch below means anything.
		t_fail "the provisioned time configuration can be read" \
			"servers named in ${EXPECT_NTP_SOURCE}: ${provisioned:-<nothing>}" \
			"of them in use: ${named:-<nothing>}"
		;;
	*)
		if [ -z "$server" ]; then
			t_fail "the clock names the server it synchronised with" \
				"timedatectl reports no server, yet the clock is synchronised"
		elif [ "$named" -ge 1 ]; then
			t_pass "the clock is set from the provisioned time server"
		elif [ "$from_lease" = yes ]; then
			t_pass "the clock is set from a time server a DHCP lease named"
		elif [ "$provisioned" -ge 1 ]; then
			t_fail "the clock is set from the provisioned time server" \
				"the generation names ${provisioned} server(s)" \
				"the clock synchronised with: ${server}"
		elif [ -n "$link_servers" ]; then
			t_fail "the clock is set from a time server a DHCP lease named" \
				"the leases name: $(printf '%s\n' "$link_servers" | tr '\n' ' ')" \
				"the clock synchronised with: ${server}"
		else
			# Not a failure: nothing is configured on a site with no local
			# server and a lease that names none, and then the distribution's
			# pool is the correct answer. It is reported because "which pool"
			# is a thing worth seeing once.
			t_pass "the clock is set from the distribution's default servers"
		fi
		;;
esac

# The boot-clock floor. A unit with no battery boots at the image's epoch; the
# floor unit raises the clock to the pinned date before any network exists, so
# its line in this boot's journal records what the clock was raised to on every
# boot, whether or not NTP was reachable afterwards. That line is what is read,
# rather than the clock, which on a synchronised unit says nothing about the
# floor. Times are in the pin's own form, so their digits, read as one number,
# order them.
dev_eq "the clock floor was applied this boot" \
	"systemctl is-active $(dev_quote "$EXPECT_CLOCK_FLOOR_UNIT")" active
dev_eq "and the floor unit succeeded" \
	"systemctl show -p Result --value $(dev_quote "$EXPECT_CLOCK_FLOOR_UNIT")" success

# A unit's monotonic timestamp, in microseconds since boot, into VAR; or a
# failure under DESC and a nonzero return. Zero is a unit that never got there
# this boot, which is not a time.
read_monotonic() {
	local var=$1 desc=$2 unit=$3 prop=$4
	dev_capture "systemctl show -p ${prop} --value $(dev_quote "$unit")"
	case $DEV_OUT in
		"" | 0 | *[!0-9]*)
			t_fail "$desc" "${unit} ${prop}: ${DEV_OUT:-<nothing>}"
			return 1
			;;
	esac
	printf -v "$var" '%s' "$DEV_OUT"
}

# Ahead of the time client, as the unit's ordering says, and as this boot
# actually ran it: the floor finished before the client started, so the
# client's own step to its recorded timestamp found the clock already raised.
floor_done="" client_start=""
if read_monotonic floor_done "the floor unit's exit time can be read" \
	"$EXPECT_CLOCK_FLOOR_UNIT" ExecMainExitTimestampMonotonic &&
	read_monotonic client_start "the time client's start time can be read" \
		"$EXPECT_TIMESYNCD_UNIT" ExecMainStartTimestampMonotonic; then
	if [ "$floor_done" -le "$client_start" ]; then
		t_pass "the floor was applied before the time client started"
	else
		t_fail "the floor was applied before the time client started" \
			"floor unit exited at ${floor_done} us" \
			"time client started at ${client_start} us"
	fi
fi

dev_capture "journalctl -b -u $(dev_quote "$EXPECT_CLOCK_FLOOR_UNIT") -o cat 2>&1 | grep '^clock-floor:' || true"
floor_lines=$DEV_OUT
# A time in the pin's form as a comparable number, or nothing if it is not in
# that form.
floor_digits() {
	case $1 in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
			printf '%s\n' "${1//[!0-9]/}"
			;;
	esac
}
floor_n=$(floor_digits "$EXPECT_CLOCK_FLOOR")
floor_count=$(printf '%s\n' "$floor_lines" | grep -c . || true)

# The journal is in RAM with a size cap, and journald deletes a boot's oldest
# file first once the cap is reached, so on a unit that has been up long enough
# the line from early boot is gone although the unit did write it. That is told
# apart from a unit that never wrote it by where this boot's journal now begins.
# The floor unit writes into journald's socket early in boot, and journald
# stamps what it finds waiting with the time it read it, so the first entry's
# receive time can be after the unit even when nothing is lost; the time the
# entry's source gives — the kernel's own, for the
# kernel's messages that open a boot — is what says how far back the journal
# still reaches. Past the floor unit's exit means the line cannot be there.
journal_start=""
if [ "$floor_count" -eq 0 ] && [ -n "$floor_done" ]; then
	dev_capture "journalctl -b -q -o json 2>/dev/null | head -n1"
	first=$DEV_OUT
	journal_start=$(printf '%s\n' "$first" | sed -n 's/.*"_SOURCE_MONOTONIC_TIMESTAMP":"\([0-9]*\)".*/\1/p')
	if [ -z "$journal_start" ]; then
		journal_start=$(printf '%s\n' "$first" | sed -n 's/.*"__MONOTONIC_TIMESTAMP":"\([0-9]*\)".*/\1/p')
	fi
fi
if [ -n "$journal_start" ] && [ "$journal_start" -gt "$floor_done" ]; then
	echo "SKIP  the floor unit's journal line: this boot's journal now begins at ${journal_start} us, after the unit exited at ${floor_done} us; rotated away, unverifiable here"
elif [ "$floor_count" -ne 1 ]; then
	t_fail "the floor unit reported once this boot" \
		"expected one clock-floor: line, found ${floor_count}" "${floor_lines}"
else
	floor_seen=$(printf '%s\n' "$floor_lines" | sed -n 's/^clock-floor: \(advanced from\|kept\) .*(floor \([^)]*\))$/\2/p')
	t_eq "the floor applied is the image's pinned floor" "$floor_seen" "$EXPECT_CLOCK_FLOOR"
fi
dev_capture "date -u +%Y-%m-%dT%H:%M:%SZ"
now=$DEV_OUT
now_n=$(floor_digits "$now")
if [ -n "$now_n" ] && [ "$now_n" -ge "$floor_n" ]; then
	t_pass "the clock now is no earlier than the floor (${now})"
else
	t_fail "the clock now is no earlier than the floor" \
		"floor: ${EXPECT_CLOCK_FLOOR}" "now:   ${now:-<nothing>}"
fi

# --- the journal ------------------------------------------------------------

# In RAM, and nowhere else. The persistent directory is what journald would
# create if the volatile setting ever stopped taking effect, and its existence
# is a steady write class on the flash rather than a cosmetic difference.
dev_exists "the journal is held in RAM" "$EXPECT_RUNTIME_JOURNAL_DIR"
dev_absent "journald keeps no directory for persistent storage" \
	"$EXPECT_PERSISTENT_JOURNAL_DIR"

# --- the upload -------------------------------------------------------------

# Whether there is an upload at all is the generation's to say: the collector is
# optional configuration, and the uploader is conditioned on the file naming it.
# Both answers are asserted — a device with a collector has to be shipping logs,
# and a device without one has to be visibly not shipping them rather than
# looking like a device whose uploader failed. What is never allowed is this
# section quietly doing nothing: a generation that dropped `upload.conf` by
# accident would then pass as a device that meant to have no collector.
dev_capture "test -e $(dev_quote "$EXPECT_UPLOAD_SOURCE") && echo provisioned || echo absent"
collector=$DEV_OUT

if [ "$collector" = absent ]; then
	t_pass "no collector is provisioned — this device's logs are in RAM and end at the next reboot"

	# Inactive because its condition was not met, which is the difference
	# between "not configured" and "tried and failed": the second is a finding
	# and looks identical from `is-active` alone.
	dev_eq "the journal uploader is not running" \
		"systemctl is-active $(dev_quote "$EXPECT_UPLOAD_UNIT") || true" inactive
	dev_eq "and it is the missing configuration that held it back" \
		"systemctl show -p ConditionResult --value $(dev_quote "$EXPECT_UPLOAD_UNIT")" no
	# Neither reading above separates a condition that failed from a unit systemd
	# never got to: `inactive` is also what a masked or unwanted unit reports, and
	# `ConditionResult=no` is what a unit whose conditions were never evaluated
	# reports. These two are what make the pair mean what it says — the unit is
	# the one the image ships, and systemd did check it. Without them a lost
	# WantedBy, a left-behind mask or a dropped logging layer passes here, and the
	# day a collector is provisioned the uploader does not start.
	dev_eq "the uploader is the unit this image ships, loaded and not masked" \
		"systemctl show -p LoadState --value $(dev_quote "$EXPECT_UPLOAD_UNIT")" loaded
	dev_capture "systemctl show -p ConditionTimestampMonotonic --value $(dev_quote "$EXPECT_UPLOAD_UNIT")"
	case $DEV_OUT in
		"" | *[!0-9]*)
			t_fail "and systemd did evaluate that condition" \
				"expected a monotonic timestamp" \
				"read: ${DEV_OUT:-<nothing>}"
			;;
		0)
			t_fail "and systemd did evaluate that condition" \
				"the conditions were never checked: nothing pulled the unit into the boot"
			;;
		*) t_pass "and systemd did evaluate that condition" ;;
	esac
	# The path the uploader would read, which is a link into the generation and
	# so dangles when the generation names no collector. Asserted because a
	# regular file left at that path by anything else is a configuration the
	# device never meant to have.
	dev_absent "the published configuration path resolves to nothing" \
		"$EXPECT_UPLOAD_CONF"

	t_done
fi

if [ "$collector" != provisioned ]; then
	t_fail "whether a collector is provisioned can be read" \
		"expected provisioned or absent" "read: ${collector:-<nothing>}"
	t_done
fi

t_pass "a collector is provisioned, so the logs are expected to leave the device"

dev_eq "the journal uploader is running" \
	"systemctl is-active $(dev_quote "$EXPECT_UPLOAD_UNIT")" active

# The provisioned configuration, by the same published path every other consumer
# uses — asserted here as a resolved readlink, not merely as a link on disk.
dev_eq "the uploader reads the provisioned configuration" \
	"readlink $(dev_quote "$EXPECT_UPLOAD_CONF")" "$EXPECT_UPLOAD_SOURCE"

# The collector's address is site information, so only its scheme is compared:
# what matters here is that no plaintext destination was provisioned.
dev_eq "the collector is reached over TLS" \
	"sed -n 's/^URL=\\(.\\{0,8\\}\\).*/\\1/p' $(dev_quote "$EXPECT_UPLOAD_SOURCE") | head -n1" \
	"$EXPECT_URL_SCHEME"

# A connection, held by the uploader itself. An established socket owned by
# that process is the evidence that the name resolved, the route exists and the
# collector answered; the matching is by process id rather than by name because
# journald and the uploader share the first fifteen characters of theirs.
dev_capture "systemctl show -p MainPID --value $(dev_quote "$EXPECT_UPLOAD_UNIT")"
upload_pid=$DEV_OUT
if [ -z "$upload_pid" ] || [ "$upload_pid" = "0" ]; then
	t_fail "the uploader holds a connection to the collector" \
		"the unit reports no main process (pid: ${upload_pid:-<nothing>})"
else
	dev_capture "ss -Htnp state established | grep -c 'pid=${upload_pid},' || true"
	if [ "${DEV_OUT:-0}" -ge 1 ] 2>/dev/null; then
		t_pass "the uploader holds a connection to the collector"
	else
		t_fail "the uploader holds a connection to the collector" \
			"established sockets owned by pid ${upload_pid}: ${DEV_OUT:-<nothing>}"
	fi
fi

# Receipt. The uploader records how far the collector has accepted, and moves
# that record only when a transfer succeeded — so a record written now, and that
# mark moving past it, is the device's own evidence that something on the far
# end took the data. Everything before this assertion is configuration; this is
# the only one that fails when the collector is quietly refusing.
#
# It is asserted in three steps, because each of the first two is a way for the
# third to report success on an experiment that did not happen. The record has
# to have been written, it has to have reached the journal, and only then does
# the collector's mark mean anything about it. What is compared is not that the
# mark moved — any log line at all moves it — but that this particular record is
# no longer ahead of it, which is the only form of the question that names the
# data whose delivery is in doubt.
tag=brenn-device-test
marker="${tag} $(date -u +%Y%m%dT%H%M%SZ) $$"
state_file=$(dev_quote "$EXPECT_UPLOAD_STATE_FILE")

# The mark, then everything the journal holds after it. A mark that is not there
# yet is nothing accepted yet, and a mark the journal cannot seek to is a
# reading rather than an answer: both are reported as pending, and the window
# running out is what turns them into the failure.
accepted="c=\$(sed -n 's/^LastCursor=//p' ${state_file} 2>/dev/null | tail -n1);"
accepted="${accepted} [ -n \"\$c\" ] || { echo 'nothing accepted yet'; exit 0; };"
accepted="${accepted} rest=\$(journalctl -t $(dev_quote "$tag") --after-cursor \"\$c\" -o cat 2>&1) ||"
accepted="${accepted} { echo \"cannot read past the mark: \$rest\"; exit 0; };"
accepted="${accepted} case \"\$rest\" in *$(dev_quote "$marker")*) echo 'still ahead of the mark' ;;"
accepted="${accepted} *) echo accepted ;; esac"

if ! dev_run "echo $(dev_quote "$marker") | systemd-cat -t $(dev_quote "$tag")" >/dev/null 2>&1; then
	t_fail "a record is written for the collector to accept" \
		"the device would not log through systemd-cat"
elif dev_wait "the record reaches the journal on the device" \
	"journalctl -t $(dev_quote "$tag") -o cat 2>/dev/null | grep -q -F $(dev_quote "$marker") && echo present" \
	present "$EXPECT_JOURNAL_VISIBLE_SECONDS"; then
	dev_wait "the collector accepted the records this test wrote" \
		"$accepted" accepted "$EXPECT_UPLOAD_RECEIPT_SECONDS"
fi

t_done
