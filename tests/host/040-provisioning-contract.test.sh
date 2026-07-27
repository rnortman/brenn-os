#!/usr/bin/env bash
#
# What a provisioning generation has to be, and what installing the first one
# does.
#
# The contract check is the only thing standing between a mistyped directory and
# a device that has to be taken apart to be recovered — no wireless credentials,
# no host key, no way in but a serial cable. So each rule gets a case that
# violates exactly it, and the conformant generation is built once so that a
# rule which quietly stops being checked shows up as a case that passes for the
# wrong reason.
#
# No key material here is real: the fixtures are the shapes of keys, and the
# addresses are placeholders.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/generation.sh
. "${BRENN_TESTS_LIB}/generation.sh"

validate="${BRENN_REPO_ROOT}/image/layer/brenn/provisioning.rootfs-overlay/usr/lib/brenn/brenn-config-validate"
provision="${BRENN_REPO_ROOT}/scripts/provision.sh"

for bin in "$validate" "$provision"; do
	if [ ! -x "$bin" ]; then
		t_fail "the provisioning tools are present and executable" "not at ${bin}"
		t_done
	fi
done

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

gen_no=0
new_gen() {
	gen_no=$((gen_no + 1))
	gen="${work}/gen-${gen_no}"
	gen_make "$gen"
}

# Run the checker over the current generation and report its verdict as a word,
# so an assertion reads as the outcome rather than as an exit status.
verdict() {
	if "$validate" "$@" "$gen" >"${work}/out" 2>&1; then
		echo accepted
	else
		echo refused
	fi
}

# The generation as assembled: everything present, nothing exposed. If this ever
# fails, every refusal below is meaningless.
new_gen
t_eq "a conformant generation is accepted" "$(verdict)" accepted

# Each required file, one at a time. A device missing any one of these is a
# device missing a way onto the network, an identity, or a way in.
for f in hostname machine-id net/wpa_supplicant-wlan0.conf \
	ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub ssh/authorized_keys \
	ca/brenn-ca.pem rauc/keyring.pem journal/upload.conf app/fetch.conf; do
	new_gen
	rm -f "${gen}/${f}"
	t_eq "a generation missing ${f} is refused" "$(verdict)" refused
done

# The local time server is the one optional file: without it the distribution's
# public pool applies, which is a working clock.
new_gen
t_eq "a generation with no local time server is accepted" "$(verdict)" accepted

new_gen
printf '[Time]\nNTP=time.example.internal\n' >"${gen}/net/ntp.conf"
t_eq "a local time server is accepted" "$(verdict)" accepted

new_gen
printf 'NTP=time.example.internal\n' >"${gen}/net/ntp.conf"
t_eq "a time drop-in with no section — which timesyncd would ignore — is refused" \
	"$(verdict)" refused

# Permissions. The private key is the case the contract names explicitly, and it
# is the one where refusing after the fact is still worth something: a key that
# arrived readable has been readable.
new_gen
chmod 0644 "${gen}/ssh/ssh_host_ed25519_key"
t_eq "a world-readable host key is refused" "$(verdict)" refused

new_gen
chmod 0640 "${gen}/ssh/ssh_host_ed25519_key"
t_eq "a group-readable host key is refused" "$(verdict)" refused

new_gen
chmod 0400 "${gen}/ssh/ssh_host_ed25519_key"
t_eq "a host key stricter than the schema is accepted" "$(verdict)" accepted

new_gen
chmod 0644 "${gen}/net/wpa_supplicant-wlan0.conf"
t_eq "world-readable wireless credentials are refused" "$(verdict)" refused

# sshd resolves the whole path to the access list and refuses one that somebody
# else could have replaced. It is right to, and the check is here so the refusal
# happens on a workstation instead of on a device with no other way in.
new_gen
chmod 0777 "${gen}/ssh"
t_eq "a group- and world-writable directory is refused" "$(verdict)" refused

new_gen
chmod 0757 "$gen"
t_eq "a writable generation root is refused" "$(verdict)" refused

new_gen
chmod 0755 "${gen}/ssh/authorized_keys"
t_eq "an executable access list is refused" "$(verdict)" refused

# Ownership is a property of an installed generation, not of one in an
# operator's working directory, so it is only checked when asked for.
new_gen
t_eq "an unowned generation is accepted on a workstation" "$(verdict)" accepted
if [ "$(id -u)" -eq 0 ]; then
	t_eq "an installed generation belonging to root is accepted" \
		"$(verdict --installed)" accepted
else
	t_eq "a generation not owned by root is refused once installed" \
		"$(verdict --installed)" refused
fi

# Formats. Each of these is a value the device applies without a second look, so
# a malformed one is either a boot that reports and carries on with the wrong
# identity, or a service that never starts.
new_gen
printf 'Not A Hostname\n' >"${gen}/hostname"
t_eq "a host name that is not a DNS label is refused" "$(verdict)" refused

new_gen
printf 'not-a-machine-id\n' >"${gen}/machine-id"
t_eq "a machine id that is not 32 hex digits is refused" "$(verdict)" refused

new_gen
sed -i '/^country=/d' "${gen}/net/wpa_supplicant-wlan0.conf"
t_eq "wireless credentials with no regulatory domain are refused" "$(verdict)" refused

new_gen
sed -i 's/^country=US/country=usa/' "${gen}/net/wpa_supplicant-wlan0.conf"
t_eq "a regulatory domain that is not a country code is refused" "$(verdict)" refused

new_gen
printf 'country=US\n' >"${gen}/net/wpa_supplicant-wlan0.conf"
t_eq "wireless credentials declaring no network are refused" "$(verdict)" refused

new_gen
printf 'ssh-ed25519 AAAAfixture\n' >"${gen}/ssh/ssh_host_ed25519_key"
t_eq "a host key that is not a private key is refused" "$(verdict)" refused

new_gen
printf 'ssh-rsa AAAAfixture unit\n' >"${gen}/ssh/ssh_host_ed25519_key.pub"
t_eq "a public half of the wrong type is refused" "$(verdict)" refused

new_gen
printf '# nobody\n\n' >"${gen}/ssh/authorized_keys"
t_eq "an access list admitting nobody is refused" "$(verdict)" refused

new_gen
gen_pem 'OPENSSH PRIVATE KEY' bm90LWEtY2VydA== >"${gen}/ca/brenn-ca.pem"
t_eq "a trust anchor that is not a certificate is refused" "$(verdict)" refused

new_gen
printf 'nothing here\n' >"${gen}/rauc/keyring.pem"
t_eq "an update keyring that is not a certificate is refused" "$(verdict)" refused

# TLS everywhere is not a preference. A collector reached over http would ship
# every log line this device produces in clear.
new_gen
sed -i 's|URL=https://|URL=http://|' "${gen}/journal/upload.conf"
t_eq "a plaintext collector is refused" "$(verdict)" refused

new_gen
sed -i 's|URL=https://|URL=http://|' "${gen}/app/fetch.conf"
t_eq "a plaintext payload source is refused" "$(verdict)" refused

# The collector's certificate is signed by the anchor this same generation
# carries; trusting anything else means trusting the distribution's store, which
# has never heard of it, and the upload fails at run time with a TLS error.
new_gen
sed -i 's|^TrustedCertificateFile=.*|TrustedCertificateFile=/etc/ssl/certs/ca-certificates.crt|' \
	"${gen}/journal/upload.conf"
t_eq "a collector trusting the wrong anchor is refused" "$(verdict)" refused

new_gen
sed -i 's|^TrustedCertificateFile=.*|TrustedCertificateFile=/data/provisioning/ca/brenn-ca.pem|' \
	"${gen}/journal/upload.conf"
t_eq "a collector reaching past the published path is refused" "$(verdict)" refused

new_gen
sed -i '/^\[Upload\]/d' "${gen}/journal/upload.conf"
t_eq "an upload configuration with no section is refused" "$(verdict)" refused

new_gen
sed -i 's/^SHA256=.*/SHA256=not-a-digest/' "${gen}/app/fetch.conf"
t_eq "a payload digest that is not one is refused" "$(verdict)" refused

# The payload is executable code arriving over the network, and the digest is
# the only thing that answers for it once TLS has said who served it. Leaving it
# out is not a lighter configuration, it is an unverified one — and it would be
# a one-character mistake away at every provisioning.
new_gen
sed -i '/^SHA256=/d' "${gen}/app/fetch.conf"
t_eq "a payload source naming no digest is refused" "$(verdict)" refused

new_gen
sed -i 's/^SHA256=/Sha256=/' "${gen}/app/fetch.conf"
t_eq "a digest under a key nobody reads is refused, not silently skipped" \
	"$(verdict)" refused

# One grammar, read by one function: what the bench accepts here is what the
# device resolves to the same URL and digest. A space after the `=` is the
# spelling most likely to parse differently across independent implementations.
new_gen
{
	printf 'URL= https://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'SHA256= %064d\n' 0
} >"${gen}/app/fetch.conf"
t_eq "a fetch source written with space after the = is accepted" "$(verdict)" accepted

# The published grammar's tie-break: a file naming a key twice is one somebody
# edited without deciding, and the first assignment is what both readers take.
# Asserted from both sides, because the value of the rule is that the bench and
# the device pick the *same* line — a check reading one and a runner reading the
# other is a device fetching a payload nothing verified.
new_gen
{
	printf 'URL=https://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'URL=http://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'SHA256=%064d\n' 0
} >"${gen}/app/fetch.conf"
t_eq "with a key named twice, the first assignment is what is read" \
	"$(verdict)" accepted

new_gen
{
	printf 'URL=http://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'URL=https://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'SHA256=%064d\n' 0
} >"${gen}/app/fetch.conf"
t_eq "and a later line does not rescue a first one that is refused" \
	"$(verdict)" refused

new_gen
{
	printf 'URL=https://payload.example.internal/reachy/payload.tar.zst\n'
	printf 'SHA256=not-a-digest\n'
	printf 'SHA256=%064d\n' 0
} >"${gen}/app/fetch.conf"
t_eq "which holds for the digest as well" "$(verdict)" refused

# Anything else in the directory. None of the rules above cover a file nobody
# expected, and the ones that turn up in practice — a working copy of a key, an
# editor's backup — are exactly the ones that should not reach a device.
new_gen
cp "${gen}/ssh/ssh_host_ed25519_key" "${gen}/ssh/ssh_host_ed25519_key.old"
t_eq "a stray copy of a key is refused" "$(verdict)" refused

new_gen
mkdir -p "${gen}/notes"
t_eq "a directory nobody expected is refused" "$(verdict)" refused

new_gen
ln -s /etc/hostname "${gen}/hostname.link"
t_eq "a link out of the generation is refused" "$(verdict)" refused

# Everything a generation carries is a plain file, and the rules above are all
# written for one. Anything else — a pipe, a device node — is refused as a
# shape rather than let through to whatever would open it on the device.
new_gen
mkfifo "${gen}/net/pipe"
t_eq "something that is not a regular file is refused" "$(verdict)" refused

# Installing the first one. The write path needs root, both to own the files and
# to mount the partition; a user namespace gives us that without one, and the
# lane says so rather than passing silently if it cannot.
run_provision() {
	rc=0
	if [ "$(id -u)" -eq 0 ]; then
		"$provision" "$@" >"${work}/prov-out" 2>&1 || rc=$?
	else
		unshare -r "$provision" "$@" >"${work}/prov-out" 2>&1 || rc=$?
	fi
}

if [ "$(id -u)" -ne 0 ] && ! unshare -r true 2>/dev/null; then
	echo "SKIP  installing a generation needs root or a user namespace"
else
	new_gen
	target="${work}/target"
	mkdir -p "$target"
	run_provision "$target" "$gen"
	t_eq "installing the first generation succeeds" "$rc" 0
	t_eq "it is committed, not on trial" \
		"$(readlink "${target}/provisioning/active" 2>/dev/null)" gen-1
	t_eq "no trial is left in flight" \
		"$([ -e "${target}/provisioning/trial" ] && echo present || echo missing)" missing
	t_eq "the generation is installed whole" \
		"$(cat "${target}/provisioning/gen-1/hostname" 2>/dev/null)" unit-under-test
	# The same modes the on-device tool installs, because both tools install
	# through the same program and take the list of secrets from the same
	# contract. A generation's permissions cannot depend on which of the two
	# put it there.
	t_eq "the host key is installed unreadable to anyone else" \
		"$(stat -c '%a' "${target}/provisioning/gen-1/ssh/ssh_host_ed25519_key" 2>/dev/null)" 600
	t_eq "so are the wireless credentials" \
		"$(stat -c '%a' "${target}/provisioning/gen-1/net/wpa_supplicant-wlan0.conf" 2>/dev/null)" 600
	t_eq "the access list is installed readable" \
		"$(stat -c '%a' "${target}/provisioning/gen-1/ssh/authorized_keys" 2>/dev/null)" 644
	t_eq "nothing is left staged" \
		"$([ -e "${target}/provisioning/gen-1.new" ] && echo present || echo missing)" missing

	# What was installed is what the device will accept: the same rules, run
	# against the copy.
	gen="${target}/provisioning/gen-1"
	t_eq "the installed generation satisfies the contract" "$(verdict)" accepted

	# Second run on the same partition. Changing configuration after the first
	# time is a transaction on the running device, which trials the change and
	# reverts it; overwriting the committed generation from the bench would skip
	# exactly that.
	new_gen
	run_provision "$target" "$gen"
	t_eq "a device that already has a generation is refused" "$rc" 1
	t_eq "and the committed generation is untouched" \
		"$(readlink "${target}/provisioning/active" 2>/dev/null)" gen-1

	# A generation that fails the contract writes nothing at all — not a
	# partially populated store, which would boot looking configured.
	new_gen
	rm -f "${gen}/ssh/authorized_keys"
	empty="${work}/target-empty"
	mkdir -p "$empty"
	run_provision "$empty" "$gen"
	t_eq "an invalid generation is refused" "$rc" 1
	t_eq "and nothing is written" \
		"$([ -e "${empty}/provisioning" ] && echo present || echo missing)" missing

	# The check-only mode, which is what an operator runs before taking a device
	# apart.
	new_gen
	run_provision -n "$empty" "$gen"
	t_eq "a check-only run accepts a conformant generation" "$rc" 0
	t_eq "a check-only run writes nothing" \
		"$([ -e "${empty}/provisioning" ] && echo present || echo missing)" missing

	run_provision "${work}/no-such-target" "$gen"
	t_eq "a target that is neither a device nor a mount is refused" "$rc" 1
fi

t_done
