#!/usr/bin/env bash
#
# Getting an application onto the device, off the device.
#
# The three programs that obtain a payload, check it and switch to it are
# ordinary shell, so what they do is asserted by running them against a
# temporary tree rather than by reading the units that call them. What is
# exercised here is every branch a device will actually take: a payload that
# arrives, one whose digest does not match what was promised, one that does not
# meet the contract, and a server that is down for a while and then is not.
#
# The network is the one thing not exercised. The downloader is a stub, because
# what matters at this level is what the programs do with what comes back —
# whether the bytes arrived over TLS is asserted of the configuration, in the
# provisioning contract, and of the unit that runs this at boot.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/app.rootfs-overlay/usr/lib/brenn"
fetch="${overlay}/brenn-app-fetch"
activate="${overlay}/brenn-app-activate"
resync="${overlay}/brenn-app-resync"

# The fetch reads its configuration through the provisioning contract's own
# library, which the image installs beside it and the tree keeps in the layer
# that owns it.
config_lib="${BRENN_REPO_ROOT}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-lib.sh"

app_lib="${overlay}/brenn-app-lib.sh"

for bin in "$fetch" "$activate" "$resync"; do
	if [ ! -x "$bin" ]; then
		t_fail "the app-runner's programs are present and executable" "not at ${bin}"
		t_done
	fi
done

# flock is how the store is kept to one writer, and the timeout is how that is
# shown to be true without a race in the test itself.
t_require_cmd tar sha256sum flock timeout

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app_dir="${work}/run/brenn-app"
link="${work}/run/brenn/provisioning"
baked_dir="${work}/data/baked"
served="${work}/served.tar.gz"
restarts="${work}/restarts"

# A payload as the contract defines one: a directory tree with an executable
# `run` at its root. The marker is what tells one build of it from the next.
make_payload() {
	local marker=$1 mode=${2:-0755} src="${work}/payload"
	rm -rf "$src"
	mkdir -p "${src}/lib"
	printf '#!/bin/sh\necho %s\n' "$marker" >"${src}/run"
	printf '%s\n' "$marker" >"${src}/lib/marker"
	chmod "$mode" "${src}/run"
	tar -czf "$served" -C "$src" .
}

# A payload missing the one thing the contract asks of it.
make_payload_without_run() {
	local src="${work}/payload"
	rm -rf "$src"
	mkdir -p "$src"
	printf 'nothing to run here\n' >"${src}/README"
	tar -czf "$served" -C "$src" .
}

# The downloader, stubbed: it serves the archive above, after failing however
# many times it has been told to. Refusing the first N attempts is how a server
# that is down for a while is written down.
make_curl() {
	local failures=${1:-0}
	printf '%s\n' "$failures" >"${work}/failures"
	rm -f "${work}/curl-args"
	cat >"${work}/curl" <<-EOF
		#!/bin/sh
		printf '%s\n' "\$*" >>"${work}/curl-args"
		left=\$(cat "${work}/failures")
		if [ "\$left" -gt 0 ]; then
			echo \$((left - 1)) > "${work}/failures"
			echo "stub: refusing" >&2
			exit 22
		fi
		out=""
		while [ \$# -gt 0 ]; do
			case "\$1" in
				--output) out=\$2; shift ;;
			esac
			shift
		done
		cp "${served}" "\$out"
	EOF
	chmod 0755 "${work}/curl"
}

# A fresh store and a fresh provisioning generation for every case, so that
# what one case leaves behind cannot be what the next one passes on. The digest
# defaults to the one of whatever is currently being served, because a
# generation without one is refused: every case here has to get past that to
# reach what it is about.
setup() {
	local url=${1:-https://payload.example.internal/payload.tar.gz}
	local digest=${2:-$(digest_of "$served")}
	rm -rf "${work}/run" "${work}/data"
	mkdir -p "${baked_dir}/releases" "${app_dir}/releases" "${app_dir}/scratch" "${link}/app" "${link}/ca"
	printf 'not-a-real-certificate\n' >"${link}/ca/brenn-ca.pem"
	{
		printf 'URL=%s\n' "$url"
		printf 'SHA256=%s\n' "$digest"
	} >"${link}/app/fetch.conf"
	: >"$restarts"
	cat >"${work}/restart" <<-EOF
		#!/bin/sh
		echo restarted >> "${restarts}"
	EOF
	chmod 0755 "${work}/restart"
}

run_fetch() {
	env BRENN_APP_DIR="$app_dir" BRENN_PROVISIONING_LINK="$link" \
		BRENN_CONFIG_LIB="$config_lib" BRENN_APP_LIB="$app_lib" \
		BRENN_BAKED_DIR="$baked_dir" \
		BRENN_APP_CURL="${work}/curl" BRENN_APP_RESTART="${work}/restart" \
		BRENN_APP_RETRY_BASE=0 BRENN_APP_RETRY_MAX=0 \
		"$@" 2>&1
}

# What `current` resolves to, as a release name, or empty if nothing is
# current. The link is relative, which is part of what is being asserted.
current_name() {
	local dest
	dest=$(readlink "${app_dir}/current" 2>/dev/null) || return 0
	printf '%s' "${dest#releases/}"
}

releases() {
	find "${app_dir}/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

digest_of() {
	sha256sum <"$1" | cut -d' ' -f1
}

# --- a payload that arrives ---------------------------------------------------

make_payload first
setup https://payload.example.internal/payload.tar.gz "$(digest_of "$served")"
make_curl 0

out=$(run_fetch "$fetch" --once)
rc=$?

t_eq "a payload whose digest matches is accepted" "$rc" 0
name=$(current_name)
case "$name" in
	fetch-*) t_pass "the payload it fetched is the current one (${name})" ;;
	*) t_fail "the payload it fetched is the current one" "current names '${name}'" "${out}" ;;
esac
t_eq "the entry point is where the contract says" \
	"$([ -x "${app_dir}/current/run" ] && echo yes || echo no)" yes
t_eq "and the rest of the tree came with it" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" first
t_eq "the application is restarted onto it" "$(cat "$restarts")" restarted

# How the download was asked for, out of what the downloader was actually
# given. Each of these is a way the payload arrives wrongly or not at all, and
# none of them shows up in the result of a working fetch.
args=$(cat "${work}/curl-args")
t_contains "the download refuses anything but TLS, including after a redirect" \
	"$(printf '%s' "$args" | tr ' ' '\n')" "--proto-redir"
case "$args" in
	*"--proto =https"*"--proto-redir =https"*)
		t_pass "and both the first hop and every later one are held to it" ;;
	*)
		t_fail "and both the first hop and every later one are held to it" \
			"asked for: ${args}" ;;
esac

# An attempt that never ends is the one state the retry loop cannot see: no
# failure, so no backoff, no log line, and a device that stays without an
# application after the server comes back.
for bound in --connect-timeout --speed-limit --speed-time; do
	t_contains "a stalled transfer is abandoned rather than waited on (${bound})" \
		"$(printf '%s' "$args" | tr ' ' '\n')" "$bound"
done

# The link is relative so that it means the same thing from anywhere the store
# is reachable, and so that nothing outside the store can ever be current.
t_eq "current is a relative link into the store" \
	"$(readlink "${app_dir}/current")" "releases/${name}"

# --- a payload that is not what was promised ----------------------------------

previous=$name
promised=$(digest_of "$served")
make_payload second
make_curl 0

out=$(run_fetch "$fetch" --once)
rc=$?

t_eq "a payload whose digest does not match is refused" "$((rc != 0))" 1

# Both digests, by name. This line is the only thing that tells an operator why
# a device is sitting without a payload, and the likeliest reason for it — a
# payload republished without the generation being updated — is indistinguishable
# from an unreachable server without it.
t_contains "and the mismatch says what was promised and what arrived" "$out" \
	"brenn-app-fetch: digest mismatch: expected ${promised}, got $(digest_of "$served")"
t_eq "what was running stays running" "$(current_name)" "$previous"
t_eq "and nothing half-fetched is left in the store" "$(releases)" "$previous"

# --- a payload that does not meet the contract --------------------------------

make_payload_without_run
setup
make_curl 0

out=$(run_fetch "$fetch" --once)
rc=$?

t_eq "a payload with no entry point is refused" "$((rc != 0))" 1
t_eq "nothing becomes current" "$(current_name)" ""
t_eq "and the unpacked tree is removed" "$(releases)" ""

make_payload third 0644
setup
make_curl 0
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a payload whose entry point is not executable is refused" "$((rc != 0))" 1
t_eq "and nothing becomes current" "$(current_name)" ""

# --- a server that is down, and then is not -----------------------------------

make_payload fourth
setup
make_curl 3

out=$(run_fetch "$fetch")
rc=$?

t_eq "a server that refuses three times and then answers converges" "$rc" 0
t_eq "and the payload it finally served is the current one" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" fourth
t_contains "and the wait is reported rather than silent" "$out" \
	"brenn-app-fetch: retrying in 0s"

# The shape of the waiting, which the case above deliberately flattens to zero
# so that it runs quickly. Both halves matter on a device: no growth is a fleet
# asking a downed server several times a second for the whole deadman window,
# and a ceiling reached immediately is a first retry longer than the window
# itself, costing an update that would otherwise have committed.
make_payload converging
setup
make_curl 4

out=$(env BRENN_APP_DIR="$app_dir" BRENN_PROVISIONING_LINK="$link" \
	BRENN_CONFIG_LIB="$config_lib" BRENN_APP_LIB="$app_lib" \
	BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_CURL="${work}/curl" BRENN_APP_RESTART="${work}/restart" \
	BRENN_APP_RETRY_BASE=1 BRENN_APP_RETRY_MAX=2 \
	"$fetch" 2>&1)
rc=$?
t_eq "a server that refuses four times still converges" "$rc" 0
t_eq "and the wait doubles from the first one and then stops at the ceiling" \
	"$(printf '%s\n' "$out" | sed -n 's/^brenn-app-fetch: retrying in //p' | tr '\n' ' ')" \
	"1s 2s 2s 2s "

# One attempt is the interactive form, and it is what resync uses: an operator
# is waiting for the answer.
make_payload fifth
setup
make_curl 1
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a single attempt does not wait out an outage" "$((rc != 0))" 1
t_eq "and reports it left nothing behind" "$(releases)" ""

# --- configuration that cannot be honoured ------------------------------------

make_payload sixth
make_curl 0

setup http://payload.example.internal/payload.tar.gz
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a plaintext URL is refused" "$((rc != 0))" 1
t_contains "and says why" "$out" "brenn-app-fetch: ${link}/app/fetch.conf names a URL that is not https://"

setup
: >"${link}/app/fetch.conf"
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a fetch configuration with no URL is refused" "$((rc != 0))" 1
t_contains "and says why" "$out" "brenn-app-fetch: ${link}/app/fetch.conf names no URL="

# Nothing is downloaded without something to check it against. The provisioning
# check refuses a generation with no digest, and this is the same refusal made
# where the payload would otherwise be unpacked and executed — a digest that
# went missing between the two would be an unverified payload and no error.
setup
sed -i '/^SHA256=/d' "${link}/app/fetch.conf"
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a fetch configuration with no digest is refused" "$((rc != 0))" 1
t_contains "and says why" "$out" "brenn-app-fetch: ${link}/app/fetch.conf names no SHA256="
t_eq "and nothing was downloaded to find that out" "$(releases)" ""

# The other half of the grammar the provisioning check pins: both read a value
# through the same function, so a space after the `=` cannot mean one thing on
# the bench and another here.
make_payload spaced
make_curl 0
setup
{
	printf 'URL= https://payload.example.internal/payload.tar.gz\n'
	printf 'SHA256= %s\n' "$(digest_of "$served")"
} >"${link}/app/fetch.conf"
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a value written with space after the = is read the same way here" "$rc" 0
t_eq "and the payload it names is the current one" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" spaced

# The tie-break, on the device side of the same grammar. A file naming a key
# twice is one somebody edited without deciding, and the bench takes the first
# of them; a device taking the last would fetch a URL nothing checked and hold
# it to a digest nothing checked either.
make_payload duplicated
make_curl 0
setup
{
	printf 'URL=https://payload.example.internal/payload.tar.gz\n'
	printf 'URL=https://payload.example.internal/second.tar.gz\n'
	printf 'SHA256=%s\n' "$(digest_of "$served")"
	printf 'SHA256=%064d\n' 0
} >"${link}/app/fetch.conf"
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "with a key named twice, the first assignment is what is fetched" "$rc" 0
t_eq "and it is the first URL that was asked for" \
	"$(sed -n 's/.* -- //p' "${work}/curl-args" | tail -n1)" \
	https://payload.example.internal/payload.tar.gz
t_eq "and the payload it named is the current one" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" duplicated

setup
rm -f "${link}/ca/brenn-ca.pem"
out=$(run_fetch "$fetch" --once)
t_contains "a missing trust anchor is refused before anything is downloaded" "$out" \
	"brenn-app-fetch: no trust anchor at ${link}/ca/brenn-ca.pem"

# --- activating a payload that was pushed by hand -----------------------------

# The development loop: a tree copied straight into the store from a
# workstation, then activated. It goes through the same checks and the same
# switch as a payload the device fetched itself.
setup
pushed="${app_dir}/releases/dev-1"
mkdir -p "$pushed"
printf '#!/bin/sh\necho pushed\n' >"${pushed}/run"
chmod 0755 "${pushed}/run"

out=$(env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed" 2>&1)
rc=$?
t_eq "a payload pushed into the store activates" "$rc" 0
t_eq "and is what is current" "$(current_name)" dev-1

# A second push, and the one it replaces is gone: the store is a capped tmpfs,
# and two payloads' worth of models is how it fills up.
pushed2="${app_dir}/releases/dev-2"
mkdir -p "$pushed2"
printf '#!/bin/sh\necho pushed2\n' >"${pushed2}/run"
chmod 0755 "${pushed2}/run"
out=$(env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed2" 2>&1)
t_eq "activating the next one leaves only it in the store" "$(releases)" dev-2
t_eq "and it is current" "$(current_name)" dev-2

# Anywhere else and it does not run. `current` is a relative link into the
# store, so a payload outside it would tie what runs to a directory nothing
# manages — and nothing would ever clean it up.
outside="${work}/elsewhere"
mkdir -p "$outside"
printf '#!/bin/sh\ntrue\n' >"${outside}/run"
chmod 0755 "${outside}/run"
out=$(env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$outside" 2>&1)
rc=$?
t_eq "a payload outside the store is refused" "$((rc != 0))" 1
t_contains "and says why" "$out" \
	"brenn-app-activate: ${outside} is not a release directory under ${app_dir}/releases"
t_eq "and what was current stays current" "$(current_name)" dev-2

# Left to itself, the switch asks the service manager to restart the
# application, and asks for it without waiting: at boot the restart would
# otherwise queue behind the very fetch that is calling it.
mkdir -p "${work}/bin"
cat >"${work}/bin/systemctl" <<-EOF
	#!/bin/sh
	echo "systemctl \$*" >> "${restarts}"
EOF
chmod 0755 "${work}/bin/systemctl"
: >"$restarts"
env PATH="${work}/bin:${PATH}" BRENN_APP_DIR="$app_dir" \
	"$activate" "$pushed2" >/dev/null 2>&1
t_eq "the switch restarts the application through the service manager" \
	"$(cat "$restarts")" "systemctl restart --no-block brenn-app.service"

# And a service manager that will not do it is reported, not treated as a
# failed switch: the payload is current either way, and an operator told the
# switch failed would go looking in the wrong place.
cat >"${work}/bin/systemctl" <<-'EOF'
	#!/bin/sh
	exit 1
EOF
out=$(env PATH="${work}/bin:${PATH}" BRENN_APP_DIR="$app_dir" \
	"$activate" "$pushed2" 2>&1)
rc=$?
t_eq "a restart that fails does not undo the switch" "$rc" 0
t_contains "and says what happened" "$out" \
	"brenn-app-activate: dev-2 is current, but the application could not be restarted"

# --- resync -------------------------------------------------------------------

make_payload seventh
setup
make_curl 0

# Something is already running, as it would be on a device that has been up for
# a while: the resync is what replaces it.
mkdir -p "$pushed"
printf '#!/bin/sh\necho pushed\n' >"${pushed}/run"
chmod 0755 "${pushed}/run"
env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed" >/dev/null 2>&1

out=$(run_fetch "$resync")
rc=$?
t_eq "a resync fetches and switches without a reboot" "$rc" 0
t_eq "and the new payload is running" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" seventh
t_eq "with the payload it replaced removed" "$(releases)" "$(current_name)"
t_eq "a resync takes no arguments" \
	"$(run_fetch "$resync" extra >/dev/null 2>&1 || echo refused)" refused

# The documented invocation is a bare command over SSH, which is a link on the
# path and not the program. Everything the runner finds beside itself has to be
# found beside the program the link leads to, or the one way an operator is told
# to reach this is the one way that does not work.
make_payload eighth
setup
make_curl 0
mkdir -p "${work}/sbin"
ln -sfn "$resync" "${work}/sbin/brenn-app-resync"

out=$(run_fetch "${work}/sbin/brenn-app-resync")
rc=$?
t_eq "a resync reached through a link finds the rest of the runner" "$rc" 0
t_eq "and the payload it fetched is the current one" \
	"$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" eighth

# --- one writer in the store --------------------------------------------------

# Every way a payload arrives ends by removing the releases that are not the one
# it just activated, so two of them at once delete each other's tree and leave
# `current` naming nothing — with both callers having reported success. The lock
# is what makes that impossible, and it is asserted by holding it: an activate
# that ran anyway would finish well inside the timeout.
setup
pushed3="${app_dir}/releases/dev-3"
mkdir -p "$pushed3"
printf '#!/bin/sh\necho pushed3\n' >"${pushed3}/run"
chmod 0755 "${pushed3}/run"

flock "${app_dir}/.lock" sleep 3 &
holder=$!
sleep 0.3
timeout 1 env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed3" >/dev/null 2>&1
rc=$?
t_eq "an activate waits while another writer holds the store" "$rc" 124
t_eq "and nothing was switched while it waited" "$(current_name)" ""
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# And once the store is free it goes through, so the lock is a queue and not a
# refusal.
out=$(env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed3" 2>&1)
rc=$?
t_eq "and goes through once the store is free" "$rc" 0
t_eq "with the payload it was given current" "$(current_name)" dev-3

# --- what a killed download leaves behind ---------------------------------------

# The store is capped RAM. A download interrupted before its own cleanup — the
# case the unit's Restart= exists for — is not this process's to remove any
# more, so the next attempt sweeps it; a few of them left lying around fill the
# mount and every later attempt fails for want of space instead of loudly.
make_payload ninth
setup
make_curl 0
printf 'half a payload' >"${app_dir}/.download.99999"
printf 'half an upload' >"${app_dir}/.bake.99999"

out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a fetch after an interrupted one succeeds" "$rc" 0
t_eq "and the partial download it found is gone" \
	"$(find "$app_dir" -maxdepth 1 -name '.download.*' | wc -l)" 0
t_eq "as is an upload a killed bake left" \
	"$(find "$app_dir" -maxdepth 1 -name '.bake.*' | wc -l)" 0

# --- a fetch that is told to stop ----------------------------------------------

# Stopping the unit, or shutting down, sends the loop SIGTERM, most likely in
# the middle of a download that is going nowhere. It cleans up and ends then,
# as killed by the signal, rather than retrying until the service manager gives
# up and kills it. The outer timeout's KILL is only there so that a fetch which
# carries on fails this case rather than hanging the suite.
make_payload stopped
setup
make_curl 0
cat >"${work}/curl" <<-EOF
	#!/bin/sh
	sleep 30
	exit 22
EOF
timeout -k 5 2 env BRENN_APP_DIR="$app_dir" BRENN_PROVISIONING_LINK="$link" \
	BRENN_CONFIG_LIB="$config_lib" BRENN_APP_LIB="$app_lib" \
	BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_CURL="${work}/curl" BRENN_APP_RESTART="${work}/restart" \
	BRENN_APP_RETRY_BASE=0 BRENN_APP_RETRY_MAX=0 \
	"$fetch" >/dev/null 2>&1
rc=$?
t_eq "a looping fetch sent SIGTERM mid-download ends on it" "$rc" 124
t_eq "and leaves no download behind" \
	"$(find "$app_dir" -maxdepth 1 -name '.download.*' | wc -l)" 0

# --- a device that was baked while the fetch waited ---------------------------

# The unit's condition keeps a baked device from fetching at boot, but it is
# read once. An operator who bakes while the fetch is waiting out an outage
# would otherwise have the baked payload replaced by the fetched one the moment
# the server came back. So every attempt of the loop asks again, and a baked
# device ends the loop as a success with nothing more downloaded. The bake
# lands while the first attempt is failing, which is the only way to tell an
# attempt that asks from a loop that asked once before it started.
make_payload tenth
setup
make_curl 1000
mkdir -p "${baked_dir}/releases/baked-1"
cat >"${work}/curl" <<-EOF
	#!/bin/sh
	printf '%s\n' "\$*" >>"${work}/curl-args"
	ln -sfn releases/baked-1 "${baked_dir}/active"
	echo "stub: refusing" >&2
	exit 22
EOF
chmod 0755 "${work}/curl"
pushed4="${app_dir}/releases/dev-4"
mkdir -p "$pushed4"
printf '#!/bin/sh\necho pushed4\n' >"${pushed4}/run"
chmod 0755 "${pushed4}/run"
env BRENN_APP_DIR="$app_dir" BRENN_APP_RESTART="${work}/restart" \
	"$activate" "$pushed4" >/dev/null 2>&1

out=$(timeout 10 env BRENN_APP_DIR="$app_dir" BRENN_PROVISIONING_LINK="$link" \
	BRENN_CONFIG_LIB="$config_lib" BRENN_APP_LIB="$app_lib" \
	BRENN_BAKED_DIR="$baked_dir" \
	BRENN_APP_CURL="${work}/curl" BRENN_APP_RESTART="${work}/restart" \
	BRENN_APP_RETRY_BASE=0 BRENN_APP_RETRY_MAX=0 \
	"$fetch" 2>&1)
rc=$?
t_eq "the waiting fetch on a device baked between attempts ends as a success" "$rc" 0
t_contains "and says why" "$out" "brenn-app-fetch: device is baked; nothing to fetch"
t_eq "having asked for the one download it made before the bake and no more" \
	"$([ -e "${work}/curl-args" ] && wc -l <"${work}/curl-args" || echo 0)" 1
t_eq "and changed nothing that runs" "$(current_name)" dev-4

# A resync is an operator asking for the fetched payload on a device they know
# is baked, so a single attempt does not ask the question: it downloads, and a
# failure is reported as one.
make_curl 1000
out=$(run_fetch "$fetch" --once)
rc=$?
t_eq "a single attempt on a baked device still fetches" "$((rc != 0))" 1
t_contains "and reports the download it made" "$out" \
	"brenn-app-fetch: could not download https://payload.example.internal/payload.tar.gz"
t_eq "which the downloader was asked for" "$(wc -l <"${work}/curl-args")" 1
t_eq "and what was running stays running" "$(current_name)" dev-4

# A link whose release is gone is not baked mode, the reading the units'
# conditions give it, so the loop fetches as on any device that is not baked.
make_payload eleventh
setup
make_curl 0
ln -sfn releases/does-not-exist "${baked_dir}/active"
out=$(run_fetch "$fetch")
rc=$?
t_eq "the fetch on a device with a dangling baked link fetches" "$rc" 0
t_eq "which the downloader was asked for" "$(wc -l <"${work}/curl-args")" 1
t_eq "and what it fetched is current" "$(cat "${app_dir}/current/lib/marker" 2>/dev/null)" eleventh

t_done
