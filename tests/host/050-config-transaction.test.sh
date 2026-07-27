#!/usr/bin/env bash
#
# Changing configuration on a running device, end to end, off the device.
#
# Installing a candidate, booting it, committing it — or not committing it, and
# getting the previous one back. Every branch of that is a branch nobody wants
# to discover on hardware: the failure it exists for is a device that has just
# been given credentials that do not work, which is the same device that cannot
# be reached to say so.
#
# The three programs of the transaction are exercised together with the boot
# selector, because the property that matters is not what any one of them does
# but what the sequence leaves behind — and because the ways they can disagree
# (an attempt record left over, a candidate committed that nothing booted) are
# invisible in any single one of them.
#
# Split in two by what it costs to run. Installing a generation sets ownership,
# which needs uid 0; everything the boot then does with one does not. The
# boot-time half therefore builds its store by hand and runs unconditionally,
# so a host without user namespaces loses the cases that write a generation
# rather than the whole file — a lane that skips itself out of a gate is a
# green result that checked nothing.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/generation.sh
. "${BRENN_TESTS_LIB}/generation.sh"

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn"
apply="${overlay}/brenn-config-apply"
commit="${overlay}/brenn-config-commit"
deadman="${overlay}/brenn-config-deadman"
select_bin="${overlay}/brenn-config-select"
validate="${overlay}/brenn-config-validate"
installer="${overlay}/brenn-config-install"
preinstall="${BRENN_REPO_ROOT}/image/layer/brenn/rauc.rootfs-overlay/usr/lib/brenn/brenn-rauc-preinstall"

for bin in "$apply" "$commit" "$deadman" "$select_bin" "$validate" "$installer" "$preinstall"; do
	if [ ! -x "$bin" ]; then
		t_fail "the transaction's programs are present and executable" "not at ${bin}"
		t_done
	fi
done

# A user namespace is the way to have uid 0 without being root. Without one the
# cases that install a generation are not run, and they say so; the rest of the
# file still runs, and still fails this lane if the boot-time half is wrong.
priv=()
can_install=yes
if [ "$(id -u)" -ne 0 ]; then
	if unshare -r true 2>/dev/null; then
		priv=(unshare -r)
	else
		can_install=no
		echo "SKIP  installing a generation needs root or a user namespace;" \
			"the cases that write one are not run"
	fi
fi

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

store=""
runtime=""
link=""
flag=""
out=""
rc=0
apply_reboot=true

# A device with one committed generation, freshly provisioned: what every case
# starts from. The store is built the way scripts/provision.sh leaves it —
# gen-1 in place, committed, nothing on trial.
new_device() {
	local root="${work}/$1"
	store="${root}/data/provisioning"
	runtime="${root}/run/brenn"
	link="${runtime}/provisioning"
	flag="${runtime}/config-trial"
	out="${root}/out"
	apply_reboot=true
	mkdir -p "${store}" "${runtime}"
	# Generations name the published path in the collector's trust anchor, and
	# the contract check derives what it expects from the same place — so the
	# fixture has to be built against this tree's runtime path, not the
	# device's.
	GEN_PUBLISHED="$link"
	gen_make "${store}/gen-1"
	ln -s gen-1 "${store}/active"
}

# A candidate to install: a conformant generation with one value changed, which
# is what a real change is.
new_candidate() {
	local dir="${work}/$1"
	rm -rf "$dir"
	gen_make "$dir"
	printf '%s\n' "${2:-unit-renamed}" >"${dir}/hostname"
	printf '%s' "$dir"
}

# A candidate put into the store directly, without the installer. What the boot
# does with one turns on the links and the attempt record and not on ownership,
# so building it this way is what lets those cases run as an ordinary user.
stage_by_hand() {
	local name=$1
	gen_make "${store}/${name}"
	printf '%s\n' "${2:-unit-renamed}" >"${store}/${name}/hostname"
	rm -f "${store}/trial"
	ln -s "$name" "${store}/trial"
}

run() {
	rc=0
	env BRENN_PROVISIONING_ROOT="$store" \
		BRENN_PROVISIONING_LINK="$link" \
		BRENN_CONFIG_TRIAL_FLAG="$flag" \
		BRENN_CONFIG_VALIDATE="$validate" \
		BRENN_MACHINE_ID_FILE="${runtime}/machine-id" \
		BRENN_HOSTNAME_FILE="${runtime}/hostname" \
		BRENN_APPLY_REBOOT="$apply_reboot" \
		BRENN_DEADMAN_REBOOT="true" \
		"$@" >"$out" 2>&1 || rc=$?
}

# Installing needs uid 0 for the ownership it sets; every other program here
# runs as whoever is running the tests.
run_apply() {
	run "${priv[@]}" "$apply" "$@"
}

# What the store selects, by name, so an assertion reads as the generation
# rather than as a path.
committed() {
	basename "$(readlink -f "${store}/active" 2>/dev/null)" 2>/dev/null
}

candidate_state() {
	if [ -L "${store}/trial" ] || [ -e "${store}/trial" ]; then
		basename "$(readlink -f "${store}/trial")"
	else
		echo none
	fi
}

running() {
	basename "$(readlink -f "$link" 2>/dev/null)" 2>/dev/null
}

present() {
	[ -e "$1" ] && echo present || echo missing
}

# A stand-in for the reboot each of these programs ends with, so that whether
# one happened is a fact a test can read rather than a line in a log.
rebooted=""
arm_fake_reboot() {
	rebooted="${work}/rebooted"
	rm -f "$rebooted"
	cat >"${work}/reboot" <<-EOF
		#!/bin/sh
		echo rebooted >"${rebooted}"
	EOF
	chmod 0755 "${work}/reboot"
	apply_reboot="${work}/reboot"
}

reboot_state() {
	cat "$rebooted" 2>/dev/null || echo "stayed up"
}

# --- the boot-time half, which needs no privilege ----------------------------

# The good path from the boot onwards: a candidate is in the store, this boot
# takes it up, the health gate is reached, and it becomes the committed one.
new_device boot-good
stage_by_hand gen-2

run "$select_bin"
t_eq "the boot with a candidate runs it" "$(running)" gen-2
t_eq "and says so, for the units that only run on such a boot" "$(present "$flag")" present
t_eq "the attempt is recorded" "$(present "${store}/trial-attempted")" present

# Reaching the health gate is what runs this.
run "$commit"
t_eq "committing succeeds" "$rc" 0
t_eq "the candidate becomes the committed generation" "$(committed)" gen-2
t_eq "and is no longer on trial" "$(candidate_state)" none
t_eq "the attempt record does not outlive the transaction" \
	"$(present "${store}/trial-attempted")" missing

# The deadman fires later in the same boot. It has to find nothing to do:
# rebooting a device that committed would be a reboot for no reason, on every
# successful configuration change.
run "$deadman"
t_eq "the deadman leaves a committed trial alone" "$rc" 0
t_contains "and says so" "$(cat "$out")" "the configuration candidate committed; nothing to do"

# And the boot after that runs the new configuration as the committed one.
run "$select_bin"
t_eq "the boot after a commit runs the new configuration" "$(running)" gen-2
t_eq "and is not a trial boot" "$(present "$flag")" missing

# The candidate that never becomes healthy: the gate is not reached, so nothing
# commits, and the timer fires.
new_device boot-bad
stage_by_hand gen-2
run "$select_bin"
t_eq "a candidate that will fail is tried like any other" "$(running)" gen-2

run "$deadman"
t_eq "the deadman reboots a candidate that never committed" "$rc" 0
t_contains "and says why" "$(cat "$out")" \
	"the configuration candidate did not commit; rebooting to the committed generation"

# What the reboot lands on. The attempt is on record, so the candidate is
# discarded rather than tried a second time.
run "$select_bin"
t_eq "the boot after the deadman runs the configuration that worked" "$(running)" gen-1
t_eq "the candidate is discarded" "$(candidate_state)" none
t_eq "and that boot is not a trial boot" "$(present "$flag")" missing

# The discarded generation is still on the device — history costs the space it
# takes — so the operator can fix it and apply it again.
t_eq "the generation that failed is kept" "$(present "${store}/gen-2")" present

# Same shape, without the timer ever running: the trial boot simply ends. The
# record is what makes the next boot revert, and it is written before the
# candidate is used precisely for this.
new_device boot-power-cut
stage_by_hand gen-2
run "$select_bin"
t_eq "the trial boot starts" "$(running)" gen-2
run "$select_bin"
t_eq "a trial boot that just ends reverts on the next one" "$(running)" gen-1
t_eq "and the candidate is gone" "$(candidate_state)" none

# --- what committing refuses -------------------------------------------------

# A boot that is not trying anything. Without this a commit run by hand — or a
# unit whose condition was dropped — would promote whatever happens to be
# staged, unbooted, which is the one thing the trial exists to prevent.
new_device commit-refusals
stage_by_hand gen-2
run "$commit"
t_eq "committing on a boot that is not trying a candidate is refused" "$rc" 1
t_eq "the candidate stays on trial" "$(candidate_state)" gen-2
t_eq "and the committed generation has not moved" "$(committed)" gen-1

# A candidate that changed underneath the boot trying it: the store now offers
# something else, which nothing has booted.
run "$select_bin"
mv "${store}/gen-1" "${store}/gen-9"
rm -f "${store}/trial"
ln -s gen-9 "${store}/trial"
run "$commit"
t_eq "committing a candidate this boot is not running is refused" "$rc" 1
t_contains "and says what it found" "$(cat "$out")" \
	"$(printf 'brenn-config-commit: the candidate (%s) is not what this boot is running (%s); refusing to commit' \
		"${store}/gen-9" "${store}/gen-2")"

# A trial boot whose selection never published anything — the selector failed,
# or the runtime directory was cleared underneath it. There is then no evidence
# of what this boot is actually running, and committing on the store's word
# alone would promote a generation nothing booted.
new_device commit-unpublished
stage_by_hand gen-2
mkdir -p "$(dirname "$flag")"
: >"$flag"
run "$commit"
t_eq "committing with nothing published is refused" "$rc" 1
t_contains "and says why" "$(cat "$out")" \
	"brenn-config-commit: nothing is published at ${link}"
t_eq "the candidate stays on trial" "$(candidate_state)" gen-2

# --- one transaction at a time, from the update's side -----------------------

new_device preinstall-refusal
stage_by_hand gen-2
installing="${work}/preinstall-refusal/rauc-installing"
run env BRENN_PROVISIONING_ROOT="$store" BRENN_RAUC_INSTALLING="$installing" "$preinstall"
t_eq "an update is refused while a configuration change is on trial" "$rc" 1
t_contains "and says why" "$(cat "$out")" \
	"a configuration change is on trial; let it commit or revert before updating"
t_eq "and nothing records an install that was refused" "$(present "$installing")" missing

new_device preinstall-allowed
installing="${work}/preinstall-allowed/rauc-installing"
run env BRENN_PROVISIONING_ROOT="$store" BRENN_RAUC_INSTALLING="$installing" "$preinstall"
t_eq "an update proceeds when no configuration change is in flight" "$rc" 0
# Writing a slot pair takes minutes and nothing else on the device says so
# until the flag is armed at the very end. This record is what a configuration
# change started in that window refuses on.
t_eq "and an install in progress is on record from the start" "$(present "$installing")" present

# --- what apply refuses before it needs any privilege ------------------------

new_device apply-checks
cand=$(new_candidate check-candidate)

# A candidate that is not a conformant generation. Refused before anything is
# written, by the same program the workstation runs.
bad="${work}/not-a-generation"
rm -rf "$bad"
gen_make "$bad"
rm -f "${bad}/ssh/authorized_keys"
run_apply "$bad"
t_eq "a candidate that does not satisfy the contract is refused" "$rc" 1
t_eq "and nothing is installed" "$(candidate_state)" none
t_eq "nothing is staged either" "$(present "${store}/gen-2")" missing

# Checking without installing, which is what an operator does first.
run_apply -n "$cand"
t_eq "a check-only run succeeds on a conformant candidate" "$rc" 0
t_eq "and installs nothing" "$(candidate_state)" none

if [ "$can_install" != yes ]; then
	t_done
fi

# --- installing a candidate --------------------------------------------------

new_device good-path
cand=$(new_candidate good-candidate)
arm_fake_reboot

run_apply "$cand"
t_eq "installing a candidate succeeds" "$rc" 0
t_eq "the candidate is installed as the next generation" "$(candidate_state)" gen-2
t_eq "and the committed generation has not moved" "$(committed)" gen-1
t_eq "applying a change reboots to try it" "$(reboot_state)" rebooted
# Ownership is set to root, and checked again by the contract check the install
# ends with — inside the user namespace, where root is what the caller is
# mapped to. From out here those files read back as the caller's own uid, so
# the install having succeeded at all is what says the ownership was right.
t_eq "its host key is installed unreadable to anyone else" \
	"$(stat -c '%a' "${store}/gen-2/ssh/ssh_host_ed25519_key" 2>/dev/null)" 600
# Both secrets, because which files are secret is the contract's to declare and
# the installer's to apply: a file that loses its declaration is installed
# readable and this is what says so.
t_eq "so are its wireless credentials" \
	"$(stat -c '%a' "${store}/gen-2/net/wpa_supplicant-wlan0.conf" 2>/dev/null)" 600
t_eq "and what is not secret is readable" \
	"$(stat -c '%a' "${store}/gen-2/ssh/authorized_keys" 2>/dev/null)" 644
# The generation directory itself is walked by services that are not root — the
# log upload reads the trust anchor through it, the application reads it too —
# so it has to end up traversable however the installer closed it while it was
# setting the modes inside.
t_eq "and the generation can be walked into" \
	"$(stat -c '%a' "${store}/gen-2" 2>/dev/null)" 755
t_eq "nothing is left staged" "$(present "${store}/gen-2.new")" missing

# The boot that tries it, and the commit, once more against a generation the
# installer actually wrote: the hand-built store above proves the sequence, this
# proves the two halves fit together.
run "$select_bin"
t_eq "the next boot runs the installed candidate" "$(running)" gen-2
run "$commit"
t_eq "and commits it" "$(committed)" gen-2

# A second change on top: the numbering continues and the transaction works
# again, which is what a stale attempt record would break.
cand=$(new_candidate second-candidate unit-renamed-again)
run_apply "$cand"
t_eq "a second change installs as the generation after it" "$(candidate_state)" gen-3
run "$select_bin"
t_eq "and is tried rather than discarded" "$(running)" gen-3

# Leaving the reboot to the caller, which is what an operator does who is about
# to install an update in the same window. The one failure mode of the flag not
# working is a device rebooted out from under whatever else was happening.
new_device no-reboot
cand=$(new_candidate no-reboot-candidate)
arm_fake_reboot
run_apply --no-reboot "$cand"
t_eq "installing without rebooting succeeds" "$rc" 0
t_eq "the candidate is on trial all the same" "$(candidate_state)" gen-2
t_eq "and the device is left running" "$(reboot_state)" "stayed up"
t_contains "and says the reboot is the caller's" "$(cat "$out")" \
	"brenn-config-apply: reboot to try it"

# --- what installing refuses -------------------------------------------------

new_device refusals
cand=$(new_candidate refusal-candidate)

# One transaction at a time, from the configuration side. A second candidate
# while one is in flight would leave a failed boot with two changes to blame.
run_apply "$cand"
t_eq "installing the first candidate succeeds" "$rc" 0
run_apply "$cand"
t_eq "a second candidate while one is in flight is refused" "$rc" 1
t_contains "and says why" "$(cat "$out")" \
	"brenn-config-apply: a configuration candidate is already in flight; let it commit or revert first"
t_eq "the candidate in flight is untouched" "$(candidate_state)" gen-2
t_eq "and no third generation was written" "$(present "${store}/gen-3")" missing

# An update staged and waiting for a reboot.
new_device os-staged
cand=$(new_candidate os-staged-candidate)
param="${work}/os-staged/reboot-param"
printf '0 tryboot\n' >"$param"
BRENN_REBOOT_PARAM="$param" run_apply "$cand"
t_eq "a configuration change is refused while an update is staged" "$rc" 1
t_eq "and nothing is installed" "$(candidate_state)" none

# An update part-way through writing its slots. Nothing is staged yet and this
# boot is not trying anything, so without the record the install leaves there is
# no sign of it at all — and both transactions would end up in one boot.
new_device os-installing
cand=$(new_candidate os-installing-candidate)
installing="${work}/os-installing/rauc-installing"
: >"$installing"
BRENN_RAUC_INSTALLING="$installing" run_apply "$cand"
t_eq "a configuration change is refused while an update is being written" "$rc" 1
t_contains "and says why" "$(cat "$out")" \
	"brenn-config-apply: an operating-system update is being installed; let it finish and settle first"
t_eq "and nothing is installed" "$(candidate_state)" none

# A boot that is itself trying an update. The check that reports it is the
# update mechanism's own, so it is passed in the way the device would find it.
new_device os-trialling
cand=$(new_candidate os-trial-candidate)
yes_check="${work}/os-trialling/tryboot-yes"
printf '#!/bin/sh\nexit 0\n' >"$yes_check"
chmod 0755 "$yes_check"
BRENN_TRYBOOT_CHECK="$yes_check" run_apply "$cand"
t_eq "a configuration change is refused on a boot trying an update" "$rc" 1
t_eq "and nothing is installed" "$(candidate_state)" none

# The refusal is specific: an ordinary boot with no update mechanism reporting
# anything installs normally, or every configuration change on a healthy device
# would be refused.
no_check="${work}/os-trialling/tryboot-no"
printf '#!/bin/sh\nexit 1\n' >"$no_check"
chmod 0755 "$no_check"
BRENN_TRYBOOT_CHECK="$no_check" run_apply "$cand"
t_eq "an ordinary boot installs a candidate" "$rc" 0

# --- what an interrupted transaction leaves behind ---------------------------

# A staging directory from a run that died part-way. The next name has to skip
# it: reusing the number would have the installer delete the evidence, and the
# generation the operator went looking for is gone.
new_device interrupted-staging
cand=$(new_candidate interrupted-candidate)
mkdir -p "${store}/gen-2.new"
: >"${store}/gen-2.new/hostname"
run_apply "$cand"
t_eq "a name a staging directory already holds is not reused" "$(candidate_state)" gen-3
t_eq "and the interrupted run's directory is left as it was" \
	"$(present "${store}/gen-2.new/hostname")" present

# An attempt record from an earlier transaction. Left in place it says this
# candidate has already had its boot, so the boot that should try it discards it
# instead — and every configuration change after the first would revert.
new_device stale-attempt
cand=$(new_candidate stale-attempt-candidate)
: >"${store}/trial-attempted"
run_apply "$cand"
t_eq "installing clears an attempt record from an earlier transaction" \
	"$(present "${store}/trial-attempted")" missing
run "$select_bin"
t_eq "so the candidate is tried rather than discarded" "$(running)" gen-2

# The installer's own guard on its destination. The caller checks too, so this
# is the second line — and the failure it prevents is a generation quietly
# replaced with a different one under a name something already selects.
new_device install-over
cand=$(new_candidate install-over-candidate)
run env BRENN_CONFIG_VALIDATE="$validate" \
	"${priv[@]}" "$installer" "$cand" "${store}/gen-1"
t_eq "installing over a generation that exists is refused" "$rc" 1
t_eq "and the generation is untouched" \
	"$(cat "${store}/gen-1/hostname" 2>/dev/null)" unit-under-test

t_done
