#!/usr/bin/env bash
#
# The baked store: a payload burned onto the persistent partition, and run from
# RAM at every boot with no network.
#
# The programs that bake, stage and unbake are ordinary shell, so what they do
# is asserted by running them against a temporary tree standing in for both
# stores: the RAM payload store and the baked store on flash. What is held here
# is what a demo device depends on — that a bake leaves the payload running and
# burned, that a stage brings it back from flash after something else ran,
# that a payload failing the contract or its digest never runs, and that a
# failed write to flash leaves the store as it was.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/app.rootfs-overlay/usr/lib/brenn"
bake="${overlay}/brenn-app-bake"
stage="${overlay}/brenn-app-stage"
unbake="${overlay}/brenn-app-unbake"
activate="${overlay}/brenn-app-activate"
app_lib="${overlay}/brenn-app-lib.sh"
config_lib="${BRENN_REPO_ROOT}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-lib.sh"

for bin in "$bake" "$stage" "$unbake" "$activate"; do
	if [ ! -x "$bin" ]; then
		t_fail "the baked store's programs are present and executable" "not at ${bin}"
		t_done
	fi
done

# python3 is what puts a terminal on the bake's stdin; flock and timeout show
# the lock is honoured without a race in the test itself.
t_require_cmd tar sha256sum flock timeout python3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app_dir="${work}/run/brenn-app"
baked_dir="${work}/data/baked"
archive="${work}/payload.tar.gz"
restarts="${work}/restarts"

cat >"${work}/restart" <<-EOF
	#!/bin/sh
	echo restarted >> "${restarts}"
EOF
chmod 0755 "${work}/restart"

# A payload as the contract defines one, archived the way an operator would
# hand it over. The marker is what tells one build of it from the next.
make_payload() {
	local marker=$1 src="${work}/payload"
	rm -rf "$src"
	mkdir -p "${src}/lib"
	printf '#!/bin/sh\necho %s\n' "$marker" >"${src}/run"
	printf '%s\n' "$marker" >"${src}/lib/marker"
	chmod 0755 "${src}/run"
	tar -czf "$archive" -C "$src" .
}

make_payload_without_run() {
	local src="${work}/payload"
	rm -rf "$src"
	mkdir -p "$src"
	printf 'nothing to run here\n' >"${src}/README"
	tar -czf "$archive" -C "$src" .
}

fresh_stores() {
	rm -rf "${work}/run" "${work}/data"
	mkdir -p "${app_dir}/releases" "${app_dir}/scratch" "${baked_dir}/releases"
	: >"$restarts"
}

fresh_ram() {
	rm -rf "${work}/run"
	mkdir -p "${app_dir}/releases" "${app_dir}/scratch"
	: >"$restarts"
}

run_env() {
	env BRENN_APP_DIR="$app_dir" BRENN_BAKED_DIR="$baked_dir" \
		BRENN_APP_LIB="$app_lib" BRENN_CONFIG_LIB="$config_lib" \
		BRENN_APP_RESTART="${work}/restart" "$@"
}

current_name() {
	local dest
	dest=$(readlink "${app_dir}/current" 2>/dev/null) || return 0
	printf '%s' "${dest#releases/}"
}

ram_releases() {
	find "${app_dir}/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

store_releases() {
	find "${baked_dir}/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

active_name() {
	local dest
	dest=$(readlink "${baked_dir}/active" 2>/dev/null) || return 0
	printf '%s' "${dest#releases/}"
}

# Whether anything is at a path, a dangling link included.
link_state() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		echo present
	else
		echo absent
	fi
}

digest_of() {
	sha256sum <"$1" | cut -d' ' -f1
}

# Commands a case puts first on the path. `sync` fails when any argument ends
# in SYNC_FAIL_ON, which is how a flush the flash could not complete is written
# down; `date` gives a fixed stamp, so that two bakes can be made to ask for the
# same release name.
real_sync=$(command -v sync)
mkdir -p "${work}/shim-sync" "${work}/shim-date"
cat >"${work}/shim-sync/sync" <<-EOF
	#!/bin/sh
	for a; do
		case "\$a" in
			*"\${SYNC_FAIL_ON}") echo "sync: stub failure on \$a" >&2; exit 1 ;;
		esac
	done
	exec "${real_sync}" "\$@"
EOF
cat >"${work}/shim-date/date" <<-'EOF'
	#!/bin/sh
	echo 20260101T000000Z
EOF
chmod 0755 "${work}/shim-sync/sync" "${work}/shim-date/date"

bake_failing_sync() {
	run_env PATH="${work}/shim-sync:${PATH}" SYNC_FAIL_ON="$1" "$bake" <"$archive" 2>&1
}

push_dev() {
	local dir="${app_dir}/releases/$1"
	mkdir -p "$dir"
	printf '#!/bin/sh\necho %s\n' "$1" >"${dir}/run"
	chmod 0755 "${dir}/run"
	run_env "$activate" "$dir" >/dev/null 2>&1
	: >"$restarts"
}

# --- a bake -----------------------------------------------------------------

make_payload first
fresh_stores
out=$(run_env "$bake" <"$archive" 2>&1)
rc=$?

t_eq "a payload that meets the contract is baked" "$rc" 0
first=$(current_name)
case "$first" in
	baked-*) t_pass "and is the current payload, named for the door it came in by (${first})" ;;
	*) t_fail "and is the current payload, named for the door it came in by" "current names '${first}'" "$out" ;;
esac
t_eq "running the tree it was baked from" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" first
t_eq "the application was restarted onto it exactly once" "$(cat "$restarts")" restarted
t_eq "the store holds one release, the one that is running" "$(store_releases)" "$first"
t_eq "active is a relative link into the store" \
	"$(readlink "${baked_dir}/active")" "releases/${first}"
cmp -s "$archive" "${baked_dir}/releases/${first}/payload.tar"
t_ok "the archive is stored exactly as it was delivered" $?
t_eq "with its digest beside it" \
	"$(cat "${baked_dir}/releases/${first}/sha256" 2>/dev/null)" "$(digest_of "$archive")"
t_contains "and the bake reports the release and the digest" "$out" \
	"brenn-app-bake: baked ${first} (sha256 $(digest_of "$archive"))"
t_eq "and no upload is left in RAM" \
	"$(find "$app_dir" -maxdepth 1 -name '.bake.*' | wc -l)" 0

# --- stage ------------------------------------------------------------------

# Right after a bake the baked payload is already running. A stage then is a
# no-op that says so, and never removes the tree `current` names.
: >"$restarts"
before=$(stat -c %i "${app_dir}/releases/${first}")
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage while the baked payload is current succeeds" "$rc" 0
t_contains "and says there was nothing to do" "$out" \
	"brenn-app-stage: ${first} is already current"
t_eq "leaving current alone" "$(current_name)" "$first"
t_eq "and the tree it names untouched" "$(stat -c %i "${app_dir}/releases/${first}")" "$before"
t_eq "and restarting nothing" "$(cat "$restarts")" ""

# The boot: the flash store survives, RAM is empty.
fresh_ram
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage into an empty RAM store succeeds" "$rc" 0
t_eq "and the baked payload is current under the same release id" "$(current_name)" "$first"
t_eq "with the tree the archive holds" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" first
t_eq "and the application restarted onto it" "$(cat "$restarts")" restarted

# Something else was run instead, the way an operator does during a demo; the
# stage brings the baked one back, and the other is pruned from RAM.
push_dev dev-1
t_eq "a pushed payload replaces the baked one in RAM" "$(current_name)" dev-1
t_eq "leaving the store on flash as it was" "$(active_name)" "$first"
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage while a pushed payload runs succeeds" "$rc" 0
t_eq "and the baked payload is current again" "$(current_name)" "$first"
t_eq "with the pushed one pruned" "$(ram_releases)" "$first"

# What a stage killed between unpacking and activating leaves: a tree under the
# baked release's name that nothing runs. It is replaced, not trusted.
fresh_ram
mkdir -p "${app_dir}/releases/${first}"
printf 'left over\n' >"${app_dir}/releases/${first}/stale"
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage over a leftover tree of the same name succeeds" "$rc" 0
t_eq "and the baked payload is current" "$(current_name)" "$first"
t_eq "with the leftover replaced by what the archive holds" \
	"$(cat "${app_dir}/current/lib/marker" "${app_dir}/current/stale" 2>/dev/null)" first

# Flash that rotted or was tampered with: refused, with both digests named, and
# nothing of it left in RAM.
fresh_ram
push_dev dev-2
stored_archive="${baked_dir}/releases/${first}/payload.tar"
cp "$stored_archive" "${work}/good.tar"
printf 'X' | dd of="$stored_archive" bs=1 seek=100 conv=notrunc status=none
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage of an archive that does not match its digest is refused" "$rc" 1
t_contains "and names what was stored and what was found" "$out" \
	"brenn-app-stage: digest mismatch in the baked release ${first}: expected $(cat "${baked_dir}/releases/${first}/sha256"), got $(digest_of "$stored_archive")"
t_eq "what was running stays running" "$(current_name)" dev-2
t_eq "and no release is left behind" "$(ram_releases)" dev-2
cp "${work}/good.tar" "$stored_archive"

# Each thing a stage refuses, refused before anything in RAM changes. The stage
# runs unattended at every baked boot, so each refusal has to say which one it
# is.
stage_refused() {
	local label=$1 want_rc=$2 want_msg=$3
	shift 3
	fresh_ram
	push_dev dev-2
	out=$(run_env "$stage" "$@" 2>&1)
	rc=$?
	t_eq "$label" "$rc" "$want_rc"
	t_has "and says why" "$out" "$want_msg"
	t_eq "and what was running stays running" "$(current_name)" dev-2
	t_eq "with no release left behind" "$(ram_releases)" dev-2
}

stored_digest="${baked_dir}/releases/${first}/sha256"
mv "$stored_archive" "${work}/aside"
stage_refused "a stage of a release with no archive is refused" 1 \
	"brenn-app-stage: the baked release ${first} has no payload.tar"
mv "${work}/aside" "$stored_archive"

mv "$stored_digest" "${work}/aside"
stage_refused "a stage of a release with no digest is refused" 1 \
	"brenn-app-stage: the baked release ${first} has no sha256"
mv "${work}/aside" "$stored_digest"

cp "$stored_digest" "${work}/good.sha256"
make_payload_without_run
cp "$archive" "$stored_archive"
digest_of "$stored_archive" >"$stored_digest"
stage_refused "a stage of a stored payload that fails the contract is refused" 1 \
	"brenn-app-stage: the baked payload ${first} could not be staged"
cp "${work}/good.tar" "$stored_archive"
cp "${work}/good.sha256" "$stored_digest"

stage_refused "a stage takes no arguments" 2 "usage: brenn-app-stage" extra

# A stranded upload from a bake that was killed outright takes RAM the stage
# needs, and no bake may come along this boot to remove it.
fresh_ram
printf 'a stranded upload' >"${app_dir}/.bake.99999"
run_env "$stage" >/dev/null 2>&1
t_eq "a stage sweeps an upload a killed bake left in RAM" \
	"$(find "$app_dir" -maxdepth 1 -name '.bake.*' | wc -l)" 0

# --- a payload that fails the contract --------------------------------------

make_payload_without_run
fresh_stores
out=$(run_env "$bake" <"$archive" 2>&1)
rc=$?
t_eq "a payload with no entry point is not baked" "$rc" 1
t_eq "nothing is current" "$(current_name)" ""
t_eq "nothing is in RAM" "$(ram_releases)" ""
t_eq "the store on flash is empty" "$(store_releases)" ""
t_eq "and nothing is active" "$(link_state "${baked_dir}/active")" absent
t_eq "and no upload is left in RAM" \
	"$(find "$app_dir" -maxdepth 1 -name '.bake.*' | wc -l)" 0

# --- a stage on a device that is not baked ----------------------------------

out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage on a device that is not baked is refused" "$rc" 1
t_has "and says why" "$out" "brenn-app-stage: not in baked mode"

# A link whose release is gone reads as not baked, as the units' conditions
# read it.
ln -sfn releases/does-not-exist "${baked_dir}/active"
out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "a stage with a dangling active link is refused" "$rc" 1
t_has "as a device that is not baked" "$out" "brenn-app-stage: not in baked mode"
rm -f "${baked_dir}/active"

# --- an upload that may have been cut short ---------------------------------

# A plain tar stream carries nothing that tells a short upload from a whole
# one, so it is refused before anything is unpacked.
make_payload plain
tar -cf "${work}/plain.tar" -C "${work}/payload" .
fresh_stores
out=$(run_env "$bake" <"${work}/plain.tar" 2>&1)
rc=$?
t_eq "an uncompressed archive is not baked" "$rc" 1
t_has "and the bake says why" "$out" "is not a gzip, xz or zstd archive"
t_eq "nothing is current" "$(current_name)" ""
t_eq "and the store on flash is empty" "$(store_releases)" ""

# A compressed one that stops short fails its unpack.
make_payload truncated
head -c "$(($(stat -c %s "$archive") / 2))" "$archive" >"${work}/short.tar.gz"
fresh_stores
out=$(run_env "$bake" <"${work}/short.tar.gz" 2>&1)
rc=$?
t_eq "a compressed archive cut short is not baked" "$rc" 1
t_eq "nothing is current" "$(current_name)" ""
t_eq "and the store on flash is empty" "$(store_releases)" ""
t_eq "and nothing is active" "$(link_state "${baked_dir}/active")" absent

# --- an activation that fails after its switch ------------------------------

# The activate step can fail after `current` names the new tree — its output
# going to an SSH channel that has closed, say. The tree is then the one that
# runs, and removing it would leave `current` naming nothing.
cat >"${work}/activate-late-failure" <<-EOF
	#!/bin/sh
	ln -sfn "releases/\$(basename "\$1")" "${app_dir}/current"
	exit 1
EOF
chmod 0755 "${work}/activate-late-failure"
make_payload late
fresh_stores
out=$(run_env BRENN_APP_ACTIVATE="${work}/activate-late-failure" "$bake" <"$archive" 2>&1)
rc=$?
late=$(current_name)
t_eq "a bake whose activation fails after the switch fails" "$rc" 1
t_has "and says the payload is current" "$out" "${late} is current, but its activation did not finish"
t_eq "and the tree current names is still there" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" late
t_eq "and nothing was baked" "$(store_releases)" ""

# --- how the bake is invoked ------------------------------------------------

# Without the redirect, stdin is the operator's terminal. What comes back
# through the terminal ends its lines with a carriage return, so the usage is
# looked for as a fragment.
out=$(run_env python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' \
	"$bake" </dev/null 2>&1)
rc=$?
t_eq "a bake with a terminal on stdin is refused as a usage error" "$rc" 2
t_has "and prints the usage" "$out" "usage: brenn-app-bake < payload-archive"
t_eq "a bake takes no arguments" "$(run_env "$bake" extra <"$archive" >/dev/null 2>&1; echo $?)" 2

# --- a second bake ----------------------------------------------------------

make_payload first
fresh_stores
run_env "$bake" <"$archive" >/dev/null 2>&1
first=$(active_name)
make_payload second
out=$(run_env "$bake" <"$archive" 2>&1)
rc=$?
second=$(current_name)
t_eq "a second bake succeeds" "$rc" 0
t_eq "and is what is running" "$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" second
if [ -n "$second" ] && [ "$second" != "$first" ]; then
	t_pass "under a release name of its own"
else
	t_fail "under a release name of its own" "first '${first}', second '${second}'"
fi
t_eq "active names it" "$(readlink "${baked_dir}/active")" "releases/${second}"
t_eq "and the first is gone from the store" "$(store_releases)" "$second"

# A release an interrupted bake left under its temporary name is swept before
# anything else, so even a bake that goes on to fail removes it.
mkdir -p "${baked_dir}/releases/baked-19700101T000000Z.new"
printf 'half an upload' >"${app_dir}/.bake.99999"
make_payload_without_run
out=$(run_env "$bake" <"$archive" 2>&1)
rc=$?
t_eq "a refused bake after an interrupted one fails" "$rc" 1
t_eq "and the half-written release it found is gone" "$(store_releases)" "$second"
t_eq "as is the upload it found in RAM" \
	"$(find "$app_dir" -maxdepth 1 -name '.bake.*' | wc -l)" 0
t_eq "and active is as it was" "$(active_name)" "$second"

# Two bakes asking for one name: the store's release keeps it, whatever RAM
# holds, and the bake takes the next.
fresh_ram
mkdir -p "${baked_dir}/releases/baked-20260101T000000Z"
make_payload collided
out=$(run_env PATH="${work}/shim-date:${PATH}" "$bake" <"$archive" 2>&1)
rc=$?
t_eq "a bake whose name is taken in the store succeeds" "$rc" 0
t_eq "under the next name" "$(active_name)" baked-20260101T000000Z-1
t_eq "and the store holds only it" "$(store_releases)" baked-20260101T000000Z-1

# --- a store that cannot be written -----------------------------------------

# The payload has passed the contract and is running by the time the write to
# flash fails, so it stays running, and every failure says what the store on
# flash holds. A flush that fails is the only sign of a write the flash did not
# complete, so each one is made to fail in turn.
make_payload kept
fresh_stores
run_env "$bake" <"$archive" >/dev/null 2>&1
kept=$(active_name)

make_payload fourth
out=$(bake_failing_sync /payload.tar)
rc=$?
t_eq "a bake whose archive could not be flushed fails" "$rc" 1
t_has "and says the payload runs but is not baked" "$out" "is running, but could not be written to ${baked_dir}/releases; it is not baked"
t_eq "the payload is running from RAM" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" fourth
t_eq "active still names the release it did" "$(active_name)" "$kept"
t_eq "and nothing half-written is left in the store" "$(store_releases)" "$kept"

make_payload fifth
out=$(bake_failing_sync "/data/baked/releases")
rc=$?
t_eq "a bake whose new release could not be flushed fails" "$rc" 1
t_has "and says the payload is not baked" "$out" "could not be written to ${baked_dir}/releases; it is not baked"
t_eq "active still names the release it did" "$(active_name)" "$kept"
t_eq "and the release it renamed is gone again" "$(store_releases)" "$kept"

make_payload sixth
mkdir "${baked_dir}/active.new"
out=$(run_env "$bake" <"$archive" 2>&1)
rc=$?
t_eq "a bake whose link could not be switched fails" "$rc" 1
t_has "and says the release before it is still the one a boot runs" "$out" \
	"could not be switched to it; it is not baked, and the baked release before it is still the one a boot runs"
t_eq "active still names the release it did" "$(active_name)" "$kept"
t_eq "and the store holds only that release" "$(store_releases)" "$kept"
t_eq "with no half-made link left" "$(link_state "${baked_dir}/active.new")" absent

make_payload seventh
out=$(bake_failing_sync "/data/baked")
rc=$?
seventh=$(current_name)
t_eq "a bake whose switched link could not be flushed fails" "$rc" 1
t_has "and says which releases a boot may run" "$out" \
	"${seventh} is running and ${baked_dir}/active names it, but the link could not be flushed"
t_eq "the link names the new release" "$(active_name)" "$seventh"
t_eq "and the one before it is kept" "$(store_releases)" "$(printf '%s\n' "$kept" "$seventh" | sort)"

# --- unbake -----------------------------------------------------------------

running=$(current_name)
out=$(run_env "$unbake" 2>&1)
rc=$?
t_eq "an unbake succeeds" "$rc" 0
t_eq "active is gone" \
	"$(link_state "${baked_dir}/active")" absent
t_eq "and every release with it" "$(store_releases)" ""
t_eq "and the running payload is left running" "$(current_name)" "$running"

out=$(run_env "$unbake" 2>&1)
rc=$?
t_eq "an unbake on a device that is not baked succeeds" "$rc" 0
t_has "and says the device is not baked" "$out" "the device is no longer baked"
t_eq "an unbake takes no arguments" "$(run_env "$unbake" extra >/dev/null 2>&1; echo $?)" 2

# --- one writer in the stores -----------------------------------------------

# Both stores are kept to one writer by the RAM store's lock. Asserted by
# holding it: a bake or a stage that ran anyway would finish well inside the
# timeout.
make_payload fifth
fresh_stores
run_env "$bake" <"$archive" >/dev/null 2>&1
baked_now=$(active_name)
fresh_ram
push_dev dev-3

flock "${app_dir}/.lock" sleep 5 &
holder=$!
sleep 0.3
timeout 1 env BRENN_APP_DIR="$app_dir" BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_LIB="$app_lib" BRENN_CONFIG_LIB="$config_lib" \
	BRENN_APP_RESTART="${work}/restart" "$stage" >/dev/null 2>&1
rc=$?
t_eq "a stage waits while another writer holds the store" "$rc" 124
t_eq "and switched nothing while it waited" "$(current_name)" dev-3
make_payload sixth
timeout 1 env BRENN_APP_DIR="$app_dir" BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_LIB="$app_lib" BRENN_CONFIG_LIB="$config_lib" \
	BRENN_APP_RESTART="${work}/restart" "$bake" <"$archive" >/dev/null 2>&1
rc=$?
t_eq "a bake waits while another writer holds the store" "$rc" 124
t_eq "and baked nothing while it waited" "$(active_name)" "$baked_now"
timeout 1 env BRENN_APP_DIR="$app_dir" BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_LIB="$app_lib" BRENN_CONFIG_LIB="$config_lib" \
	"$unbake" >/dev/null 2>&1
rc=$?
t_eq "an unbake waits while another writer holds the store" "$rc" 124
t_eq "and unbaked nothing while it waited" "$(active_name)" "$baked_now"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

out=$(run_env "$stage" 2>&1)
rc=$?
t_eq "and a stage goes through once the store is free" "$rc" 0
t_eq "with the baked payload current" "$(current_name)" "$baked_now"

# --- reached through the path -----------------------------------------------

# The documented invocation is a bare command over SSH, which is a link on the
# path: the library and the activate step have to be found beside the program
# the link leads to.
mkdir -p "${work}/sbin"
ln -sfn "$stage" "${work}/sbin/brenn-app-stage"
fresh_ram
out=$(env BRENN_APP_DIR="$app_dir" BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_RESTART="${work}/restart" "${work}/sbin/brenn-app-stage" 2>&1)
rc=$?
t_eq "a stage reached through a link finds the rest of the runner" "$rc" 0
t_eq "and the baked payload is current" "$(current_name)" "$baked_now"

t_done
