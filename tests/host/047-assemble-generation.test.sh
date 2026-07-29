#!/usr/bin/env bash
#
# What `scripts/assemble-generation.sh` produces, and what it refuses.
#
# Everything here runs against synthetic material in a temporary store — a
# throwaway certificate, a throwaway keyring, a made-up passphrase — so the
# assembly is exercised end to end without a real secret anywhere near it. The
# generation it produces is then handed to `scripts/provision.sh -n`, which is
# the check that matters: a generation the assembler writes is one the device
# will accept.
#
# No real unit's configuration is read either: the unit directories are
# temporary, so a run cannot depend on, or disturb, the store or the
# configuration of an actual device.
#
# The refusals are the bulk of it on purpose. A generation that assembles
# cleanly, passes the contract check and is wrong — the wrong network name, an
# address with a space in it, a passphrase the radio cannot use — is diagnosed
# by taking the device apart, because there is no console on it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

script="${BRENN_REPO_ROOT}/scripts/assemble-generation.sh"
provision="${BRENN_REPO_ROOT}/scripts/provision.sh"

for bin in "$script" "$provision"; do
	if [ ! -x "$bin" ]; then
		t_fail "the assembly tools are present and executable" "not at ${bin}"
		t_done
	fi
done

t_require_cmd openssl ssh-keygen python3 sha256sum install stat find diff

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

units="${work}/units"
store="${work}/store"
export BRENN_PROVISIONING_STORE="$store"

passphrase="not-a-real-passphrase-3141592653"

exists() {
	[ -e "$1" ] && echo present || echo absent
}

write_unit() {
	# write_unit <name> [extra lines...] — later lines override the defaults,
	# because the configuration is sourced in order.
	local name=$1
	shift
	mkdir -p "${units}/${name}"
	{
		echo "UNIT_HOSTNAME=${name}"
		echo "WIFI_COUNTRY=US"
		echo "JOURNAL_URL=https://collector.example.internal:19532"
		echo "APP_URL=https://payloads.example.internal/${name}.tar.zst"
		echo "APP_SHA256=$(printf 'payload-%s' "$name" | sha256sum | cut -d' ' -f1)"
		local line
		for line in "$@"; do
			echo "$line"
		done
	} >"${units}/${name}/unit.conf"
}

cert() {
	# A throwaway self-signed certificate, standing in for a trust anchor.
	openssl req -x509 -newkey ed25519 -noenc -days 2 \
		-subj "/CN=$2" -keyout "${1}.key" -out "$1" >/dev/null 2>&1
	rm -f -- "${1}.key"
}

# The material every unit's store starts from, minted once. No assertion here
# depends on one unit's key or certificate differing from another's — they are
# about presence, PEM-ness, modes and byte-identity with the store copy — and a
# case that needs a different input overwrites its own copy after fill_store.
material="${work}/material"
mkdir -p "$material"
ssh-keygen -q -t ed25519 -N "" -C "admin" -f "${material}/admin" </dev/null
mv "${material}/admin.pub" "${material}/authorized_keys"
rm -f -- "${material}/admin"
cert "${material}/brenn-ca.pem" "test-anchor"
cert "${material}/rauc-keyring.pem" "test-keyring"

fill_store() {
	# fill_store <unit> [psk]
	local unit=$1
	local psk=${2:-$passphrase}
	local dir="${store}/${unit}/inputs"
	mkdir -p "$dir"
	cp -- "${material}/authorized_keys" "${material}/brenn-ca.pem" \
		"${material}/rauc-keyring.pem" "$dir"
	{
		echo "SSID=test-network"
		echo "PSK=${psk}"
	} >"${dir}/wifi.conf"
}

mode_of() {
	stat -c '%a' "$1"
}

# One run of the script under test, its output kept for the assertions that
# follow it. The last argument is a unit name, which is turned into the
# directory the script takes — that directory's name is the unit's, which is how
# the store files it.
run_out=""
run() {
	local args=("$@")
	local last=$((${#args[@]} - 1))
	args[last]="${units}/${args[last]}"
	run_out=$("$script" "${args[@]}" 2>&1)
}

refused() {
	# refused <desc> <args...> — the run must fail, and its output is kept.
	local desc=$1
	shift
	if run "$@"; then
		t_fail "$desc" "the run succeeded"
	else
		t_pass "$desc"
	fi
}

refused "an unknown unit is refused" no-such-unit
t_has "the refusal names the directory it looked for" "$run_out" "no such unit directory"

write_unit gather
refused "an empty store refuses" gather
t_has "the wireless credentials are named" "$run_out" "wifi.conf"
t_has "the access list is named" "$run_out" "authorized_keys"
t_has "the trust anchor is named" "$run_out" "brenn-ca.pem"
t_has "the update keyring is named" "$run_out" "rauc-keyring.pem"
t_has "the run says nothing was assembled" "$run_out" "nothing was assembled"
t_eq "no generation was left behind" "$(exists "${store}/gather/generation")" absent
t_has "the refusal names the store it looked in" "$run_out" \
	"store ${store} (BRENN_PROVISIONING_STORE)"

# A refused run mints no identity. That is the property that makes a run against
# the wrong store recoverable — the operator fixes the root and no second
# machine-id or host key exists for the unit — and it holds only while identity
# generation stays below the refusal gate, which is a reorder away from not
# being true.
t_eq "a refused run mints no machine id" \
	"$(exists "${store}/gather/identity/machine-id")" absent
t_eq "and no host key either" \
	"$(exists "${store}/gather/identity/ssh_host_ed25519_key")" absent

# A forgotten store variable produces this same refusal with every path under a
# different root, and the refusal is the whole instruction for gathering the
# inputs. Following it into the wrong store is only avoidable if the run says
# which root it took and where that came from.
default_home="${work}/forgotten"
default_store="${default_home}/.brenn-provisioning"
if default_out=$(env -u BRENN_PROVISIONING_STORE "HOME=${default_home}" \
	"$script" "${units}/gather" 2>&1); then
	t_fail "a run with no store variable refuses" "the run succeeded"
else
	t_pass "a run with no store variable refuses"
fi
t_has "an unset store variable is named as the default" "$default_out" \
	"store ${default_store} (default; set BRENN_PROVISIONING_STORE to use another)"
t_has "and that run asks for the same inputs under that root" "$default_out" \
	"${default_store}/gather/inputs/wifi.conf"
t_eq "and it minted no identity under that root either" \
	"$(exists "${default_store}/gather/identity/machine-id")" absent
t_eq "nor a host key" \
	"$(exists "${default_store}/gather/identity/ssh_host_ed25519_key")" absent

# Set to nothing is not the same as unset: the run takes the default, and an
# operator who did set the variable must not be told to set it. Reachable from a
# wrapper or a profile expanding a variable that does not exist.
empty_out=$(env "BRENN_PROVISIONING_STORE=" "HOME=${default_home}" \
	"$script" "${units}/gather" 2>&1 || true)
t_has "a store variable set to nothing says so, and says which root it took" \
	"$empty_out" "store ${default_store} (BRENN_PROVISIONING_STORE is set to nothing; using the default)"

# A relative root is resolved before anything is printed. Unresolved, every path
# in the refusal — which is the instruction for gathering the material — means
# something different from every other directory, and the next run from another
# one creates a second store and a second identity in it.
rel_out=$(cd "$work" && env "BRENN_PROVISIONING_STORE=rel-store" \
	"$script" "${units}/gather" 2>&1 || true)
t_has "a relative store root is resolved against the working directory" \
	"$rel_out" "store ${work}/rel-store (BRENN_PROVISIONING_STORE)"
t_has "and the inputs are asked for by absolute path" "$rel_out" \
	"${work}/rel-store/gather/inputs/wifi.conf"
t_lacks "with no relative path anywhere in the refusal" "$rel_out" " rel-store/"

# --- the whole assembly, checked by the tool that installs it ----------------

write_unit reachy-test "NTP_SERVER=time.example.internal"
fill_store reachy-test
run reachy-test
t_ok "a complete store assembles" $? "$run_out"

gen="${store}/reachy-test/generation"
"$provision" -n "${work}/dry" "$gen" >/dev/null 2>&1
t_ok "the provisioning tool accepts the assembled generation" $?

for f in hostname machine-id net/wpa_supplicant-wlan0.conf net/ntp.conf \
	ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub ssh/authorized_keys \
	ca/brenn-ca.pem rauc/keyring.pem journal/upload.conf app/fetch.conf; do
	t_eq "the generation carries ${f}" "$(exists "${gen}/${f}")" present
done

# Nothing else: the contract refuses a stray file, and so must the assembly that
# produces one.
t_eq "no entry is anything but a file or a directory" \
	"$(find "$gen" -mindepth 1 \! -type d \! -type f | wc -l)" 0

# The store is where the material lives between assemblies — the host private
# key, the wireless credentials in cleartext, the anchor and the keyring — and
# where it lives is the operator's decision. A dropped chmod here leaves all of
# it at the invoking umask, readable by every account on the workstation, and
# nothing downstream would ever notice.
t_eq "the unit's store is private" "$(mode_of "${store}/reachy-test")" 700
t_eq "the operator's inputs are private" "$(mode_of "${store}/reachy-test/inputs")" 700
t_eq "the unit's identity is private" "$(mode_of "${store}/reachy-test/identity")" 700
t_eq "the machine id is private" \
	"$(mode_of "${store}/reachy-test/identity/machine-id")" 600
t_eq "the store root itself is private" "$(mode_of "$store")" 700

# The modes above only prove the run that *created* those directories tightened
# them. What the documentation promises an operator whose store is tracked in a
# repository is stronger and is the whole answer to git recording no modes: a
# fresh clone's loose directories are taken back to 0700 by the next run, which
# never created any of them. Loosen them and re-run.
store_dirs=("$store" "${store}/reachy-test" "${store}/reachy-test/inputs"
	"${store}/reachy-test/identity")
chmod 0755 "${store_dirs[@]}"
run -f reachy-test
t_ok "a run against a loosened store succeeds" $? "$run_out"
for d in "${store_dirs[@]}"; do
	t_eq "a fresh clone's loose modes are re-tightened: ${d#"${work}/"}" \
		"$(mode_of "$d")" 700
done

t_eq "the host key is a secret" "$(mode_of "${gen}/ssh/ssh_host_ed25519_key")" 600
t_eq "the supplicant configuration is a secret" \
	"$(mode_of "${gen}/net/wpa_supplicant-wlan0.conf")" 600
t_eq "the access list is readable" "$(mode_of "${gen}/ssh/authorized_keys")" 644
t_eq "the generation root is not group-writable" "$(mode_of "$gen")" 755

t_eq "the host name is the configured one" "$(cat "${gen}/hostname")" reachy-test
grep -Eq '^[0-9a-f]{32}$' "${gen}/machine-id"
t_ok "the machine id is 32 hex digits" $?

wpa=$(cat "${gen}/net/wpa_supplicant-wlan0.conf")
t_has "the supplicant names the regulatory domain" "$wpa" "country=US"
t_has "the supplicant opens a control socket for wpa_cli" "$wpa" \
	"ctrl_interface=/run/wpa_supplicant"
t_has "the supplicant declares the network" "$wpa" 'ssid="test-network"'
grep -Eq '^[[:space:]]*psk=[0-9a-f]{64}$' "${gen}/net/wpa_supplicant-wlan0.conf"
t_ok "the pre-shared key is a hash" $?
t_lacks "the passphrase itself is not on the device" "$wpa" "$passphrase"
t_lacks "the network name is not scanned for when it is broadcast" "$wpa" "scan_ssid"

# The passphrase must not have leaked into any other file either.
t_eq "the passphrase is nowhere in the generation" \
	"$(grep -rl -- "$passphrase" "$gen" 2>/dev/null | wc -l)" 0

upload=$(cat "${gen}/journal/upload.conf")
t_has "the collector is the configured one" "$upload" \
	"URL=https://collector.example.internal:19532"
t_has "the upload trusts the anchor this generation carries" "$upload" \
	"TrustedCertificateFile=/run/brenn/provisioning/ca/brenn-ca.pem"
t_has "the time server drop-in names a server" "$(cat "${gen}/net/ntp.conf")" \
	"NTP=time.example.internal"

fetch=$(cat "${gen}/app/fetch.conf")
t_has "the payload address is the configured one" "$fetch" \
	"URL=https://payloads.example.internal/"
grep -Eq '^SHA256=[0-9a-f]{64}$' "${gen}/app/fetch.conf"
t_ok "the payload digest is 64 hex digits" $?

diff -q "${store}/reachy-test/inputs/authorized_keys" "${gen}/ssh/authorized_keys" >/dev/null
t_ok "the access list is the operator's file" $?
diff -q "${store}/reachy-test/inputs/brenn-ca.pem" "${gen}/ca/brenn-ca.pem" >/dev/null
t_ok "the trust anchor is the operator's file" $?
diff -q "${store}/reachy-test/inputs/rauc-keyring.pem" "${gen}/rauc/keyring.pem" >/dev/null
t_ok "the update keyring is the operator's file" $?

# The unit's own unit.conf, named directly rather than by its directory: the same
# unit, the same store entry, because the name comes from the directory either
# way.
run -f "reachy-test/unit.conf"
t_ok "the configuration file may be named instead of its directory" $? "$run_out"
t_has "and the unit is the directory's name" "$run_out" "reachy-test assembled at"

cp "${units}/reachy-test/unit.conf" "${units}/reachy-test/other.conf"
if "$script" -f "${units}/reachy-test/other.conf" >"${work}/other" 2>&1; then
	t_fail "some other file in the unit's directory is refused" "the run succeeded"
else
	t_pass "some other file in the unit's directory is refused"
fi
t_has "and the refusal says what it wanted" "$(cat "${work}/other")" "is not a unit.conf"
rm -f "${units}/reachy-test/other.conf"

id_before=$(cat "${gen}/machine-id")
key_before=$(sha256sum <"${gen}/ssh/ssh_host_ed25519_key")

refused "an existing generation is not replaced silently" reachy-test
t_has "the refusal says how to replace it" "$run_out" "-f"

run -f reachy-test
t_ok "-f reassembles" $? "$run_out"
t_has "the identity is reused rather than made again" "$run_out" "identity reused"
t_eq "the machine id is the same device's" "$(cat "${gen}/machine-id")" "$id_before"
t_eq "the host key is the same device's" \
	"$(sha256sum <"${gen}/ssh/ssh_host_ed25519_key")" "$key_before"

# -o writes the generation where the operator says: a parent that may not exist
# yet, a scratch sibling of a path outside the store, and the same two-rename
# replacement over it. None of that is on the default path, and flash day would
# otherwise be the first time any of it ran.
elsewhere="${work}/elsewhere/gen"
run -o "$elsewhere" reachy-test
t_ok "an operator-named destination assembles" $? "$run_out"
t_eq "the generation is where it was asked for" "$(exists "${elsewhere}/hostname")" present
"$provision" -n "${work}/dry" "$elsewhere" >/dev/null 2>&1
t_ok "the tool accepts a generation assembled outside the store" $?
t_eq "nothing half-written is left beside it" \
	"$(find "${work}/elsewhere" -maxdepth 1 -name 'gen.*' | wc -l)" 0

refused "an operator-named destination is not replaced silently either" \
	-o "$elsewhere" reachy-test
run -f -o "$elsewhere" reachy-test
t_ok "-f replaces an operator-named destination" $? "$run_out"
t_eq "and the generation is the one that replaced it" \
	"$(exists "${elsewhere}/hostname")" present
t_eq "and neither the scratch copy nor the displaced one is left behind" \
	"$(find "${work}/elsewhere" -maxdepth 1 -name 'gen.*' | wc -l)" 0

# A destination named with a trailing slash, which is what tab completion offers.
# The scratch copy is a sibling built from this path by hand, so an unnormalised
# one names a directory nothing created and the run dies on the template.
run -o "${work}/trailing/gen/" reachy-test
t_ok "a destination named with a trailing slash assembles" $? "$run_out"
t_eq "and the generation is where it was asked for" \
	"$(exists "${work}/trailing/gen/hostname")" present

# The replacement is two renames with a recovery between them, and that recovery
# is the only thing between a failed replace and an operator whose one assembled
# generation is gone. It runs here: a `mv` that refuses the scratch copy, which
# is the rename that has the destination empty when it fails.
shim="${work}/bin"
mkdir -p "$shim"
cat >"${shim}/mv" <<'EOF'
#!/bin/sh
# The scratch-to-destination rename fails; every other move is the real one.
for arg in "$@"; do
	case $arg in
		*.new.*)
			echo "mv: refused by the test shim" >&2
			exit 1
			;;
	esac
done
PATH=${PATH#*:}
exec mv "$@"
EOF
chmod 0755 "${shim}/mv"
kept_id=$(cat "${elsewhere}/machine-id")
if PATH="${shim}:${PATH}" "$script" -f -o "$elsewhere" "${units}/reachy-test" \
	>"${work}/rollback" 2>&1; then
	t_fail "a replacement that cannot be moved into place fails" "the run succeeded"
else
	t_pass "a replacement that cannot be moved into place fails"
fi
t_eq "and the generation that was displaced is back in its place" \
	"$(cat "${elsewhere}/machine-id" 2>/dev/null)" "$kept_id"
t_eq "whole, not half of one" "$(exists "${elsewhere}/rauc/keyring.pem")" present
t_eq "and neither half is left beside it" \
	"$(find "${work}/elsewhere" -maxdepth 1 -name 'gen.*' | wc -l)" 0
rm -rf "$shim"

# Those two scratch templates are a published interface, not an implementation
# detail: docs/provisioning.md prints the ignore recipe a store tracked in a
# repository needs, and such a repository's .gitignore is exactly those literals.
# Rename one here and the recipe goes quietly wrong — the next killed run leaves
# a whole previous generation, host key and cleartext credentials included,
# untracked beside the store and offered for commit.
doc="${BRENN_REPO_ROOT}/docs/provisioning.md"
scratch_kinds=$(grep -o 'mktemp -d "\$[{]out_dir[}]\.[a-z]*\.' "$script" |
	sed 's/.*\.\([a-z]*\)\.$/\1/' | sort -u)
t_eq "the assembler names two scratch siblings of a generation" \
	"$(printf '%s\n' "$scratch_kinds" | wc -l)" 2
for kind in $scratch_kinds; do
	grep -Fq "store/*/generation.${kind}.*" "$doc"
	t_ok "the documented ignore recipe covers generation.${kind}.*" $?
done
grep -Fq 'store/*/generation/' "$doc"
t_ok "and the generation directory itself" $?

# unit.conf is read as shell, and none of the script's own state is a knob a unit
# may set: whether an existing generation is replaced, where the generation goes,
# where the store is. A stray or copy-pasted assignment in a file that is
# hand-edited and kept in version control is refused by name rather than obeyed.
write_unit hijack "force=1" "out_dir=${work}/hijacked" "store_root=${work}/hijacked"
fill_store hijack
refused "a unit.conf assigning the tool's own variables is refused" hijack
t_has "the refusal names the clobber knob" "$run_out" "'force'"
t_has "and the destination knob" "$run_out" "'out_dir'"
t_has "and the store knob" "$run_out" "'store_root'"
t_eq "nothing was written where they pointed" "$(exists "${work}/hijacked")" absent
t_eq "and no generation was assembled" "$(exists "${store}/hijack/generation")" absent

# The same, against the guard it would have disabled: an existing generation is
# still not replaced by a configuration that sets force.
write_unit clobber
fill_store clobber
run clobber
t_ok "a unit assembles once" $? "$run_out"
clobber_id=$(cat "${store}/clobber/generation/machine-id")
write_unit clobber "force=1"
refused "a unit.conf cannot grant itself -f" clobber
t_eq "and the generation that was there is untouched" \
	"$(cat "${store}/clobber/generation/machine-id")" "$clobber_id"

write_unit hexpsk
hex=$(printf 'hex-psk-source' | sha256sum | cut -d' ' -f1)
fill_store hexpsk "$hex"
run hexpsk
t_ok "a 64-hex PSK assembles" $? "$run_out"
t_has "the hex key is used verbatim" \
	"$(cat "${store}/hexpsk/generation/net/wpa_supplicant-wlan0.conf")" "psk=${hex}"

# --- what a site may leave unnamed -------------------------------------------
#
# A unit with no log collector, no application payload and so nothing for a trust
# anchor to be for is the bring-up configuration: it boots, joins the network,
# answers SSH and takes updates. It has to assemble, or the first flash waits on
# infrastructure that does not exist yet.

write_unit bare "JOURNAL_URL=" "APP_URL=" "APP_SHA256="
fill_store bare
rm -f "${store}/bare/inputs/brenn-ca.pem"
run bare
t_ok "a unit with no collector, no payload and no anchor assembles" $? "$run_out"
bare_gen="${store}/bare/generation"
"$provision" -n "${work}/dry" "$bare_gen" >/dev/null 2>&1
t_ok "the tool accepts it" $?
t_eq "no upload drop-in is written" "$(exists "${bare_gen}/journal/upload.conf")" absent
t_eq "no fetch configuration is written" "$(exists "${bare_gen}/app/fetch.conf")" absent
t_eq "no trust anchor is carried" "$(exists "${bare_gen}/ca/brenn-ca.pem")" absent
t_eq "the update keyring is carried all the same" \
	"$(exists "${bare_gen}/rauc/keyring.pem")" present
t_has "the run says the logs will not survive a reboot" "$run_out" \
	"the journal stays in RAM"
t_has "the run says no application will run" "$run_out" "no application"

write_unit no-journal "JOURNAL_URL="
fill_store no-journal
run no-journal
t_ok "a unit with a payload and no collector assembles" $? "$run_out"
t_eq "and writes no upload drop-in" \
	"$(exists "${store}/no-journal/generation/journal/upload.conf")" absent
t_eq "and still carries the payload configuration" \
	"$(exists "${store}/no-journal/generation/app/fetch.conf")" present
"$provision" -n "${work}/dry" "${store}/no-journal/generation" >/dev/null 2>&1
t_ok "and the tool accepts it" $?

write_unit no-app "APP_URL=" "APP_SHA256="
fill_store no-app
run no-app
t_ok "a unit with a collector and no payload assembles" $? "$run_out"
t_eq "and writes no fetch configuration" \
	"$(exists "${store}/no-app/generation/app/fetch.conf")" absent
t_eq "and still carries the upload drop-in" \
	"$(exists "${store}/no-app/generation/journal/upload.conf")" present

# An anchor in the store with nothing in this generation reading it is staged
# trust, not a mistake: it is carried, and the contract check accepts it.
write_unit staged "JOURNAL_URL=" "APP_URL=" "APP_SHA256="
fill_store staged
run staged
t_ok "a unit with an anchor and nothing to verify assembles" $? "$run_out"
t_eq "the staged anchor is carried" \
	"$(exists "${store}/staged/generation/ca/brenn-ca.pem")" present
"$provision" -n "${work}/dry" "${store}/staged/generation" >/dev/null 2>&1
t_ok "and the tool accepts staged trust" $?

write_unit no-ntp
fill_store no-ntp
run no-ntp
t_ok "a unit with no time server assembles" $? "$run_out"
t_eq "no time server drop-in is written" \
	"$(exists "${store}/no-ntp/generation/net/ntp.conf")" absent
t_has "the run says where the clock will come from instead" "$run_out" \
	"no local time server"
"$provision" -n "${work}/dry" "${store}/no-ntp/generation" >/dev/null 2>&1
t_ok "the tool accepts a generation without the optional file" $?

# The anchor is demanded exactly when this generation names something that would
# read it. The device carries no certificate store of its own, so an endpoint
# with no anchor is a connection that can never succeed — retried forever on a
# unit nobody is watching.

anchorless() {
	# anchorless <desc> <unit> [unit.conf overrides...]
	local desc=$1 unit=$2
	shift 2
	write_unit "$unit" "$@"
	fill_store "$unit"
	rm -f "${store}/${unit}/inputs/brenn-ca.pem"
	if run "$unit"; then
		t_fail "$desc" "the run succeeded"
		return
	fi
	t_has "$desc" "$run_out" "brenn-ca.pem"
	t_eq "${desc}: nothing was assembled" \
		"$(exists "${store}/${unit}/generation")" absent
}

anchorless "a collector with no trust anchor is refused" journal-no-ca \
	"APP_URL=" "APP_SHA256="
t_has "and the refusal names the value that demanded it" "$run_out" "JOURNAL_URL"
anchorless "a payload source with no trust anchor is refused" app-no-ca "JOURNAL_URL="
t_has "and names that value too" "$run_out" "APP_URL"

# The keyring is not conditional on anything a unit configures: a device that can
# verify no update bundle can only be changed by being taken apart.
write_unit no-keyring "JOURNAL_URL=" "APP_URL=" "APP_SHA256="
fill_store no-keyring
rm -f "${store}/no-keyring/inputs/rauc-keyring.pem" \
	"${store}/no-keyring/inputs/brenn-ca.pem"
refused "a unit with nothing configured still needs the update keyring" no-keyring
t_has "the refusal names the keyring" "$run_out" "rauc-keyring.pem"
t_lacks "and does not ask for an anchor nothing would read" "$run_out" "brenn-ca.pem"

refuses() {
	# refuses <desc> <unit> <expected fragment> [unit.conf overrides...]
	local desc=$1
	local unit=$2
	local want=$3
	shift 3
	write_unit "$unit" "$@"
	fill_store "$unit"
	if run "$unit"; then
		t_fail "$desc" "the run succeeded"
		return
	fi
	t_has "$desc" "$run_out" "$want"
	t_eq "${desc}: nothing was assembled" \
		"$(exists "${store}/${unit}/generation")" absent
}

refuses "a host name that is not a DNS label is refused" bad-host \
	"is not a single DNS label" "UNIT_HOSTNAME=Not_A_Label"
refuses "a missing regulatory domain is refused" no-country \
	"sets no WIFI_COUNTRY" "WIFI_COUNTRY="
refuses "a plaintext collector is refused" plain-journal \
	"is not an https:// address" "JOURNAL_URL=http://collector.example.internal:19532"
refuses "a plaintext payload address is refused" plain-app \
	"is not an https:// address" "APP_URL=http://payloads.example.internal/x.tar.zst"
refuses "a scan-for-the-name knob that is not 0 or 1 is refused" scan-word \
	"is not 0 or 1" "WIFI_SCAN_SSID=yes"
refuses "a lower-case regulatory domain is refused" lc-country \
	"is not a two-letter regulatory domain" "WIFI_COUNTRY=us"

# A key nobody reads is not an omission the operator chose. For the optional ones
# absence is a legal configuration, so a typo would assemble, validate, install
# and boot a device quietly using the public pool or shipping no logs at all.
refuses "a misspelled key is refused by name" typo-key \
	"'NTP_SEVER'" "NTP_SEVER=time.example.internal"
t_has "and the refusal says which keys there are" "$run_out" "NTP_SERVER"

# The payload address and its digest are one decision in two halves. Half of it
# is the thing an optional pair can get wrong: an address with nothing to check
# what was served against, or a digest with nothing to fetch.
refuses "a payload address with no digest is refused" app-no-digest \
	"sets APP_URL and no APP_SHA256" "APP_SHA256="
refuses "a digest with no payload address is refused" digest-no-app \
	"sets APP_SHA256 and no APP_URL" "APP_URL="
refuses "a truncated digest is refused" short-digest \
	"is not 64 hex digits" "APP_SHA256=abc123"

# The values that are interpolated raw into drop-ins. A space in one of them
# assembles cleanly, passes the contract check, and produces a unit that boots,
# associates, and quietly uploads nothing — the least visible of the ways a typo
# can survive to the device.
refuses "a collector address with a space in it is refused" spacey-journal \
	"JOURNAL_URL holds a space" 'JOURNAL_URL="https://collector.example.internal /x"'
refuses "a payload address with a space in it is refused" spacey-app \
	"APP_URL holds a space" 'APP_URL="https://payloads.example.internal/a b.tar.zst"'
refuses "a time server with a space in it is refused" spacey-ntp \
	"NTP_SERVER holds a space" 'NTP_SERVER="time.example.internal and-another"'

# A network name and a WPA passphrase may both contain spaces, and a reader that
# removed them would hash the right words against the wrong network: the
# generation would assemble, pass the contract check, and produce a unit that
# associates with nothing.

spaced_ssid="Some Guest Network"
spaced_psk="correct horse battery staple"
write_unit spaced
fill_store spaced
{
	echo "SSID=${spaced_ssid}"
	echo "PSK=${spaced_psk}"
} >"${store}/spaced/inputs/wifi.conf"
run spaced
t_ok "credentials with spaces assemble" $? "$run_out"
spaced_wpa=$(cat "${store}/spaced/generation/net/wpa_supplicant-wlan0.conf")
t_has "the network name keeps its spaces" "$spaced_wpa" "ssid=\"${spaced_ssid}\""
t_lacks "the passphrase itself is still not on the device" "$spaced_wpa" "$spaced_psk"

# wpa_passphrase is not what the assembler uses — it derives the key itself, to
# keep the passphrase off a command line — so here it is the independent
# implementation the derived key is checked against. Absent, only this comparison
# goes unmade: everything else about the spaced credentials is asserted above.
psk_written=$(printf '%s\n' "$spaced_wpa" |
	sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')
if command -v wpa_passphrase >/dev/null 2>&1; then
	t_eq "the key is the one for that exact name and passphrase" \
		"$psk_written" \
		"$(wpa_passphrase "$spaced_ssid" "$spaced_psk" |
			sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')"
else
	echo "SKIP  the independent derivation: wpa_passphrase is not installed"
	t_eq "the key is 64 hex digits derived from those credentials" \
		"${#psk_written}" 64
fi

write_unit hidden "WIFI_SCAN_SSID=1"
fill_store hidden
run hidden
t_ok "a hidden network assembles" $? "$run_out"
t_has "the supplicant is told to scan for the name" \
	"$(cat "${store}/hidden/generation/net/wpa_supplicant-wlan0.conf")" "scan_ssid=1"

# Each of these is a value the rendered supplicant configuration cannot carry.
# Refusing here is the whole point: the alternative is a file that parses as
# something else, or does not parse at all, discovered on a device with no
# console.

refuses_wifi() {
	# refuses_wifi <desc> <unit> <expected fragment> <ssid> <psk>
	local desc=$1 unit=$2 want=$3 ssid=$4 psk=$5
	write_unit "$unit"
	fill_store "$unit"
	{
		echo "SSID=${ssid}"
		echo "PSK=${psk}"
	} >"${store}/${unit}/inputs/wifi.conf"
	if run "$unit"; then
		t_fail "$desc" "the run succeeded"
		return
	fi
	t_has "$desc" "$run_out" "$want"
	t_eq "${desc}: nothing was assembled" \
		"$(exists "${store}/${unit}/generation")" absent
}

refuses_wifi "a network name holding a double quote is refused" quoted-ssid \
	"holds a double quote or a control character" 'say "hello"' "$passphrase"
refuses_wifi "a network name with a stray carriage return is refused" cr-ssid \
	"holds a double quote or a control character" "$(printf 'network\r')" "$passphrase"
refuses_wifi "a network name longer than 32 bytes is refused" long-ssid \
	"is at most 32" "abcdefghijklmnopqrstuvwxyz0123456789" "$passphrase"
refuses_wifi "a passphrase shorter than 8 characters is refused" short-psk \
	"a WPA passphrase is 8 to 63" "network" "seven77"
refuses_wifi "a passphrase longer than 63 characters is refused" long-psk \
	"a WPA passphrase is 8 to 63" "network" \
	"zz-a-passphrase-of-sixty-four-characters-is-one-too-many-for-wpa2"
refuses_wifi "a passphrase with a non-ASCII byte is refused" utf8-psk \
	"outside printable ASCII" "network" "$(printf 'passphras\303\251')"

# The two branches where the file names nothing at all. An empty SSID would
# otherwise become the derivation's salt and render as ssid="": a generation that
# assembles, passes the contract check, and associates with nothing.
refuses_wifi "a wifi.conf naming no network is refused" no-ssid \
	"names no SSID=" "" "$passphrase"
refuses_wifi "a wifi.conf naming no key is refused" no-psk \
	"names no PSK=" "network" ""

# A trust anchor that is not a certificate: the one bad input that is a file
# rather than a missing one.
write_unit bad-ca
fill_store bad-ca
echo "this is not a certificate" >"${store}/bad-ca/inputs/brenn-ca.pem"
refused "a trust anchor that is not a certificate is refused" bad-ca
t_has "the refusal says what the file is not" "$run_out" "is not a PEM certificate"

# An access list with no key in it is a device nobody can log into.
write_unit empty-keys
fill_store empty-keys
echo "# nobody" >"${store}/empty-keys/inputs/authorized_keys"
refused "an access list admitting nobody is refused" empty-keys
t_has "the refusal says the list admits nobody" "$run_out" "admits nobody"

# The unit's name is the basename of a directory the operator names on the command
# line, and it is interpolated into the store paths this script creates, chmods
# 0700, and writes the host private key and the cleartext wireless credentials
# into.
mkdir -p "${units}/has space"
cp "${units}/reachy-test/unit.conf" "${units}/has space/unit.conf"
if "$script" "${units}/has space" >"${work}/spacey" 2>&1; then
	t_fail "a unit directory whose name is not usable as a unit's is refused" \
		"the run succeeded"
else
	t_pass "a unit directory whose name is not usable as a unit's is refused"
fi
t_has "and the refusal says what it is about the name" "$(cat "${work}/spacey")" \
	"is not usable as one"
t_eq "and no store entry was made under it" "$(exists "${store}/has space")" absent

t_done
