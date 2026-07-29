#!/usr/bin/env bash
#
# The clock is right and the logs leave the device.
#
# These two belong together because one depends on the other: the upload is TLS
# to a private certificate authority, and a device that thinks it is 1970
# rejects every certificate it is shown. So the ordering that the image suite
# reads out of the unit files has a consequence only a running device can show
# — the clock was set, and then the logs went somewhere.
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

# The target every TLS-dependent unit is ordered after. It is reached when the
# clock has been set, not when the service started.
dev_eq "the time-sync target has been reached" \
	"systemctl is-active $(dev_quote "$EXPECT_TIME_SYNC_TARGET")" active

dev_eq "the clock is synchronised to the network" \
	'timedatectl show -p NTPSynchronized --value' "$EXPECT_NTP_SYNCHRONIZED"

# Which server it used. A site with its own time server provisions one, and the
# distribution's public pool is what happens otherwise — so both sides of this
# comparison are read from the device, as they are for the regulatory domain,
# and what is asserted is that the two agree.
#
# Which way round they have to agree is decided by the provisioned file itself,
# read as its own count: if the generation names servers, one of them is the
# answer, and synchronising to the pool instead means an override that did not
# take — a drop-in in the wrong place, or wiring lost on an update. That is the
# likeliest way this knob breaks, so it is the one thing here that fails.
dev_capture 'timedatectl show-timesync -p ServerName --value'
server=$DEV_OUT
ntp_servers="sed -n 's/^[[:space:]]*NTP=//p' $(dev_quote "$EXPECT_NTP_SOURCE") 2>/dev/null | tr ' ' '\n'"
dev_capture "${ntp_servers} | grep -c . || true"
provisioned=$DEV_OUT
dev_capture "${ntp_servers} | grep -c -x $(dev_quote "$server") || true"
named=$DEV_OUT

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
		elif [ "$provisioned" -ge 1 ]; then
			t_fail "the clock is set from the provisioned time server" \
				"the generation names ${provisioned} server(s)" \
				"the clock synchronised with: ${server}"
		else
			# Not a failure: the optional override is absent on a site that
			# has no local server, and then the distribution's pool is the
			# correct answer. It is reported because "which pool" is a thing
			# worth seeing once.
			t_pass "the clock is set from the distribution's default servers"
		fi
		;;
esac

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
