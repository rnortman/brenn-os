#!/usr/bin/env bash
#
# Assemble a device's provisioning generation from its configuration and its
# secret material.
#
#   scripts/assemble-generation.sh [-f] [-o <out-dir>] <unit-dir>
#
# A generation is the whole of one device's site configuration — identity,
# credentials, trust anchors, endpoints — and the device installs one as a single
# transaction. Nothing in it may be built into an image, so it is assembled from
# inputs that live outside this repository and the result is what reaches the
# device: at flash time for the first one, over SSH for every one after.
#
# Two kinds of input go in, and the difference matters:
#
#   * The unit's own configuration — host name, regulatory domain, the collector
#     and payload addresses — is plain text, and is <unit-dir>/unit.conf. The
#     directory is named for the unit; its name is what the unit's material is
#     filed under in the store. Where those directories live is the operator's
#     business: this repository holds no unit configuration and points at none.
#   * The unit's secrets and trust material — wireless credentials, the access
#     list, the trust anchor, the update keyring — never enter this repository,
#     which is public. They live in the operator's store
#     (BRENN_PROVISIONING_STORE, by default ~/.brenn-provisioning: a private
#     directory outside any repository). Whether that store is instead tracked in
#     a private repository is the operator's call, and docs/provisioning.md says
#     what it costs.
#
# Two files are generated here rather than supplied: the machine id and the SSH
# host key. Both are generated once, kept in the store, and reused on every later
# assembly, because they are the unit's identity — the name its logs are filed
# under and the key that says it is the same device — and a reflash that changed
# either would look like a different machine to everything upstream.
#
# The run is a dry one until every input is present: a missing secret is reported
# alongside every other missing one, in one pass, so that gathering them is one
# trip rather than one trip per file.
#
# What a generation may leave out is the contract's business, not this script's:
# a unit that names no collector, no payload and no anchor assembles, and the
# device it configures boots, joins the network and answers SSH. See
# docs/provisioning.md.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# The contract — which files a generation carries, which of them are secret, what
# a host name and a machine id look like — is read from the one place that
# defines it, the copy the device itself runs. A second statement of it here is
# an assembly that produces what the device then refuses. Resolved the way
# provision.sh resolves the same file, so this runs from a checkout or from an
# installed image.
overlay="${repo_root}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn"
contract="${overlay}/brenn-config-lib.sh"
[ -r "$contract" ] || contract=/usr/lib/brenn/brenn-config-lib.sh
provision="${repo_root}/scripts/provision.sh"

# Where the operator's secrets live. Overridable because the location is the
# operator's decision, and so tests can use a disposable store.
if [ -n "${BRENN_PROVISIONING_STORE:-}" ]; then
	store_root=$BRENN_PROVISIONING_STORE
	store_provenance="BRENN_PROVISIONING_STORE"
else
	store_root=${HOME}/.brenn-provisioning
	if [ -n "${BRENN_PROVISIONING_STORE+set}" ]; then
		# Set to nothing — a wrapper or a profile expanding a variable that does
		# not exist. Telling this operator to set the variable would be a lie,
		# and the default they are getting is not the one they asked for.
		store_provenance="BRENN_PROVISIONING_STORE is set to nothing; using the default"
	else
		store_provenance="default; set BRENN_PROVISIONING_STORE to use another"
	fi
fi

# A relative root is resolved here, for the same reason the unit directory is
# below: every store path this run prints is an instruction to be followed, and
# one that only means something from the directory the run happened to start in
# gathers a unit's material somewhere nothing will look for it again.
case $store_root in
	/*) ;;
	*) store_root=${PWD}/${store_root} ;;
esac

force=0
out_dir=""

usage() {
	echo "usage: $(basename "$0") [-f] [-o <out-dir>] <unit-dir>" >&2
	echo "  <unit-dir>  the directory holding the unit's unit.conf; its name is the unit's" >&2
	echo "  -f          replace an existing generation directory" >&2
	echo "  -o          write the generation here (default: <store>/<unit>/generation)" >&2
}

die() {
	echo "assemble-generation: $*" >&2
	exit 1
}

# Problems are collected rather than fatal, so that one run names everything that
# has to be found or decided before the next one can succeed.
problems=0
problem() {
	echo "assemble-generation: $*" >&2
	problems=$((problems + 1))
}

while [ $# -gt 0 ]; do
	case $1 in
		-f)
			force=1
			shift
			;;
		-o)
			[ $# -ge 2 ] || {
				usage
				exit 2
			}
			# Normalised here because the scratch copy is a sibling built from
			# this path by hand: `-o gen/`, the shape tab completion offers,
			# would name `gen/.new.XXXXXX` under a directory nothing has
			# created, and the run would die on that template rather than on
			# the argument it came from.
			out_dir=$2
			while [ "$out_dir" != "${out_dir%/}" ]; do
				out_dir=${out_dir%/}
			done
			[ -n "$out_dir" ] ||
				die "-o '${2}' names no directory to write a generation into"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			exit 2
			;;
		*) break ;;
	esac
done

[ $# -eq 1 ] || {
	usage
	exit 2
}

# The argument is the unit's configuration directory, or the unit.conf in it. The
# unit's name is that directory's name: it is what the store files the unit's
# identity and secrets under, so it is resolved to an absolute path first — a
# relative `unit.conf` would otherwise be filed under `.`.
unit_arg=$1
if [ -d "$unit_arg" ]; then
	unit_dir=$unit_arg
elif [ -f "$unit_arg" ]; then
	unit_dir=$(dirname -- "$unit_arg")
	case $(basename -- "$unit_arg") in
		unit.conf) ;;
		*) die "${unit_arg} is not a unit.conf; name the unit's directory or its unit.conf" ;;
	esac
else
	die "no such unit directory: ${unit_arg}"
fi
unit_dir=$(cd -- "$unit_dir" && pwd)
unit=$(basename -- "$unit_dir")
unit_conf=${unit_dir}/unit.conf

# The name goes into store paths and into the announcement, so it is held to what
# reads unambiguously as one.
case $unit in
	*[!A-Za-z0-9._-]* | "" | . | ..)
		die "the unit directory's name is the unit's name, and '${unit}' is not usable as one"
		;;
esac

[ -r "$unit_conf" ] || die "no configuration for ${unit}: ${unit_conf} does not exist"

for tool in ssh-keygen install; do
	command -v "$tool" >/dev/null 2>&1 ||
		die "${tool} is not installed; it is needed to assemble a generation"
done

[ -r "$contract" ] ||
	die "the provisioning contract is not readable at ${contract}"
[ -x "$provision" ] ||
	die "the provisioning tool is not executable at ${provision}"
# shellcheck source=../image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-lib.sh
. "$contract"

# Every key a unit's configuration may set, and the only names that come back out
# of it.
unit_keys="UNIT_HOSTNAME WIFI_COUNTRY WIFI_SCAN_SSID JOURNAL_URL APP_URL APP_SHA256 NTP_SERVER"

# The configuration is shell, and reading it with `.` would run it in this
# script's own namespace: an assignment colliding with an internal name — force,
# out_dir, store_root, the contract's own tables — would silently reconfigure the
# tool, and unit.conf is a hand-edited file kept in version control. So it is read
# in a shell that starts with nothing but the keys above, holding the defaults for
# everything a unit may leave unsaid and empty for everything it has to state, and
# exactly those seven values come back.
#
# Every other name that file sets is returned too, and refused. A misspelled key
# otherwise reads as a feature deliberately left out — which for the optional ones
# is a legal configuration, so nothing further along would ever notice.
#
# UNIT_HOSTNAME rather than HOSTNAME: bash maintains one of its own.
unit_reader=$(
	cat <<'READER'
set -eu
__brenn_conf=$1
__brenn_keys=$2
UNIT_HOSTNAME=""
WIFI_COUNTRY=""
WIFI_SCAN_SSID=0
JOURNAL_URL=""
APP_URL=""
APP_SHA256=""
NTP_SERVER=""
__brenn_before=$(compgen -v | sort)
. "$__brenn_conf"
__brenn_after=$(compgen -v | sort)
for __brenn_name in $(comm -13 <(printf '%s\n' "$__brenn_before") <(printf '%s\n' "$__brenn_after")); do
	case " ${__brenn_keys} " in
	*" ${__brenn_name} "*) continue ;;
	esac
	case $__brenn_name in
	__brenn_*) continue ;;
	esac
	printf 'u%s\0' "$__brenn_name"
done
for __brenn_name in $__brenn_keys; do
	printf 'k%s=%s\0' "$__brenn_name" "${!__brenn_name}"
done
READER
)

# The values come back through a file, one NUL-terminated record each: a value may
# hold a newline, and a command substitution would drop the NULs that separate
# them.
unit_read=$(mktemp) || die "could not create a temporary file"
trap 'rm -f -- "$unit_read"' EXIT
env -i "PATH=${PATH}" bash --noprofile --norc -c "$unit_reader" \
	unit-conf-reader "$unit_conf" "$unit_keys" >"$unit_read" ||
	die "${unit_conf} could not be read as a configuration; the message above is the shell's"

# Named here only so that a reader which returned nothing fails on a value rather
# than on an unbound name — every one of them is overwritten below, and the
# defaults themselves are the reader's.
UNIT_HOSTNAME=""
WIFI_COUNTRY=""
WIFI_SCAN_SSID=""
JOURNAL_URL=""
APP_URL=""
APP_SHA256=""
NTP_SERVER=""

unknown_keys=""
while IFS= read -r -d '' record; do
	case $record in
		u*) unknown_keys="${unknown_keys} ${record#u}" ;;
		k*)
			record=${record#k}
			value=${record#*=}
			case ${record%%=*} in
				UNIT_HOSTNAME) UNIT_HOSTNAME=$value ;;
				WIFI_COUNTRY) WIFI_COUNTRY=$value ;;
				WIFI_SCAN_SSID) WIFI_SCAN_SSID=$value ;;
				JOURNAL_URL) JOURNAL_URL=$value ;;
				APP_URL) APP_URL=$value ;;
				APP_SHA256) APP_SHA256=$value ;;
				NTP_SERVER) NTP_SERVER=$value ;;
				*) die "the configuration reader returned '${record%%=*}', which is not a key" ;;
			esac
			;;
		*) die "the configuration reader returned a record this script does not understand" ;;
	esac
done <"$unit_read"
rm -f -- "$unit_read"
trap - EXIT

for name in $unknown_keys; do
	problem "${unit_conf} sets '${name}', which is not a key of the unit configuration; the keys are: ${unit_keys}"
done

# Not a unit knob: wpa_cli reaches the supplicant through this socket directory
# and looks here by default, while the supplicant opens it only if its
# configuration names one. The device wireless lane drives the radio through
# wpa_cli, so any other value produces a unit that associates and cannot be asked
# whether it did.
WPA_CTRL_INTERFACE=/run/wpa_supplicant

if [ -z "$UNIT_HOSTNAME" ]; then
	problem "${unit_conf} sets no UNIT_HOSTNAME"
elif ! printf '%s' "$UNIT_HOSTNAME" | grep -Eq "$BRENN_RE_HOSTNAME"; then
	problem "UNIT_HOSTNAME '${UNIT_HOSTNAME}' is not a single DNS label"
fi

if [ -z "$WIFI_COUNTRY" ]; then
	problem "${unit_conf} sets no WIFI_COUNTRY: the radio would have no channels it is allowed to use"
elif ! printf '%s' "$WIFI_COUNTRY" | grep -Eq '^[A-Z][A-Z]$'; then
	problem "WIFI_COUNTRY '${WIFI_COUNTRY}' is not a two-letter regulatory domain"
fi

# Anything but 1 would otherwise read as "the network is broadcast", so a
# spelling of yes would quietly produce a unit that never finds a hidden one.
case $WIFI_SCAN_SSID in
	0 | 1) ;;
	*) problem "WIFI_SCAN_SSID '${WIFI_SCAN_SSID}' is not 0 or 1; a network that does not broadcast its name needs 1" ;;
esac

# An address or a host name with a space or a newline in it renders into a drop-in
# that means something else, or nothing at all, and the device is where that gets
# discovered — the same reasoning the wireless credentials are checked under,
# applied to the values that are interpolated raw.
holds_blank() {
	case $1 in
		*[[:space:]]* | *[[:cntrl:]]*) return 0 ;;
	esac
	return 1
}

# The collector and the payload are each configured or not. Unset means the
# feature is left out of this generation — the device runs without it and says so
# — rather than a value this script could stand in for.
case $JOURNAL_URL in
	"") ;;
	https://?*)
		! holds_blank "$JOURNAL_URL" ||
			problem "JOURNAL_URL holds a space or a control character; the upload drop-in cannot carry one"
		;;
	*) problem "JOURNAL_URL '${JOURNAL_URL}' is not an https:// address; there is no plaintext option" ;;
esac

# The payload address and its digest are one value in two halves: an address with
# no digest is a device that fetches whatever is served, and a digest with no
# address is a decision half made.
if [ -n "$APP_URL" ] && [ -z "$APP_SHA256" ]; then
	problem "${unit_conf} sets APP_URL and no APP_SHA256; the digest is what answers for what was served"
elif [ -z "$APP_URL" ] && [ -n "$APP_SHA256" ]; then
	problem "${unit_conf} sets APP_SHA256 and no APP_URL; there is nothing for the digest to be of"
fi

if [ -n "$APP_URL" ]; then
	case $APP_URL in
		https://?*)
			! holds_blank "$APP_URL" ||
				problem "APP_URL holds a space or a control character; the fetch configuration cannot carry one"
			;;
		*) problem "APP_URL '${APP_URL}' is not an https:// address; there is no plaintext option" ;;
	esac
fi

if [ -n "$APP_SHA256" ]; then
	printf '%s' "$APP_SHA256" | grep -Eq '^[0-9a-f]{64}$' ||
		problem "APP_SHA256 is not 64 hex digits: '${APP_SHA256}'"
fi

if [ -n "$NTP_SERVER" ] && holds_blank "$NTP_SERVER"; then
	problem "NTP_SERVER holds a space or a control character; the time drop-in names one server"
fi

store=${store_root}/${unit}
identity=${store}/identity
inputs=${store}/inputs

# Every store path below carries this prefix, and a run whose store variable was
# forgotten differs from a run whose inputs are simply not gathered yet in that
# prefix alone. Said before the store is touched: a root that cannot be created
# or chmodded is exactly the case where the root is the thing in question, and
# mkdir's own message names a path without saying where it came from.
echo "assemble-generation: store ${store_root} (${store_provenance})" >&2

# The store holds secrets, so it is created private and stays that way — on every
# run, not only the one that created it: a clone of a repository holding a store
# arrives at the clone's umask, and this is what takes it back. Creating it here
# rather than requiring it means the first run of a new unit reports which files
# to put in it instead of refusing to look.
mkdir -p "$store_root" "$store" "$identity" "$inputs"
chmod 0700 "$store_root" "$store" "$identity" "$inputs"

# The operator's half of the store. Each entry is named with what it is for,
# because the refusal below is the whole instruction for assembling a new unit.
wifi_conf=${inputs}/wifi.conf
authorized_keys=${inputs}/authorized_keys
ca_pem=${inputs}/brenn-ca.pem
keyring_pem=${inputs}/rauc-keyring.pem

[ -f "$wifi_conf" ] ||
	problem "missing ${wifi_conf}: the wireless credentials, as SSID= and PSK= lines (a passphrase, or 64 hex digits); each value is the rest of its line, verbatim and unquoted"
[ -f "$authorized_keys" ] ||
	problem "missing ${authorized_keys}: the public keys admitted to the device as root"
# The update keyring is not conditional on anything: A/B slots exist from the
# first boot, and a device that can verify no bundle can only be changed by being
# taken apart.
[ -f "$keyring_pem" ] ||
	problem "missing ${keyring_pem}: the PEM certificate update bundles are verified against"

# The trust anchor is demanded exactly when this generation names something that
# would use it. The image carries no distribution certificate store, so an
# endpoint with no anchor here is a connection that can never succeed; with no
# endpoint at all, demanding one would force the decision for nothing.
anchor_for=""
[ -z "$JOURNAL_URL" ] || anchor_for="JOURNAL_URL"
if [ -n "$APP_URL" ]; then
	if [ -z "$anchor_for" ]; then
		anchor_for="APP_URL"
	else
		anchor_for="${anchor_for} and APP_URL"
	fi
fi
if [ -n "$anchor_for" ] && [ ! -f "$ca_pem" ]; then
	problem "missing ${ca_pem}: ${unit_conf} sets ${anchor_for}, and the device trusts nothing this generation does not carry (a public root is a legitimate anchor; a leaf certificate is not)"
fi

# wifi.conf is the operator's own file, not one of the generation's. A network
# name and a WPA passphrase may both legally contain spaces, so the reader here
# takes a value as the rest of its line, byte for byte — no quoting, and a
# trailing space would be part of it. Deliberately not the contract's
# brenn_conf_value: that grammar ends by deleting every space in the value,
# which would hash the right words against the wrong network name.
wifi_value() {
	sed -n "s/^[[:space:]]*${2}=//p" "$1" | head -n1
}

byte_length() {
	printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

wifi_ssid=""
wifi_psk=""
# Whether the operator gave the pre-shared key itself rather than a passphrase is
# decided once, here, and the composition below reads the answer. Deciding it
# twice would let the two decisions drift, and a hex key run through the
# derivation yields a well-formed generation for a unit that never associates.
wifi_psk_is_hex=0
if [ -f "$wifi_conf" ]; then
	wifi_ssid=$(wifi_value "$wifi_conf" SSID)
	wifi_psk=$(wifi_value "$wifi_conf" PSK)
	# Everything the rendered configuration cannot carry is refused here, because
	# nothing further along would notice: the supplicant file assembles, the
	# contract check passes, and the unit boots healthy and never associates —
	# which on this hardware is diagnosed by a teardown.
	ssid_bytes=$(byte_length "$wifi_ssid")
	if [ -z "$wifi_ssid" ]; then
		problem "${wifi_conf} names no SSID="
	elif [ "$ssid_bytes" -gt 32 ]; then
		problem "the SSID in ${wifi_conf} is ${ssid_bytes} bytes; a network name is at most 32"
	elif printf '%s' "$wifi_ssid" | LC_ALL=C grep -q '["[:cntrl:]]'; then
		problem "the SSID in ${wifi_conf} holds a double quote or a control character, which a quoted ssid= cannot carry; a carriage return from a Windows editor is the usual cause"
	fi
	psk_bytes=$(byte_length "$wifi_psk")
	if [ -z "$wifi_psk" ]; then
		problem "${wifi_conf} names no PSK="
	elif printf '%s' "$wifi_psk" | grep -Eq '^[0-9a-fA-F]{64}$'; then
		# Already the pre-shared key itself; used as it stands.
		wifi_psk_is_hex=1
	elif [ "$psk_bytes" -lt 8 ] || [ "$psk_bytes" -gt 63 ]; then
		problem "the PSK in ${wifi_conf} is ${psk_bytes} bytes; a WPA passphrase is 8 to 63 of them, or give the key itself as 64 hex digits"
	elif printf '%s' "$wifi_psk" | LC_ALL=C grep -q '[^ -~]'; then
		problem "the PSK in ${wifi_conf} holds a byte outside printable ASCII, which a WPA passphrase may not; give the key itself as 64 hex digits instead"
	fi
fi

if [ -f "$authorized_keys" ]; then
	grep -Eq '(^|[[:space:]])(ssh-|ecdsa-|sk-)' "$authorized_keys" ||
		problem "${authorized_keys} admits nobody: no public key in it"
fi
for pem in "$ca_pem" "$keyring_pem"; do
	[ -f "$pem" ] || continue
	grep -q 'BEGIN CERTIFICATE' "$pem" ||
		problem "${pem} is not a PEM certificate"
done

if [ "$problems" -gt 0 ]; then
	die "${problems} problem(s) above; nothing was assembled"
fi

# Identity: generated once and never again. Both files are the unit's, not this
# generation's — a later generation carries the same two, and a reflash restores
# them, which is the point of provisioning them rather than letting the device
# make its own.
machine_id_file=${identity}/machine-id
host_key=${identity}/ssh_host_ed25519_key

created=""
if [ ! -f "$machine_id_file" ]; then
	# 128 bits of hex, which is what machine-id(5) is.
	id=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
	[ "${#id}" -eq 32 ] || die "could not generate a machine id"
	printf '%s\n' "$id" >"$machine_id_file"
	chmod 0600 "$machine_id_file"
	created="${created} machine-id"
fi
id=$(brenn_first_line "$machine_id_file")
printf '%s' "$id" | grep -Eq "$BRENN_RE_MACHINE_ID" ||
	die "${machine_id_file} does not hold 32 hex digits"

if [ ! -f "$host_key" ]; then
	ssh-keygen -q -t ed25519 -N "" -C "${UNIT_HOSTNAME}" -f "$host_key" ||
		die "could not generate an SSH host key"
	created="${created} ssh-host-key"
fi
[ -f "${host_key}.pub" ] ||
	die "${host_key} exists without its public half; remove both to regenerate the pair"

# The output. A generation is written whole into a scratch directory and moved
# into place, so an interrupted run leaves nothing that looks like one.
[ -n "$out_dir" ] || out_dir=${store}/generation
if [ -e "$out_dir" ]; then
	[ "$force" -eq 1 ] ||
		die "${out_dir} exists; pass -f to replace it"
	[ -d "$out_dir" ] ||
		die "${out_dir} exists and is not a directory; look at it"
fi
# The scratch copy is a sibling of the destination, so the move into place is a
# rename within one filesystem and not a copy that can half happen. Nothing is
# said about the mode of a directory the operator named: it may be one that was
# already there for other things.
#
# The `.new.` template here and the `.old.` one further down have a consumer
# outside this script: an operator whose store is tracked in a repository
# ignores exactly those two patterns, so renaming either un-ignores whatever a
# killed run left behind. docs/provisioning.md states the recipe.
mkdir -p -- "$(dirname -- "$out_dir")"

scratch=$(mktemp -d "${out_dir}.new.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
chmod 0755 "$scratch"

for dir in $BRENN_CONTRACT_DIRECTORIES; do
	mkdir -m 0755 "${scratch}/${dir}"
done

put() {
	# One writer for every file in a generation, taking the mode from the
	# contract's own classification rather than from a mode written here twice.
	local rel=$1 src=$2 class mode
	class=""
	for entry in $BRENN_CONTRACT_REQUIRED $BRENN_CONTRACT_OPTIONAL; do
		[ "${entry%:*}" = "$rel" ] || continue
		class=${entry##*:}
	done
	case $class in
		secret) mode=0600 ;;
		public) mode=0644 ;;
		*) die "${rel} is not part of the provisioning contract" ;;
	esac
	install -m "$mode" -- "$src" "${scratch}/${rel}"
}

text() {
	# A file the assembly composes rather than copies. Written to scratch first so
	# that put() is still the only thing that decides a mode.
	local rel=$1 tmp
	tmp=$(mktemp "${scratch}/.compose.XXXXXX")
	cat >"$tmp"
	put "$rel" "$tmp"
	rm -f -- "$tmp"
}

printf '%s\n' "$UNIT_HOSTNAME" | text hostname
printf '%s\n' "$id" | text machine-id

# The supplicant configuration. A passphrase is turned into the pre-shared key
# here, so what reaches the device is the key the radio needs rather than the
# words somebody chose — those would be one more secret sitting on the device for
# nothing. A 64-hex PSK is already the key and is used as it stands.
#
# The derivation is 802.11i's: PBKDF2-HMAC-SHA1 over the passphrase, salted with
# the network name, 4096 iterations, 256 bits. `wpa_passphrase` computes exactly
# this, but only from a passphrase on its command line, and argv is world
# readable through /proc for the life of the process — every other process on the
# workstation could read the one credential this assembly exists to protect. So
# the passphrase goes down a pipe instead, and never appears in an argument list
# or in a message.
psk_line=""
if [ "$wifi_psk_is_hex" = 1 ]; then
	psk_line="psk=$(printf '%s' "$wifi_psk" | tr 'A-F' 'a-f')"
else
	command -v python3 >/dev/null 2>&1 ||
		die "python3 is not installed; it derives the pre-shared key from the passphrase. Install it, or put the key itself as 64 hex digits in ${wifi_conf}"
	psk_hex=$(printf '%s' "$wifi_psk" | python3 -c '
import hashlib, os, sys
sys.stdout.write(
    hashlib.pbkdf2_hmac(
        "sha1", sys.stdin.buffer.read(), os.fsencode(sys.argv[1]), 4096, 32
    ).hex()
)' "$wifi_ssid") || psk_hex=""
	printf '%s' "$psk_hex" | grep -Eq '^[0-9a-f]{64}$' ||
		die "no pre-shared key was derived from the credentials in ${wifi_conf}; check them, or put the key itself as 64 hex digits there"
	psk_line="psk=${psk_hex}"
fi

{
	echo "# wpa_supplicant configuration for wlan0. Assembled, not hand-edited."
	echo "country=${WIFI_COUNTRY}"
	echo "ctrl_interface=${WPA_CTRL_INTERFACE}"
	echo "network={"
	printf '\tssid="%s"\n' "$wifi_ssid"
	printf '\t%s\n' "$psk_line"
	if [ "$WIFI_SCAN_SSID" = 1 ]; then
		printf '\tscan_ssid=1\n'
	fi
	echo "}"
} | text net/wpa_supplicant-wlan0.conf

if [ -n "$NTP_SERVER" ]; then
	{
		echo "[Time]"
		echo "NTP=${NTP_SERVER}"
	} | text net/ntp.conf
fi

put ssh/ssh_host_ed25519_key "$host_key"
put ssh/ssh_host_ed25519_key.pub "${host_key}.pub"
put ssh/authorized_keys "$authorized_keys"
put rauc/keyring.pem "$keyring_pem"

# An anchor in the store is carried whether or not this generation names anything
# that reads it: trust staged ahead of the endpoint that will use it is harmless,
# and it is one fewer reassembly when the endpoint arrives.
if [ -f "$ca_pem" ]; then
	put ca/brenn-ca.pem "$ca_pem"
fi

# The collector's certificate has to chain to the anchor this same generation
# carries, and the device reads that anchor through the path the selected
# generation is published at — not through the path it was assembled at.
if [ -n "$JOURNAL_URL" ]; then
	{
		echo "[Upload]"
		echo "URL=${JOURNAL_URL}"
		echo "TrustedCertificateFile=/run/brenn/provisioning/ca/brenn-ca.pem"
	} | text journal/upload.conf
fi

if [ -n "$APP_URL" ]; then
	{
		echo "URL=${APP_URL}"
		echo "SHA256=${APP_SHA256}"
	} | text app/fetch.conf
fi

# Checked before it is anywhere anybody could mistake for finished, by the same
# tool that will install it on flash day. The target argument is a scratch
# directory: -n validates the generation and stops without touching it.
dry_target=$(mktemp -d)
if ! "$provision" -n "$dry_target" "$scratch"; then
	rmdir "$dry_target"
	die "the assembled generation does not satisfy the contract; nothing was written"
fi
rmdir "$dry_target"

# The replacement is two renames: the destination never holds a partly written
# generation, and the one being replaced is only removed once the new one is in
# its place. Its `.old.` template is the other pattern a tracked store ignores.
if [ -e "$out_dir" ]; then
	old=$(mktemp -d "${out_dir}.old.XXXXXX")
	mv -- "$out_dir" "${old}/generation"
	# Between the two renames the destination does not exist, and the cleanup that
	# was right up to here — delete the scratch copy — would leave nothing there at
	# all. For the length of the gap it puts the old one back instead, and if even
	# that cannot be done it says where both halves are rather than removing
	# either.
	#
	# The destination existing means the second rename has already run and the new
	# generation is in place: restoring then would move the old one *inside* it,
	# which is how `mv` treats a directory that is already there, and leave the
	# previous generation's secrets nested in what looks like a clean assembly.
	trap 'if [ -e "$out_dir" ] || mv -- "${old}/generation" "$out_dir" 2>/dev/null; then
		rm -rf -- "$scratch" "$old"
	else
		echo "assemble-generation: ${out_dir} is empty: the generation it held is at ${old}/generation and the new one at ${scratch}" >&2
	fi' EXIT
	mv -- "$scratch" "$out_dir"
	trap - EXIT
	rm -rf -- "$old"
else
	mv -- "$scratch" "$out_dir"
	trap - EXIT
fi

echo "assemble-generation: ${unit} assembled at ${out_dir}"
if [ -z "$created" ]; then
	echo "assemble-generation: identity reused from ${identity}"
else
	echo "assemble-generation: generated and stored in ${identity}:${created}"
fi
echo "assemble-generation: host key fingerprint $(ssh-keygen -lf "${host_key}.pub" | awk '{print $2}')"

# What this generation leaves out, said plainly: absence is a configuration and
# the operator should read it back rather than discover it on a device.
if [ -z "$JOURNAL_URL" ]; then
	echo "assemble-generation: no journal collector: the journal stays in RAM and ends at each reboot"
fi
if [ -z "$APP_URL" ]; then
	echo "assemble-generation: no application payload: the device runs the base system and no application"
fi
if [ -z "$NTP_SERVER" ]; then
	echo "assemble-generation: no local time server: the device uses the distribution's public pool"
fi

echo
echo "Flash day, with the persistent partition of the freshly written device:"
echo "  sudo ${provision} -n /dev/sdX6 ${out_dir}   # check only, before opening anything"
echo "  sudo ${provision}    /dev/sdX6 ${out_dir}"
