#!/usr/bin/env bash
#
# The boot-time choice between a committed configuration and a candidate.
#
# This is the mechanism that makes a configuration mistake cost one boot: a
# candidate is taken up exactly once, and a boot that finds the attempt marker
# already set knows the previous attempt did not survive to commit. It runs
# here against a temporary tree rather than on a device, because every branch
# of it is a branch nobody wants to discover on hardware — least of all the one
# that decides whether a device with bad wireless credentials comes back.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

select_bin="${BRENN_REPO_ROOT}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-select"
if [ ! -x "$select_bin" ]; then
	t_fail "the generation selector is present and executable" "not at ${select_bin}"
	t_done
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Any 32 hex digits, and any DNS label. These are formats, not identities: the
# real ones are provisioned per device and are not in this repository.
good_machine_id=00112233445566778899aabbccddeeff
good_hostname=unit-under-test

prov=""
link=""
flag=""
midfile=""
hostfile=""
out=""

# A fresh tree per case, so a case cannot pass on state another one left.
new_tree() {
	local root="${work}/$1"
	prov="${root}/data/provisioning"
	link="${root}/run/brenn/provisioning"
	flag="${root}/run/brenn/config-trial"
	midfile="${root}/run/machine-id"
	hostfile="${root}/run/hostname"
	out="${root}/out"
	mkdir -p "$prov" "${root}/run"
}

add_gen() {
	mkdir -p "${prov}/$1"
	printf '%s\n' "${2-$good_machine_id}" >"${prov}/$1/machine-id"
	printf '%s\n' "${3-$good_hostname}" >"${prov}/$1/hostname"
}

# A generation missing one of its identity files. The selector has a branch for
# each; a generation is meant to be complete, but an incomplete one must degrade
# rather than stop the boot.
add_partial_gen() {
	mkdir -p "${prov}/$1"
	case $2 in
		machine-id) printf '%s\n' "$good_machine_id" >"${prov}/$1/machine-id" ;;
		hostname) printf '%s\n' "$good_hostname" >"${prov}/$1/hostname" ;;
	esac
}

run_select() {
	rc=0
	BRENN_PROVISIONING_ROOT="$prov" \
		BRENN_PROVISIONING_LINK="$link" \
		BRENN_CONFIG_TRIAL_FLAG="$flag" \
		BRENN_MACHINE_ID_FILE="$midfile" \
		BRENN_HOSTNAME_FILE="$hostfile" \
		"$select_bin" >"$out" 2>&1 || rc=$?
}

# What the published link says, read one level and not canonicalised: the
# property is that the *resolved* generation directory is published rather than
# the `active`/`trial` link, so that a commit or a discard later in the boot
# cannot change what a service already reading it sees. Resolving both sides
# would make publishing the link indistinguishable from publishing its target.
published() {
	[ -L "$link" ] || return 0
	readlink "$link"
}

# The generation directory as the selector would name it.
generation() {
	readlink -f "${prov}/$1"
}

# No trial in flight: the committed generation runs, and its machine id becomes
# this boot's identity.
new_tree committed-only
add_gen gen-1
ln -s gen-1 "${prov}/active"
run_select
t_eq "a boot with no trial succeeds" "$rc" 0
t_eq "a boot with no trial runs the committed generation" \
	"$(published)" "$(generation gen-1)"
t_eq "the provisioned machine id is installed" \
	"$(cat "$midfile" 2>/dev/null)" "$good_machine_id"
t_eq "the provisioned host name is applied" \
	"$(cat "$hostfile" 2>/dev/null)" "$good_hostname"
# The two units that only make sense while a candidate is being tried condition
# on this file, so an ordinary boot must not leave one behind: a commit on such
# a boot would promote whatever happens to be staged, unbooted.
t_eq "an ordinary boot is not marked as a trial" \
	"$([ -e "$flag" ] && echo present || echo missing)" missing

# A candidate nobody has tried yet: it runs, and the attempt is recorded before
# it does — the record is what stops it from being tried forever.
new_tree trial-fresh
add_gen gen-1
add_gen gen-2
ln -s gen-1 "${prov}/active"
ln -s gen-2 "${prov}/trial"
run_select
t_eq "a first trial boot succeeds" "$rc" 0
t_eq "a first trial boot runs the candidate" \
	"$(published)" "$(generation gen-2)"
t_eq "the attempt is recorded" \
	"$([ -e "${prov}/trial-attempted" ] && echo present || echo missing)" present
t_eq "the candidate is still on trial" \
	"$([ -L "${prov}/trial" ] && echo present || echo missing)" present
t_eq "and the boot is marked as a trial, naming what it is running" \
	"$(cat "$flag" 2>/dev/null)" "$(generation gen-2)"

# The same candidate on the next boot: the previous attempt ended without
# committing, so it is discarded rather than tried again.
run_select
t_eq "an unfinished trial reverts to the committed generation" \
	"$(published)" "$(generation gen-1)"
t_eq "the candidate is discarded" \
	"$([ -L "${prov}/trial" ] && echo present || echo missing)" missing
t_eq "the attempt record is cleared" \
	"$([ -e "${prov}/trial-attempted" ] && echo present || echo missing)" missing
t_eq "the revert is reported as a failure" "$rc" 1
# And the mark from the boot that failed is gone with it, or the commit would
# run on a boot that is no longer trying anything.
t_eq "the boot that reverts is not marked as a trial" \
	"$([ -e "$flag" ] && echo present || echo missing)" missing

# A candidate whose target is not there. Same answer as an unfinished trial:
# discard it and boot what is known to work.
new_tree trial-dangling
add_gen gen-1
ln -s gen-1 "${prov}/active"
ln -s gen-9 "${prov}/trial"
run_select
t_eq "a candidate pointing at nothing reverts" \
	"$(published)" "$(generation gen-1)"
t_eq "a candidate pointing at nothing is discarded" \
	"$([ -L "${prov}/trial" ] && echo present || echo missing)" missing

# A candidate that is a directory instead of a link — what a provisioning tool
# interrupted mid-install leaves behind. It is usable on the boot that takes it
# up, and discarding it afterwards has to work: a discard that fell over would
# abort the selection with nothing published, turning one malformed entry into
# a device that comes up unconfigured on every boot from then on.
new_tree trial-directory
add_gen gen-1
add_gen trial
ln -s gen-1 "${prov}/active"
run_select
t_eq "a candidate installed as a directory is tried" \
	"$(published)" "$(generation trial)"
run_select
t_eq "an unfinished directory candidate reverts" \
	"$(published)" "$(generation gen-1)"
t_eq "a directory candidate is discarded" \
	"$([ -e "${prov}/trial" ] && echo present || echo missing)" missing
t_eq "the attempt record is cleared after a directory candidate" \
	"$([ -e "${prov}/trial-attempted" ] && echo present || echo missing)" missing

# An unprovisioned device. Nothing is published, and the failure is loud: the
# boot continues so the console is reachable, but nothing pretends to be
# configured.
new_tree unprovisioned
run_select
t_eq "an unprovisioned device fails the selection" "$rc" 1
t_eq "an unprovisioned device publishes nothing" "$(published)" ""

# A generation whose machine id is not one. The configuration is otherwise
# usable, so it is published; the identity is not silently accepted.
new_tree bad-machine-id
add_gen gen-1 "not-a-machine-id"
ln -s gen-1 "${prov}/active"
run_select
t_eq "a malformed machine id is refused" "$rc" 1
t_eq "a malformed machine id does not stop the generation being used" \
	"$(published)" "$(generation gen-1)"
t_eq "a malformed machine id is not installed" \
	"$([ -e "$midfile" ] && echo present || echo missing)" missing

# A host name that is not a DNS label. Handled the same way: reported, and the
# name the image came with is left alone rather than a name being invented or a
# rejected one being set anyway.
new_tree bad-hostname
add_gen gen-1 "$good_machine_id" "Not A Hostname"
ln -s gen-1 "${prov}/active"
run_select
t_eq "a malformed host name is refused" "$rc" 1
t_eq "a malformed host name does not stop the generation being used" \
	"$(published)" "$(generation gen-1)"
t_eq "a malformed host name is not applied" \
	"$([ -e "$hostfile" ] && echo present || echo missing)" missing

# A generation with no machine id and one with no host name. Each is reported,
# and each still runs: a generation that is missing a file is not a reason to
# publish nothing, which would be a device with no wireless and no sshd.
new_tree absent-machine-id
add_partial_gen gen-1 hostname
ln -s gen-1 "${prov}/active"
run_select
t_eq "a generation with no machine id is reported" "$rc" 1
t_eq "a generation with no machine id is still used" "$(published)" "$(generation gen-1)"
t_eq "no machine id is written" \
	"$([ -e "$midfile" ] && echo present || echo missing)" missing
t_eq "the rest of the generation still applies" \
	"$(cat "$hostfile" 2>/dev/null)" "$good_hostname"

new_tree absent-hostname
add_partial_gen gen-1 machine-id
ln -s gen-1 "${prov}/active"
run_select
t_eq "a generation with no host name is reported" "$rc" 1
t_eq "a generation with no host name is still used" "$(published)" "$(generation gen-1)"
t_eq "no host name is applied" \
	"$([ -e "$hostfile" ] && echo present || echo missing)" missing
t_eq "the machine id still applies" "$(cat "$midfile" 2>/dev/null)" "$good_machine_id"

# A committed trial, then a second candidate. Committing removes the candidate
# and leaves the attempt record behind; a record that outlived its candidate has
# to be retired, or the next configuration change is discarded on the boot that
# should have tried it — and every one after that.
new_tree trial-committed-then-next
add_gen gen-1
add_gen gen-2
add_gen gen-3
ln -s gen-1 "${prov}/active"
ln -s gen-2 "${prov}/trial"
run_select
t_eq "the first candidate is tried" "$(published)" "$(generation gen-2)"
# What committing does: the candidate becomes the committed generation.
mv -T "${prov}/trial" "${prov}/active"
run_select
t_eq "the boot after a commit runs the committed generation" \
	"$(published)" "$(generation gen-2)"
t_eq "the attempt record does not outlive its candidate" \
	"$([ -e "${prov}/trial-attempted" ] && echo present || echo missing)" missing
ln -s gen-3 "${prov}/trial"
run_select
t_eq "the next candidate is tried rather than discarded" \
	"$(published)" "$(generation gen-3)"
t_eq "the next candidate is still on trial" \
	"$([ -L "${prov}/trial" ] && echo present || echo missing)" present

# The two failure branches that need an unwritable store. Skipped for a root
# caller, which write-protection does not apply to.
if [ "$(id -u)" -ne 0 ]; then
	# A candidate that cannot record its attempt is refused, not taken up: a
	# trial with no record would be retried on every boot forever. The committed
	# generation runs, so the device is reachable and the candidate can be tried
	# again once there is room to record it.
	new_tree marker-unwritable
	add_gen gen-1
	add_gen gen-2
	ln -s gen-1 "${prov}/active"
	ln -s gen-2 "${prov}/trial"
	chmod a-w "$prov"
	run_select
	chmod u+w "$prov"
	t_eq "a candidate whose attempt cannot be recorded is reported" "$rc" 1
	t_eq "a candidate whose attempt cannot be recorded is not tried" \
		"$(published)" "$(generation gen-1)"
	t_eq "and it is left in place for a later boot" \
		"$([ -L "${prov}/trial" ] && echo present || echo missing)" present

	# A discard that cannot finish keeps the attempt record, so the same
	# candidate stays refused instead of being taken up as a fresh one on the
	# next boot. What it must not do is abort with nothing published.
	new_tree discard-unwritable
	add_gen gen-1
	add_gen trial
	ln -s gen-1 "${prov}/active"
	: >"${prov}/trial-attempted"
	chmod a-w "$prov"
	run_select
	t_eq "a discard that cannot finish is reported" "$rc" 1
	t_eq "a discard that cannot finish still publishes the committed generation" \
		"$(published)" "$(generation gen-1)"
	t_eq "the attempt record survives a discard that could not finish" \
		"$([ -e "${prov}/trial-attempted" ] && echo present || echo missing)" present
	run_select
	t_eq "and the same candidate stays refused on the next boot" \
		"$(published)" "$(generation gen-1)"
	chmod u+w "$prov"
fi

t_done
