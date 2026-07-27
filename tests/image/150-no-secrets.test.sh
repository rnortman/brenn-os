#!/usr/bin/env bash
#
# The image carries no secrets.
#
# Every other test here asserts that one particular credential comes from
# provisioning — the host key, the collector's trust anchor, the wireless
# passphrase. This one asks the question from the other side, over the whole of
# /etc: is there a key or a certificate anywhere that nobody accounted for?
#
# It matters because the answer is a property of the build, not of any layer we
# wrote: a package's postinst generating a key pair at install time is ordinary
# behaviour, and the result is a credential shared by every device built from
# the image, published in a public, reproducible build.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root
t_require_cmd find grep

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One copy of the tree, then find and grep: a per-file question asked through
# the reader would be thousands of invocations.
if ! img_ext4_rdump "$IMG_SPEC" /etc "$work"; then
	t_fail "copy /etc out of the root filesystem" "the reader wrote nothing to ${work}"
	t_done
fi
etc="${work}/etc"

# The distribution's trust store is the one place certificates belong: it is
# public CAs, it ships in a package, and it is the same on every Debian system.
# Anything key-shaped outside it was put there by this build.
suspects=$(find "$etc" \( -path "${etc}/ssl/certs" -o -path "${etc}/ca-certificates" \) -prune -o \
	-type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.key' \
	-o -name '*.p12' -o -name '*.pfx' -o -name '*_key' -o -name 'id_*' \) -print |
	sed "s|^${work}/|/|" | sort)

if [ -z "$suspects" ]; then
	t_pass "no key or certificate under /etc outside the distribution's trust store"
else
	t_fail "no key or certificate under /etc outside the distribution's trust store" \
		"found: $(printf '%s' "$suspects" | tr '\n' ' ')"
fi

# And by content rather than by name, which is what catches a key written to a
# path nobody would think to look at. A private key in an image is the worst
# case of all of this: it is a credential every device built from that image
# holds, and one that a public build hands to anybody.
private=$(grep -rlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$etc" 2>/dev/null |
	sed "s|^${work}/|/|" | sort)

if [ -z "$private" ]; then
	t_pass "no private key material under /etc"
else
	t_fail "no private key material under /etc" \
		"found: $(printf '%s' "$private" | tr '\n' ' ')"
fi

t_done
