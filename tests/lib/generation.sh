# A conformant provisioning generation, as a fixture. Source, don't execute.
#
# The shape of one, and nothing more: no key here is a key, every address is a
# placeholder, and the whole thing exists so that a test which refuses a
# generation refuses it for the reason the test names rather than because the
# fixture was never acceptable in the first place.

# shellcheck shell=bash

# Where the device publishes the selected generation. The collector's trust
# anchor has to be named through that path and not through the store, so the
# fixture has to know it.
GEN_PUBLISHED=/run/brenn/provisioning

# PEM armour, assembled from its parts rather than written out: the secret
# scanners that guard this repository match a private-key header wherever they
# find one, and a fixture that tripped them would have to carry an exemption.
gen_pem() {
	printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "$1" "$2" "$1"
}

# Build one at the given path, with the ownership-independent half of the modes
# the contract requires. Callers mutate a fresh copy per case, so that a
# mutation cannot leak into the next one.
gen_make() {
	local dir=$1
	mkdir -p "${dir}"/{net,ssh,ca,rauc,journal,app}

	printf 'unit-under-test\n' >"${dir}/hostname"
	printf '00112233445566778899aabbccddeeff\n' >"${dir}/machine-id"

	cat >"${dir}/net/wpa_supplicant-wlan0.conf" <<-'EOF'
		country=US
		network={
			ssid="example"
			psk="not-a-real-secret"
		}
	EOF

	gen_pem 'OPENSSH PRIVATE KEY' bm90LWEtcmVhbC1rZXk= >"${dir}/ssh/ssh_host_ed25519_key"
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfixture unit\n' \
		>"${dir}/ssh/ssh_host_ed25519_key.pub"
	printf '# the operators\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfixture operator\n' \
		>"${dir}/ssh/authorized_keys"

	gen_pem CERTIFICATE bm90LWEtcmVhbC1jZXJ0 >"${dir}/ca/brenn-ca.pem"
	cp "${dir}/ca/brenn-ca.pem" "${dir}/rauc/keyring.pem"

	cat >"${dir}/journal/upload.conf" <<-EOF
		[Upload]
		URL=https://journal.example.internal:19532
		TrustedCertificateFile=${GEN_PUBLISHED}/ca/brenn-ca.pem
	EOF

	cat >"${dir}/app/fetch.conf" <<-'EOF'
		URL=https://payload.example.internal/reachy/payload.tar.zst
	EOF
	gen_pem CERTIFICATE bm90LWEtcmVhbC1jbGllbnQ= >"${dir}/app/client.crt"
	gen_pem 'PRIVATE KEY' bm90LWEtcmVhbC1jbGllbnQta2V5 >"${dir}/app/client.key"

	# Spelled out rather than read from the contract the programs share. A
	# fixture built from the rules it is used to test would conform to whatever
	# they happen to say; this one states what a conformant generation is
	# independently, so a contract that grows a file or a secret fails here
	# until somebody agrees it should.
	chmod 0755 "$dir" "${dir}"/{net,ssh,ca,rauc,journal,app}
	find "$dir" -type f -exec chmod 0644 {} +
	chmod 0600 "${dir}/ssh/ssh_host_ed25519_key" "${dir}/net/wpa_supplicant-wlan0.conf" \
		"${dir}/app/client.key"
}
