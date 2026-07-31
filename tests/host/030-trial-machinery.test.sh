#!/usr/bin/env bash
#
# The decisions a trial boot turns on, exercised off the device.
#
# Three programs share one job: choose which boot and system pair the firmware
# starts, give a candidate exactly one boot to prove itself, and put the device
# back if it does not. Every branch of that is a branch nobody wants to meet
# for the first time on hardware — the failure mode of getting it wrong is a
# device that boots the pair being replaced, or neither.
#
# The firmware and the selector partition are stood in for by a directory: the
# partition labels become symlinks, the device tree becomes two files holding
# what the firmware would have reported, and the selector file is a plain file.
# What is left is the whole decision table, which is the part that is ours.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/tryboot.sh
. "${BRENN_TESTS_LIB}/tryboot.sh"

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/rauc.rootfs-overlay"
backend="${overlay}/usr/lib/rauc/rpi-tryboot-backend"
tryboot_check="${overlay}/usr/lib/brenn/brenn-tryboot-check"
deadman="${overlay}/usr/lib/brenn/brenn-trial-deadman"
rearm="${overlay}/usr/lib/brenn/brenn-trial-rearm"
reporter="${overlay}/usr/lib/brenn/brenn-trial-report"
breadcrumb_writer="${overlay}/etc/initramfs-tools/scripts/local-premount/50-brenn-trial-breadcrumb"
breadcrumb_hook="${overlay}/etc/initramfs-tools/hooks/brenn-trial-breadcrumb"

for prog in "$backend" "$tryboot_check" "$deadman" "$rearm" "$reporter" \
	"$breadcrumb_writer" "$breadcrumb_hook"; do
	if [ ! -x "$prog" ]; then
		t_fail "the trial machinery is present and executable" "not at ${prog}"
		t_done
	fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root=""
slots=""
dt=""
autoboot=""
state=""
reboot_param=""
installing=""
breadcrumb=""
out=""
err=""
rc=0

# A fresh device per case, so no case can pass on what another one left behind.
new_device() {
	root="${work}/$1"
	autoboot="${root}/autoboot.txt"
	state="${root}/data/rauc"
	reboot_param="${root}/run/systemd/reboot-param"
	installing="${root}/run/brenn/rauc-installing"
	# The selector file stands in for the partition, so its directory stands in
	# for what else is on that partition — which is where the backend looks for
	# the record a trial boot leaves.
	breadcrumb="${root}/brenn-trial.log"
	out="${root}/out"
	err="${root}/err"

	mkdir -p "$state" "${root}/run/systemd"
	tryboot_fixture "$root" "${2:-}" "${3:-}"
	slots=$tryboot_slots
	dt=$tryboot_dt

	tryboot_autoboot_text "${4:-2}" "${5:-3}" >"$autoboot"
}

run_backend() {
	rc=0
	BRENN_TRYBOOT_SLOT_DIR="$slots" \
		BRENN_TRYBOOT_DT_DIR="$dt" \
		BRENN_TRYBOOT_AUTOBOOT="$autoboot" \
		BRENN_TRYBOOT_STATE_DIR="$state" \
		BRENN_TRYBOOT_REBOOT_PARAM="$reboot_param" \
		BRENN_RAUC_INSTALLING="$installing" \
		"$backend" "$@" >"$out" 2>"$err" || rc=$?
}

said() {
	cat "$out"
}

armed() {
	[ -f "$reboot_param" ] && cat "$reboot_param" || echo "(not armed)"
}

# What the writable partition remembers about trials that have been started and
# not yet answered. The device is off while most of this matters, so this is the
# whole of it.
staged_markers() {
	local marker found=""
	for marker in "${state}"/staged-*; do
		[ -e "$marker" ] || continue
		found="${found}${found:+ }${marker##*/}"
	done
	printf '%s\n' "${found:-(none)}"
}

# --- reading what the firmware would do -------------------------------------

# The committed pair is the one named outside the tryboot section, and the
# bootname it maps to comes from the labels rather than from any table here.
new_device reads-committed-a
run_backend get-primary
t_eq "reading the committed slot succeeds" "$rc" 0
t_eq "partition 2 is slot A" "$(said)" A

new_device reads-committed-b 2 0 3 2
run_backend get-primary
t_eq "partition 3 is slot B" "$(said)" B

# The booted slot is what the firmware reported, not what the file says: on a
# trial boot the two deliberately disagree, and every later decision rests on
# telling them apart.
new_device reads-booted 3 1
run_backend get-current
t_eq "reading the booted slot succeeds" "$rc" 0
t_eq "the booted slot is the one the firmware reported" "$(said)" B

# A selector file as a human might leave it: comments, spacing, and a section
# order nobody promised. The firmware reads the assignment in the section that
# applies, and so must this.
new_device reads-untidy
{
	echo "# written by hand"
	echo "[tryboot]"
	echo "boot_partition = 2"
	echo "  [all]  "
	echo "tryboot_a_b=1"
	echo "boot_partition=3   # the committed pair"
} >"$autoboot"
run_backend get-primary
t_eq "an untidy selector file is still read correctly" "$(said)" B

# --- staging a candidate ----------------------------------------------------

new_device stages-candidate
mkdir -p "$(dirname "$installing")"
: >"$installing"
run_backend set-primary B
t_eq "staging a candidate succeeds" "$rc" 0
t_eq_text "the committed pair is untouched and the candidate is staged" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 2 3)"
t_eq "the one-shot flag is armed for the next reboot" "$(armed)" "0 tryboot"

# Staging is the last thing an install does, and from here the armed flag is
# what says an update is in flight. The record the install wrote while it was
# writing slots has to go with it, or every configuration change is refused
# until the device is rebooted.
t_eq "and the record of an install in progress is cleared" \
	"$([ -e "$installing" ] && echo present || echo missing)" missing

# Nothing has been committed yet: a device that lost power here comes back on
# the pair it was already running.
run_backend get-primary
t_eq "staging does not change what boots by default" "$(said)" A

# The firmware reads at most 512 bytes of this file, and there is no guarantee
# that rewriting it is atomic — which is survivable only while the file stays
# inside a single sector and the same size from one write to the next.
t_le "the selector file fits the firmware's budget" "$(wc -c <"$autoboot")" 512

staged_size=$(wc -c <"$autoboot")

# The armed flag is RAM, and every verb that reboots this device can take it
# away. What says a trial is owed is on flash beside the refusals, written here
# and read by the shutdown that has to re-arm and by the test suite that has to
# notice a trial nobody ever took.
t_eq "staging is recorded where it survives the reboot" "$(staged_markers)" staged-B

# The install shape, in order. RAUC refuses its target before it writes a byte
# to it and never marks it good again, so staging is the only place that
# refusal can be withdrawn — and until something does, a pair that was
# installed perfectly is indistinguishable from one that was rejected.
new_device stages-over-refusal
run_backend set-state B bad
run_backend get-state B
t_eq "an install's target starts out refused" "$(said)" bad

run_backend set-primary B
t_eq "staging over a refusal succeeds" "$rc" 0
run_backend get-state B
t_eq "and a freshly staged pair is not a refused one" "$(said)" good
t_eq "with the trial it owes recorded" "$(staged_markers)" staged-B

# At most one trial can be owed: the selector file has one [tryboot] section, so
# a staging replaces whatever the last one asked for. An install taken during a
# trial boot targets the other pair, and a marker left behind for the pair being
# replaced is answered by nothing afterwards — the shutdown re-arm would then
# make every reboot for the rest of the device's life a trial.
new_device stages-while-a-trial-is-owed 3 1
: >"${state}/staged-B"
run_backend set-primary A
t_eq "staging while another trial is owed succeeds" "$rc" 0
t_eq "and only the pair just staged owes one" "$(staged_markers)" staged-A

# An install that dies before it stages never reaches this backend's staging
# verb, so its target keeps the refusal — which is the case the refusal marker
# is actually for. It must not read as a trial that is owed.
new_device aborted-install
run_backend set-state B bad
run_backend get-state B
t_eq "an install that never staged leaves its target refused" "$(said)" bad
t_eq "and owes no trial" "$(staged_markers)" "(none)"

# What the previous trial's initramfs left on the selector partition describes
# the pair that is about to be overwritten. Staging is the one verb that holds
# that partition writable on a boot which has already proved itself, so it is
# where the record is cleared; one that outlived its install would be read after
# the next fallback as evidence about a boot that never happened.
new_device stages-over-a-breadcrumb
printf 'trial boot: initramfs reached local-premount\n' >"$breadcrumb"
run_backend set-primary B
t_eq "staging succeeds over a previous trial's record" "$rc" 0
t_eq "and clears it" \
	"$([ -e "$breadcrumb" ] && echo present || echo cleared)" cleared

# --- committing a trial boot ------------------------------------------------

# The trial boot came up on B and reached the health gate: B becomes the pair
# the firmware boots by default, and the pair it was replacing becomes the
# candidate for next time.
new_device commits-trial 3 1
run_backend set-primary B
run_backend set-state B good
t_eq "committing succeeds" "$rc" 0
t_eq_text "the pair that proved itself is now the committed one" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 3 2)"
# The commit path notes a selector it had to repair, and that note is the fleet's
# only evidence that a FAT rewrite ever corrupted one. A commit of an undamaged
# selector rewrites the file too, so the note is all that separates the two — one
# that fired on every update would turn the evidence into background noise.
t_lacks "and a commit of an undamaged selector reports no damage" \
	"$(cat "$err")" "belongs to no slot"

run_backend get-primary
t_eq "the committed slot is the one that was tried" "$(said)" B
t_eq "committing leaves no armed flag behind" "$(armed)" "(not armed)"

# The trial has been answered, so the record of one being owed goes with it. A
# marker outliving its commit would tell the next ordinary shutdown to arm a
# trial of a pair that is already the committed one.
t_eq "and no trial still owed" "$(staged_markers)" "(none)"
t_eq "the committed file is the same size as the staged one" \
	"$(wc -c <"$autoboot")" "$staged_size"

# Marking good a slot that is already committed is what happens on any boot
# that runs the commit twice. It must change nothing at all: a needless rewrite
# of this file is a needless chance to corrupt it.
before=$(cat "$autoboot")
run_backend set-state B good
t_eq "committing the running slot again succeeds" "$rc" 0
t_eq_text "and rewrites nothing" "$(cat "$autoboot")" "$before"

# Only the pair that is running can have proved itself. Declaring the other one
# good — which an install does to its target as it goes, and which an operator
# can do by hand — must not quietly make an untried pair the default.
run_backend set-state A good
t_eq "declaring the other pair good succeeds" "$rc" 0
t_eq_text "and commits nothing" "$(cat "$autoboot")" "$before"

# The same move against a pair that is staged and has not booted yet: it
# withdraws a refusal and nothing more. Only the boot itself can answer the
# trial, so the record of one being owed has to survive being told the pair is
# fine by something that never ran it.
new_device withdraws-refusal-while-staged
run_backend set-primary B
run_backend set-state B good
t_eq "declaring a staged pair good from the other one succeeds" "$rc" 0
t_eq "and leaves the trial owed" "$(staged_markers)" staged-B

# And a firmware that reported nothing at all. There is then no answer to "is
# this the running pair", and the dangerous reading is the reassuring one: a
# commit that reports success and commits nothing leaves the update to be
# rolled back by the deadman ten minutes later, with no sign of why.
new_device commits-without-firmware-report 3 1
run_backend set-primary B
before=$(cat "$autoboot")
rm -f "${dt}/partition"
run_backend set-state B good
t_fails "committing without knowing what booted fails" "$rc" "$(cat "$err")"
t_eq_text "and commits nothing" "$(cat "$autoboot")" "$before"
t_eq "and leaves the trial owed" "$(staged_markers)" staged-B

# A commit that reaches the selector partition and cannot write it — the mount
# failed, or the write did. Nothing is committed, so the trial is still
# unanswered and the record of it has to survive: an install taken on this boot
# would overwrite the pair the device is still falling back to, and the marker
# is what the pre-install gate reads to refuse one. Hence the order the marker is
# removed in, which is the whole of what this case pins.
new_device commits-without-a-writable-selector 3 1
run_backend set-primary B
autoboot="${root}/gone/autoboot.txt"
run_backend set-state B good
t_fails "committing without being able to write the selector fails" "$rc" "$(cat "$err")"
t_eq "and leaves the trial owed" "$(staged_markers)" staged-B
t_eq "and the flag stays armed, so the next reboot is the trial again" \
	"$(armed)" "0 tryboot"

# The runbook quotes these repair notes verbatim, as the string an operator greps
# during an incident to see what the commit found. The drift between the two is
# invisible until then, so it is asserted rather than trusted: the line this run
# printed, with the partition number reduced to the placeholder the doc writes it
# with, has to appear in the shipped runbook.
runbook_quotes() {
	local printed
	printed=$(sed -n 's/^[^:]*: \(the selector named .*rewriting it\)$/\1/p' "$err" |
		sed 's/boot_partition [0-9][0-9]*/boot_partition <n>/')
	t_eq "and the runbook quotes the line it printed" \
		"$(grep -cF "$printed" "${BRENN_REPO_ROOT}/docs/update.md")" 1
}

# A selector file naming no committed pair — what a power cut during the one
# write with no atomicity guarantee can leave on a partition the firmware still
# boots from. On this path falling through is the repair, not a guess: the pair
# being committed has just proved itself on a boot that succeeded, and the write
# names it. Failing instead would leave the unreadable file in place with the
# trial unanswered, and the deadman would reboot ten minutes later into whatever
# the firmware makes of it.
new_device commits-with-no-committed-pair 3 1
printf '0 tryboot\n' >"$reboot_param"
: >"${state}/staged-B"
printf '[all]\ntryboot_a_b=1\n' >"$autoboot"
run_backend set-state B good
t_eq "committing against a selector naming no committed pair succeeds" "$rc" 0
# The rewrite alone says nothing: an unread selector compares unequal to the
# running pair too, so the write happens either way. What separates a deliberate
# repair from a lucky one is the line saying so, and on a device with no console
# that line is the whole record that the file was ever damaged.
t_has "and says it repaired the selector rather than tripping over it" \
	"$(cat "$err")" "the selector named no committed pair; rewriting it"
runbook_quotes
t_eq_text "and rewrites it to name the pair that proved itself" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 3 2)"
t_eq "with the trial answered" "$(staged_markers)" "(none)"
t_eq "and no armed flag left behind" "$(armed)" "(not armed)"

# The same damage one digit over: a committed value that reads cleanly and names
# a partition belonging to neither pair. The repair is identical — the pair being
# committed has just proved itself — but this value compares unequal to the
# running pair exactly as a routine commit does, so the only thing separating the
# two in a journal is the line saying which one it was. On a fleet where a FAT
# rewrite is the one write with no atomicity guarantee, that line is the evidence
# that the corruption is real and happening.
new_device commits-with-an-alien-committed-pair 3 1
printf '0 tryboot\n' >"$reboot_param"
: >"${state}/staged-B"
# The shape a staging leaves, with the committed value corrupted: the candidate
# line still names the pair this boot came up on, so the repair has to change both
# lines and the comparison below covers the whole file.
tryboot_autoboot_text 9 3 >"$autoboot"
run_backend set-state B good
t_eq "committing against a selector naming a partition of neither pair succeeds" \
	"$rc" 0
# This run's own stderr, not the whole suite's: the refusal path dies with the
# same words, so a wider read would pass on another case's output.
t_has "and says which value it found rather than logging a routine commit" \
	"$(cat "$err")" "boot_partition 9, which belongs to no slot; rewriting it"
runbook_quotes
t_eq_text "and rewrites it to name the pair that proved itself" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 3 2)"
t_eq "with the trial answered" "$(staged_markers)" "(none)"
t_eq "and no armed flag left behind" "$(armed)" "(not armed)"

# --- refusing a slot --------------------------------------------------------

new_device refuses-slot
run_backend get-state B
t_eq "a slot nobody refused is good" "$(said)" good

run_backend set-state B bad
t_eq "refusing a slot succeeds" "$rc" 0
run_backend get-state B
t_eq "a refused slot reports bad" "$(said)" bad

run_backend get-state A
t_eq "refusing one slot says nothing about the other" "$(said)" good

# A refusal is the other answer a staged trial can get, and it ends the trial as
# firmly as a commit does: whoever refused the pair is not asking for it to be
# booted once more on the way out.
new_device refuses-staged-slot
run_backend set-primary B
run_backend set-state B bad
t_eq "refusing a staged pair answers its trial" "$(staged_markers)" "(none)"
run_backend get-state B
t_eq "and the pair reads refused" "$(said)" bad

# Refusing the slot the firmware boots by default has to move the default, or
# the refusal means nothing.
new_device refuses-committed
run_backend set-primary B
run_backend set-state A bad
t_eq_text "refusing the committed slot moves the default to the other one" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 3 2)"

# A refusal is a decision, so it ends the same way a commit does. An armed flag
# surviving it turns the next ordinary reboot into a trial of whatever happens
# to be staged — and an install reaches here as a matter of course, since RAUC
# refuses its target slot before it writes to it.
t_eq "refusing a slot leaves no armed flag behind" "$(armed)" "(not armed)"

# And a slot can come back: an installed update over a slot that was once
# refused is a new system, and the old verdict must not outlive it. This device
# is running A, so declaring it good is also a commit.
run_backend set-state A good
run_backend get-state A
t_eq "committing a refused slot clears the refusal" "$(said)" good
t_eq_text "and the running pair is the committed one again" \
	"$(cat "$autoboot")" "$(tryboot_autoboot_text 2 3)"

# The same unreadable selector on the refusal path, where falling through would
# lie: the empty reading compares as "some other pair is committed", so refusing
# the committed pair would report success and leave the default naming the pair
# just refused. `rauc status mark-bad` is the manual escape hatch on a device
# with no console, and exit-0-while-doing-nothing is the worst shape it can fail
# in. What the refusal already did before reaching the selector stands: the
# marker is written, the trial is answered, and the flag is shed — the one thing
# that would otherwise boot the refused pair again.
new_device refuses-with-no-committed-pair 3 1
printf '0 tryboot\n' >"$reboot_param"
: >"${state}/staged-B"
printf '[all]\ntryboot_a_b=1\n' >"$autoboot"
before=$(cat "$autoboot")
run_backend set-state B bad
t_fails "refusing against a selector naming no committed pair fails" "$rc" \
	"$(cat "$err")"
t_eq_text "and leaves the selector as it found it" "$(cat "$autoboot")" "$before"
t_eq "and the trial is answered all the same" "$(staged_markers)" "(none)"
t_eq "and the flag is disarmed, so no reboot re-enters the refused pair" \
	"$(armed)" "(not armed)"
run_backend get-state B
t_eq "and the refusal is on record" "$(said)" bad

# The same corruption one digit over: a committed value that names neither pair.
# Taken at face value it compares as "some other pair is committed", so the verb
# would report success without moving anything — while the runbook's next step
# tells the operator to reboot on the strength of the selector still naming the
# committed pair. What the firmware makes of a partition belonging to no slot is
# established nowhere.
new_device refuses-with-an-alien-committed-pair 3 1
printf '0 tryboot\n' >"$reboot_param"
: >"${state}/staged-B"
printf '[all]\ntryboot_a_b=1\nboot_partition=8\n[tryboot]\nboot_partition=3\n' >"$autoboot"
before=$(cat "$autoboot")
run_backend set-state B bad
t_fails "refusing against a selector naming a partition of neither pair fails" \
	"$rc" "$(cat "$err")"
t_has "and names the value it could not place" \
	"$(cat "$err")" "boot_partition 8 belongs to no slot"
t_eq_text "and leaves the selector as it found it" "$(cat "$autoboot")" "$before"
t_eq "and the trial is answered all the same" "$(staged_markers)" "(none)"
t_eq "and the flag is disarmed here too" "$(armed)" "(not armed)"
run_backend get-state B
t_eq "and this refusal is on record as well" "$(said)" bad

# The other side of a refusal that fails, and the one the runbook reads the state
# directory to tell apart: a failure before the refusal is recorded at all. The
# label lookup is the first thing the verb does, so nothing it would have written
# is written — the refusal is absent, the trial is still owed, and the flag that
# re-enters the candidate is still armed. An operator is told to conclude "nothing
# this step wanted has happened" from exactly those three readings, so the order
# the backend does its work in is what makes that conclusion true.
new_device refuses-before-anything-is-recorded 3 1
printf '0 tryboot\n' >"$reboot_param"
: >"${state}/staged-B"
rm -f "${slots}/boot_b"
run_backend set-state B bad
t_fails "refusing a pair whose label has gone fails" "$rc" "$(cat "$err")"
t_has "and blames the label" "$(cat "$err")" "no partition labelled boot_b"
t_eq "with no refusal recorded" \
	"$([ -e "${state}/bad-B" ] && echo recorded || echo "(none)")" "(none)"
t_eq "the trial still owed" "$(staged_markers)" staged-B
t_eq "and the flag still armed, so the next reboot re-enters the candidate" \
	"$(armed)" "0 tryboot"

# --- refusing to guess ------------------------------------------------------

new_device rejects-nonsense
before=$(cat "$autoboot")

run_backend set-primary C
t_fails "an unknown bootname fails" "$rc" "$(cat "$err")"
t_eq_text "and changes nothing" "$(cat "$autoboot")" "$before"

run_backend frobnicate
t_fails "an unknown verb fails" "$rc" "$(cat "$err")"

# A selector file with no committed pair is a device whose next boot is the
# firmware's guess. Writing a default over it would be inventing one.
printf '[all]\ntryboot_a_b=1\n' >"$autoboot"
run_backend get-primary
t_fails "a selector file with no committed pair fails" "$rc" "$(cat "$err")"
# Failing is half of it. The reading the runbook sends an operator after is the
# backend's own line, so blaming a partition lookup that found nothing — which
# is what an empty value reaching bootname_of_partition produces — sends them
# after a GPT label problem that does not exist.
t_has "and blames the selector" "$(cat "$err")" "no committed boot_partition in"
t_lacks "rather than a partition lookup" "$(cat "$err")" "belongs to no slot"

# A missing label is a layout that is not the one this backend was written for.
new_device rejects-unlabelled
rm -f "${slots}/boot_b"
run_backend set-primary B
t_fails "a missing partition label fails" "$rc" "$(cat "$err")"

# --- was this a trial boot? -------------------------------------------------

# Everything that commits or gives up is gated on this answer, so a wrong one
# in either direction is expensive: yes on an ordinary boot writes flash for
# nothing and arms a deadman against a system nobody is trying, no on a trial
# boot leaves a candidate that can never be committed.
check_tryboot() {
	rc=0
	BRENN_TRYBOOT_DT_DIR="$dt" "$tryboot_check" >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] && echo trial || echo ordinary
}

new_device ordinary-boot 2 0
t_eq "a boot with the flag clear is an ordinary boot" "$(check_tryboot)" ordinary

new_device trial-boot 3 1
t_eq "a boot with the flag set is a trial boot" "$(check_tryboot)" trial

new_device boot-without-firmware-report
rm -f "${dt}/tryboot"
t_eq "a firmware that reported nothing is not a trial boot" "$(check_tryboot)" ordinary

# --- giving up on a trial ---------------------------------------------------

run_deadman() {
	rc=0
	BRENN_TRYBOOT_SLOT_DIR="$slots" \
		BRENN_TRYBOOT_DT_DIR="$dt" \
		BRENN_TRYBOOT_AUTOBOOT="$autoboot" \
		BRENN_TRYBOOT_STATE_DIR="$state" \
		BRENN_TRYBOOT_REBOOT_PARAM="$reboot_param" \
		BRENN_RAUC_INSTALLING="$installing" \
		BRENN_TRYBOOT_BACKEND="$backend" \
		BRENN_DEADMAN_REBOOT="${root}/reboot" \
		"$deadman" >"$out" 2>"$err" || rc=$?
}

install_fake_reboot() {
	cat >"${root}/reboot" <<-EOF
		#!/bin/sh
		echo rebooted >"${root}/rebooted"
	EOF
	chmod 0755 "${root}/reboot"
}

# The candidate came up, the deadman fired, and nothing had committed. The
# reboot lands on the committed pair, because that is the one the selector file
# still names.
new_device deadman-uncommitted 3 1
install_fake_reboot
run_deadman
t_eq "an uncommitted trial is rebooted out of" \
	"$(cat "${root}/rebooted" 2>/dev/null || echo "stayed up")" rebooted

# The same boot, after a commit: the deadman finds nothing to do, which is what
# every successful update looks like ten minutes in.
new_device deadman-committed 3 1
install_fake_reboot
run_backend set-state B good
run_deadman
t_eq "a committed trial is left alone" "$rc" 0
t_eq "and stays up" \
	"$(cat "${root}/rebooted" 2>/dev/null || echo "stayed up")" "stayed up"

# The deadman cannot answer its own question if the backend will not answer
# either, and guessing in either direction is worse than failing: reboot and a
# healthy trial loses its commit, stay up and an unreachable one is the running
# system. Failing is what the unit's retry is there to pick up.
new_device deadman-without-firmware-report 3 1
install_fake_reboot
rm -f "${dt}/partition"
run_deadman
t_fails "a deadman that cannot tell what booted fails" "$rc" "$(cat "$err")"
t_eq "and does not reboot on a guess" \
	"$(cat "${root}/rebooted" 2>/dev/null || echo "stayed up")" "stayed up"

# --- keeping a staged trial armed -------------------------------------------

# Staging arms the next boot by writing a file in RAM, and three of the verbs
# that reboot this device delete that file while parsing their own arguments.
# The marker on flash is the durable half, and this runs from the shutdown to
# write the RAM half again from it — so what decides whether a trial happens is
# what was installed, not which word the operator typed.

run_rearm() {
	rc=0
	BRENN_TRYBOOT_STATE_DIR="$state" \
		BRENN_TRYBOOT_REBOOT_PARAM="$reboot_param" \
		BRENN_TRYBOOT_CHECK="$tryboot_check" \
		BRENN_TRYBOOT_DT_DIR="$dt" \
		"$rearm" >"$out" 2>"$err" || rc=$?
}

# The staging boot, going down under a verb that deleted the arming.
new_device rearm-after-a-verb-erased-it
run_backend set-primary B
rm -f "$reboot_param"
run_rearm
t_eq "re-arming a staged trial succeeds" "$rc" 0
t_eq "and the next boot is the trial after all" "$(armed)" "0 tryboot"

# A device with nothing owed is every device most of the time. Arming one on
# the way down would make the next ordinary reboot a trial of whatever the
# selector file happens to name.
new_device rearm-with-nothing-staged
run_rearm
t_eq "a shutdown with no trial owed succeeds" "$rc" 0
t_eq "and arms nothing" "$(armed)" "(not armed)"

# The trial boot itself, being rebooted out of by the deadman: the marker is
# still there, because only a commit or a refusal removes it. Arming here would
# send the device back into the candidate it is giving up on, every ten
# minutes, instead of home to the committed pair.
new_device rearm-during-the-trial 3 1
: >"${state}/staged-B"
run_rearm
t_eq "a shutdown during the trial itself succeeds" "$rc" 0
t_eq "and leaves the fallback alone" "$(armed)" "(not armed)"

# --- what a trial boot leaves behind ----------------------------------------

# A candidate that dies before the network is up says nothing: no serial, no
# display, no journal that survives. The initramfs writes one file on the
# selector partition so that a fallback can be told from a trial that was never
# taken — and so that "died before the initramfs" is a reading rather than a
# guess.

run_breadcrumb() {
	rc=0
	BRENN_TRYBOOT_DT_DIR="$dt" \
		BRENN_TRYBOOT_CHECK="$tryboot_check" \
		BRENN_TRYBOOT_ROOT_LINK="${slots}/system_a" \
		BRENN_TRYBOOT_BREADCRUMB="$breadcrumb" \
		"$breadcrumb_writer" local-premount >"$out" 2>"$err" || rc=$?
}

crumbs() {
	[ -f "$breadcrumb" ] && cat "$breadcrumb" || echo "(none)"
}

# mkinitramfs asks every boot script what has to run before it, and drops the
# ones that answer badly. A script that is silently not in the initramfs is the
# failure this whole record exists to rule out.
new_device breadcrumb-declares-its-prerequisites 3 1
rc=0
prereqs=$("$breadcrumb_writer" prereqs 2>"$err") || rc=$?
t_eq "the writer answers the prerequisites question" "$rc" 0
t_eq "with nothing to run before it" "$prereqs" ""

# An ordinary boot writes no flash at all, and the partition the firmware reads
# to find a bootable system is the last place to make an exception.
new_device breadcrumb-on-an-ordinary-boot 2 0
run_breadcrumb
t_eq "an ordinary boot's initramfs succeeds" "$rc" 0
t_eq "and leaves nothing behind" "$(crumbs)" "(none)"

# The trial boot itself: the record says the initramfs ran, which pair the
# firmware handed over to, and what it found where the root filesystem should
# be. Absent after a fallback, that means the boot died earlier than this.
new_device breadcrumb-on-a-trial-boot 3 1
run_breadcrumb
t_eq "a trial boot's initramfs succeeds" "$rc" 0
t_has "and records that it got as far as the root check" \
	"$(crumbs)" "initramfs reached local-premount"
t_has "which pair the firmware handed over to" \
	"$(crumbs)" "firmware booted partition 3"
t_has "and what the root slot resolved to" \
	"$(crumbs)" "system_a -> "

# The reading the A/B root check reboots on, taken before it does. Without it
# the one failure the check exists for is also the one that leaves no evidence.
new_device breadcrumb-without-a-root-slot 3 1
rm -f "${slots}/system_a"
run_breadcrumb
t_eq "a trial boot with no root slot still succeeds" "$rc" 0
t_has "and records that the link was missing" "$(crumbs)" "absent"

# Written, not appended. A staging buys exactly one trial boot, so there is
# never a second record to keep — and a file on the selector partition that can
# grow is a file that can fill the partition the firmware reads.
new_device breadcrumb-is-rewritten 3 1
run_breadcrumb
run_breadcrumb
t_eq "a second trial boot rewrites the record rather than growing it" \
	"$(wc -l <"$breadcrumb")" 3

# The instrumentation must never be the reason a boot fails. A selector that
# cannot be written is a diagnostic that is missing, not a device that is down.
new_device breadcrumb-that-cannot-be-written 3 1
breadcrumb="${root}/nonexistent/brenn-trial.log"
run_breadcrumb
t_eq "a trial boot whose record cannot be written carries on" "$rc" 0

# A firmware that reported no partition. The record is still worth writing: what
# it says about the root slot is the reading the check below it reboots on, and
# a named gap reads better than a line that is not there.
new_device breadcrumb-without-a-firmware-report 3 1
rm -f "${dt}/partition"
run_breadcrumb
t_eq "a trial boot whose firmware reported no partition still records" "$rc" 0
t_has "saying so in the line that would have named it" \
	"$(crumbs)" "firmware booted partition unreported"

# This host runs GNU coreutils; the initramfs runs klibc's readlink, which need
# not take -f. The most useful line of the record must not turn into the word
# "unresolvable" there, so the immediate target is the answer when full
# resolution is unavailable.
new_device breadcrumb-without-readlink-f 3 1
stub_bin="${root}/bin"
mkdir -p "$stub_bin"
real_readlink=$(command -v readlink)
cat >"${stub_bin}/readlink" <<-STUB
	#!/bin/sh
	[ "\$1" = "-f" ] && exit 1
	exec "${real_readlink}" "\$@"
STUB
chmod 0755 "${stub_bin}/readlink"
saved_path=$PATH
PATH="${stub_bin}:${PATH}"
run_breadcrumb
PATH=$saved_path
t_eq "a trial boot whose readlink has no -f still records" "$rc" 0
t_has "and names what the root slot points at" \
	"$(crumbs)" "system_a -> ../../mmcblk0p4"

# --- the same, by the path a device takes -----------------------------------

# Every case above hands the writer a record by path. On a device it has none:
# the selector is found by its GPT label, mounted, written and released, and
# that sequence is the one that must not fail a boot. mount and umount are
# called by name and the mount point is overridable, so a stub on PATH drives
# the whole of it.

crumb_file=brenn-trial.log

# Any block device on this host stands in for the selector partition: the writer
# refuses one that is not, and nothing is mounted, since mount itself is a stub.
block_device=""
for entry in /sys/block/*; do
	[ -e "$entry" ] || continue
	if [ -b "/dev/${entry##*/}" ]; then
		block_device="/dev/${entry##*/}"
		break
	fi
done

# <status> is what the stub mount exits with; <copy>, if given, is a file it
# leaves at the mount point, standing in for what is already on the partition.
new_mount_stubs() {
	local status=${1:-0} copy=${2:-}
	stub_bin="${root}/bin"
	mkdir -p "$stub_bin"
	cat >"${stub_bin}/mount" <<-STUB
		#!/bin/sh
		printf '%s\n' "\$*" >>"${root}/mount-args"
		for target in "\$@"; do :; done
		[ -z "${copy}" ] || cp "${copy}" "\${target}/${crumb_file}"
		exit ${status}
	STUB
	cat >"${stub_bin}/umount" <<-STUB
		#!/bin/sh
		printf '%s\n' "\$*" >>"${root}/umount-args"
		exit 0
	STUB
	chmod 0755 "${stub_bin}/mount" "${stub_bin}/umount"
}

mounted_args() {
	cat "${root}/mount-args" 2>/dev/null || echo "(nothing was mounted)"
}

unmounted_args() {
	cat "${root}/umount-args" 2>/dev/null || echo "(nothing was unmounted)"
}

mount_target() {
	awk 'END { print $NF }' "${root}/mount-args" 2>/dev/null
}

run_breadcrumb_mounting() {
	rc=0
	PATH="${stub_bin}:${PATH}" \
		BRENN_TRYBOOT_DT_DIR="$dt" \
		BRENN_TRYBOOT_CHECK="$tryboot_check" \
		BRENN_TRYBOOT_ROOT_LINK="${slots}/system_a" \
		BRENN_TRYBOOT_SLOT_DIR="$slots" \
		BRENN_TRYBOOT_MOUNT_POINT="${root}/mnt" \
		"$breadcrumb_writer" local-premount >"$out" 2>"$err" || rc=$?
}

# A label that resolves to something which is not a block device is a layout
# this writer was not written for, and a boot is not the place to discover that
# by mounting it.
new_device breadcrumb-without-a-block-selector 3 1
new_mount_stubs
run_breadcrumb_mounting
t_eq "a trial boot whose selector is not a block device carries on" "$rc" 0
t_eq "and mounts nothing" "$(mounted_args)" "(nothing was mounted)"
t_eq "and writes nothing" \
	"$([ -e "${root}/mnt/${crumb_file}" ] && echo present || echo none)" none

if [ -n "$block_device" ]; then
	new_device breadcrumb-mounts-the-selector 3 1
	ln -sf "$block_device" "${slots}/bootconfig"
	new_mount_stubs
	run_breadcrumb_mounting
	t_eq "a trial boot mounts the selector by label and records on it" "$rc" 0
	t_has "writable, and only for as long as the write takes" \
		"$(mounted_args)" "-t vfat -o rw ${slots}/bootconfig ${root}/mnt"
	t_has "the record is on the partition that was mounted" \
		"$(cat "${root}/mnt/${crumb_file}" 2>/dev/null || echo "(no record)")" \
		"initramfs reached local-premount"
	t_has "and the mount is released again" "$(unmounted_args)" "${root}/mnt"

	# The failure this whole path has to survive: the diagnostic is missing,
	# the boot is not.
	new_device breadcrumb-selector-will-not-mount 3 1
	ln -sf "$block_device" "${slots}/bootconfig"
	new_mount_stubs 1
	run_breadcrumb_mounting
	t_eq "a trial boot whose selector will not mount carries on" "$rc" 0
	t_eq "and unmounts nothing it never mounted" \
		"$([ -e "${root}/umount-args" ] && echo unmounted || echo none)" none
else
	echo "SKIP  no block device on this host to stand in for the selector partition"
fi

# --- carrying it off the device ---------------------------------------------

# The record is written by a boot that may not have survived and read by the
# next one that did. Reading means the journal, which leaves the device the same
# way every other line does.

run_report() {
	rc=0
	BRENN_TRYBOOT_BREADCRUMB="$breadcrumb" \
		"$reporter" >"$out" 2>"$err" || rc=$?
}

new_device reports-a-breadcrumb
printf 'trial boot: initramfs reached local-premount\ntrial boot: firmware booted partition 3\n' \
	>"$breadcrumb"
run_report
t_eq "reporting a record succeeds" "$rc" 0
t_has "and puts it where the journal will take it" \
	"$(cat "$err")" "firmware booted partition 3"

# Every boot after the record has been cleared, which is most of them. Saying so
# is the point: silence would read the same as a reporter that is not running.
new_device reports-nothing-when-there-is-nothing
run_report
t_eq "reporting with no record succeeds" "$rc" 0
t_has "and says there is none" "$(cat "$err")" "no trial breadcrumb"

# A record cut off mid-write — a power cut or a reset during the very boot this
# exists to explain — ends without a newline, and that last partial line is the
# one worth the most.
new_device reports-a-record-cut-off-mid-write
printf 'trial boot: initramfs reached local-premount' >"$breadcrumb"
run_report
t_eq "reporting a record with no final newline succeeds" "$rc" 0
t_has "and the line the dying boot got out is reported too" \
	"$(cat "$err")" "initramfs reached local-premount"

# And the reporter's own device path: the selector found by label, mounted
# read-only, released. An ordinary boot writes no flash, and this runs on every
# one of them.

run_report_mounting() {
	rc=0
	PATH="${stub_bin}:${PATH}" \
		BRENN_TRYBOOT_SLOT_DIR="$slots" \
		"$reporter" >"$out" 2>"$err" || rc=$?
}

new_device reports-from-the-selector
printf 'trial boot: initramfs reached local-premount\ntrial boot: firmware booted partition 3\n' \
	>"${root}/record"
new_mount_stubs 0 "${root}/record"
run_report_mounting
t_eq "reporting from the selector succeeds" "$rc" 0
t_has "and mounts it read-only, which is what an ordinary boot may do" \
	"$(mounted_args)" "-t vfat -o ro,noatime"
t_has "the record reaches the journal" "$(cat "$err")" "firmware booted partition 3"
t_has "and the mount is released again" "$(unmounted_args)" "$(mount_target)"

# Every boot after the record has been cleared, which is most of them: nothing
# to say, said, and the temporary mount point taken away with it.
new_device reports-from-a-selector-with-no-record
new_mount_stubs
run_report_mounting
t_eq "reporting from a selector holding no record succeeds" "$rc" 0
t_has "and says there is none" "$(cat "$err")" "no trial breadcrumb"
t_eq "and the temporary mount point is gone" \
	"$([ -d "$(mount_target)" ] && echo present || echo gone)" gone

# Neither of the two ways the read can fail may fail the boot doing it: this
# runs on every ordinary boot, and a report nobody asked for is not worth one.
new_device reports-when-the-selector-will-not-mount
new_mount_stubs 1
run_report_mounting
t_eq "a selector that will not mount does not fail the boot" "$rc" 0
t_has "and says which one it could not read" "$(cat "$err")" "cannot mount"

new_device reports-without-a-slot-directory
new_mount_stubs
slots="${root}/dev/disk/absent"
run_report_mounting
t_eq "a slot directory that is not there does not fail the boot either" "$rc" 0
t_has "and names the label it went looking for" \
	"$(cat "$err")" "no partition labelled bootconfig"

t_done
