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

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/rauc.rootfs-overlay"
backend="${overlay}/usr/lib/rauc/rpi-tryboot-backend"
tryboot_check="${overlay}/usr/lib/brenn/brenn-tryboot-check"
deadman="${overlay}/usr/lib/brenn/brenn-trial-deadman"

for prog in "$backend" "$tryboot_check" "$deadman"; do
	if [ ! -x "$prog" ]; then
		t_fail "the trial machinery is present and executable" "not at ${prog}"
		t_done
	fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The layout this profile ships: the selector partition first, then the two
# boot partitions. The backend is told none of this — it reads the labels.
declare -A partition_of=(
	[bootconfig]=1
	[boot_a]=2
	[boot_b]=3
	[system_a]=4
	[system_b]=5
	[persistent]=6
)

# The file the firmware reads, in the shape the image ships it and the shape
# the backend must keep it in. Written out here as well as in the image
# expectations on purpose: one says what the build produced, this says what the
# update mechanism leaves behind, and the firmware needs them to be the same
# thing.
autoboot_text() {
	printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' "$1" "$2"
}

root=""
slots=""
dt=""
autoboot=""
state=""
reboot_param=""
installing=""
out=""
err=""
rc=0

# A fresh device per case, so no case can pass on what another one left behind.
new_device() {
	root="${work}/$1"
	slots="${root}/dev/disk/by-partlabel"
	dt="${root}/dt"
	autoboot="${root}/autoboot.txt"
	state="${root}/data/rauc"
	reboot_param="${root}/run/systemd/reboot-param"
	installing="${root}/run/brenn/rauc-installing"
	out="${root}/out"
	err="${root}/err"

	mkdir -p "$slots" "$dt" "$state" "${root}/dev" "${root}/run/systemd"
	local label
	for label in "${!partition_of[@]}"; do
		: >"${root}/dev/mmcblk0p${partition_of[$label]}"
		ln -sf "../../mmcblk0p${partition_of[$label]}" "${slots}/${label}"
	done

	# What the firmware reports about the boot it just did: the partition it
	# booted, and whether it took the one-shot path. Both are 32-bit
	# big-endian, as they arrive in the device tree.
	dt_u32 partition "${2:-2}"
	dt_u32 tryboot "${3:-0}"

	autoboot_text "${4:-2}" "${5:-3}" >"$autoboot"
}

dt_u32() {
	local value=$2 escapes
	escapes=$(printf '\\%03o\\%03o\\%03o\\%03o' \
		$(((value >> 24) & 255)) $(((value >> 16) & 255)) \
		$(((value >> 8) & 255)) $((value & 255)))
	printf '%b' "$escapes" >"${dt}/$1"
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
	"$(cat "$autoboot")" "$(autoboot_text 2 3)"
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

# --- committing a trial boot ------------------------------------------------

# The trial boot came up on B and reached the health gate: B becomes the pair
# the firmware boots by default, and the pair it was replacing becomes the
# candidate for next time.
new_device commits-trial 3 1
run_backend set-primary B
run_backend set-state B good
t_eq "committing succeeds" "$rc" 0
t_eq_text "the pair that proved itself is now the committed one" \
	"$(cat "$autoboot")" "$(autoboot_text 3 2)"
run_backend get-primary
t_eq "the committed slot is the one that was tried" "$(said)" B
t_eq "committing leaves no armed flag behind" "$(armed)" "(not armed)"
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

# And a firmware that reported nothing at all. There is then no answer to "is
# this the running pair", and the dangerous reading is the reassuring one: a
# commit that reports success and commits nothing leaves the update to be
# rolled back by the deadman ten minutes later, with no sign of why.
new_device commits-without-firmware-report 3 1
run_backend set-primary B
before=$(cat "$autoboot")
rm -f "${dt}/partition"
run_backend set-state B good
t_eq "committing without knowing what booted fails" \
	"$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed
t_eq_text "and commits nothing" "$(cat "$autoboot")" "$before"

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

# Refusing the slot the firmware boots by default has to move the default, or
# the refusal means nothing.
new_device refuses-committed
run_backend set-primary B
run_backend set-state A bad
t_eq_text "refusing the committed slot moves the default to the other one" \
	"$(cat "$autoboot")" "$(autoboot_text 3 2)"

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
	"$(cat "$autoboot")" "$(autoboot_text 2 3)"

# --- refusing to guess ------------------------------------------------------

new_device rejects-nonsense
before=$(cat "$autoboot")

run_backend set-primary C
t_eq "an unknown bootname fails" "$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed
t_eq_text "and changes nothing" "$(cat "$autoboot")" "$before"

run_backend frobnicate
t_eq "an unknown verb fails" "$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed

# A selector file with no committed pair is a device whose next boot is the
# firmware's guess. Writing a default over it would be inventing one.
printf '[all]\ntryboot_a_b=1\n' >"$autoboot"
run_backend get-primary
t_eq "a selector file with no committed pair fails" \
	"$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed

# A missing label is a layout that is not the one this backend was written for.
new_device rejects-unlabelled
rm -f "${slots}/boot_b"
run_backend set-primary B
t_eq "a missing partition label fails" \
	"$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed

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
t_eq "a deadman that cannot tell what booted fails" \
	"$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed
t_eq "and does not reboot on a guess" \
	"$(cat "${root}/rebooted" 2>/dev/null || echo "stayed up")" "stayed up"

t_done
