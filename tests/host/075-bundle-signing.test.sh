#!/usr/bin/env bash
#
# Signing and verifying an update bundle, off the build.
#
# The device installs nothing it cannot verify against the trust anchor its
# provisioning generation carries, so the signing path is load-bearing twice
# over: a bundle that will not verify cannot be installed at all, and one that
# verifies against the wrong anchor would mean the check is not doing anything.
# Both are asserted here, on a bundle of a few kilobytes rather than of a real
# root filesystem, because what is being checked is the mechanism.
#
# The signing pair is generated for this run and never leaves the temporary
# directory it is made in. No key of any kind is in this tree, including a
# throwaway one.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

# The packing toolchain. CI installs all three, so a skip here is a workstation
# without them and never the gate's own path — which is what makes a green CI
# run mean the signing path was actually exercised.
for cmd in openssl rauc mksquashfs; do
	command -v "$cmd" >/dev/null 2>&1 ||
		t_skip "requires ${cmd}, which is not installed (installed and enforced in CI)"
done

make_bundle="${BRENN_REPO_ROOT}/scripts/make-bundle.sh"
[ -x "$make_bundle" ] || {
	t_fail "the bundle tool is present and executable" "not at ${make_bundle}"
	t_done
}

expectations="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env"
[ -f "$expectations" ] || t_skip "no expectations for profile '${BRENN_PROFILE}'"
# shellcheck disable=SC1090  # path is profile-dependent by design
. "$expectations"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Two unrelated self-signed pairs: one signs, the other stands for a device
# provisioned to trust somebody else.
new_signer() {
	local dir="${work}/$1"
	mkdir -p "$dir"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-subj "/CN=brenn-os throwaway $1" \
		-keyout "${dir}/signing" -out "${dir}/anchor" >/dev/null 2>&1 ||
		return 1
	printf '%s' "$dir"
}

mine=$(new_signer mine) || {
	t_fail "generate a throwaway signing pair"
	t_done
}
theirs=$(new_signer theirs) || {
	t_fail "generate a second throwaway signing pair"
	t_done
}

# A build's output, in miniature: the two slot images the update replaces and
# the description the version is read from. Incompressible content, because the
# packer refuses a payload that compresses down to nothing — a real pair of
# filesystem images is never that small.
dir="${work}/image-out"
mkdir -p "$dir"
head -c 262144 /dev/urandom >"${dir}/boot.vfat"
head -c 262144 /dev/urandom >"${dir}/system.ext4"
cat >"${dir}/image.json" <<-EOF
	{
	    "IGmeta": {
	        "IGconf_image_version": "2026.07.26-signing"
	    }
	}
EOF

bundle="${work}/out.raucb"

# Every run gets a local overlay of this test's own and starts from a cleared
# environment: a build host with signing material configured — which is every
# host that has ever cut a release — must assert exactly what a bare clone
# does. The overlay path is a variable so the cases below can put content in
# it and drive the precedence assertions.
conf="${work}/bundle.conf"
: >"$conf"
run_bundle() {
	t_env_scrubbed BRENN_BUNDLE_ BRENN_BUNDLE_CONF="$conf" "$make_bundle" "$@" 2>&1
}

out=$(run_bundle \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	--keyring "${mine}/anchor" \
	--output "$bundle" "$dir")
rc=$?

t_eq "packing and signing a bundle succeeds" "$rc" 0
if [ "$rc" -ne 0 ]; then
	t_fail "the tool's output" "$out"
	t_done
fi

t_eq "the bundle is written where it was asked for" \
	"$([ -f "$bundle" ] && echo yes)" yes
t_eq "the tool reports having verified it" \
	"$(printf '%s\n' "$out" | grep -c '^make-bundle: verified against ')" 1
# Two lines with a verb, in this order. A bare path says nothing about whether
# what it names was checked, and an operator reading a transcript has only
# these lines to go on.
t_contains "and names what it wrote, as having been written" \
	"$out" "make-bundle: wrote ${bundle}"
t_eq_text "the outcome is stated in two lines and nothing else" \
	"$(printf '%s\n' "$out" | grep '^make-bundle: ')" \
	"$(printf '%s\n%s\n' "make-bundle: verified against ${mine}/anchor" \
		"make-bundle: wrote ${bundle}")"
# The packer verifies its own output, which it says it is skipping when it is
# not handed an anchor. That line's absence is what shows --signing-keyring
# arrived: a bundle can be signed and unchecked and look identical otherwise.
t_lacks "the packer did not skip its own signature check" \
	"$out" "No keyring given"
t_eq "the staging directory is not left behind" \
	"$([ -e "${dir}/bundle-stage" ] || echo gone)" gone

# What the device would read out of the bundle before deciding to install it.
info=$(rauc info --keyring="${mine}/anchor" --output-format=shell "$bundle" 2>/dev/null)
t_eq "the bundle verifies against the anchor that signed it" "$?" 0
t_contains "and is compatible with this device family" \
	"$info" "RAUC_MF_COMPATIBLE='${EXPECT_RAUC_COMPATIBLE}'"
t_contains "and carries the version the build stamped" \
	"$info" "RAUC_MF_VERSION='2026.07.26-signing'"
# Quoting of this one value differs between the version that packs a bundle on
# a build host and the version that reads it on a device, so it is matched
# rather than compared.
if printf '%s\n' "$info" | grep -Eq "^RAUC_MF_IMAGES='?2'?$"; then
	t_pass "and carries both slot images"
else
	t_fail "and carries both slot images" "no image count of 2 in the manifest"
fi
t_contains "the root filesystem image, for the rootfs slot" \
	"$info" "RAUC_IMAGE_CLASS_0='rootfs'"
t_contains "under the name the manifest gave it" \
	"$info" "RAUC_IMAGE_NAME_0='system.ext4'"
t_contains "the boot filesystem image, for the boot slot" \
	"$info" "RAUC_IMAGE_CLASS_1='boot'"
t_contains "under the name the manifest gave it" \
	"$info" "RAUC_IMAGE_NAME_1='boot.vfat'"

# Asked for nothing in particular, the tool writes the bundle beside the build
# it packed, named for the image and the version. That name is what `make
# bundle` produces and what the image lane's verify step globs for, so it is
# asserted here rather than discovered half an hour into a build as a glob that
# matched nothing.
default_dir="${work}/image-${EXPECT_IMAGE_NAME}"
mkdir -p "$default_dir"
cp "${dir}/boot.vfat" "${dir}/system.ext4" "${dir}/image.json" "$default_dir/"

out=$(run_bundle \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	"$default_dir")
rc=$?
t_eq "packing without being told where to write it succeeds" "$rc" 0
t_eq "and the bundle is beside the build, named for the image and the version" \
	"$([ -f "${default_dir}/${EXPECT_IMAGE_NAME}-2026.07.26-signing.raucb" ] && echo yes)" yes

# That run named no trust anchor. Verification still happened — against the
# certificate that signed it, which in the single-pair configuration is the
# same file a device is provisioned with. The alternative, skipping the check
# because nobody named an anchor, is a bundle nobody looked at, reported as a
# success.
#
# It is a round trip and not an independent check, which is why the tool says
# out loud which anchor it fell back to: a transcript must never show a
# verification against something the operator did not choose.
t_contains "an unnamed anchor defaults to the signing cert, out loud" \
	"$out" "make-bundle: BRENN_BUNDLE_KEYRING unset; verifying against the signing cert (single-pair bring-up)"
t_contains "and the verification names that cert" \
	"$out" "make-bundle: verified against ${mine}/anchor"

# The whole point of signing: an anchor that did not sign this bundle refuses
# it. A device trusts exactly one keyring, and this is what that buys.
if rauc info --keyring="${theirs}/anchor" --output-format=shell "$bundle" >/dev/null 2>&1; then
	t_fail "a bundle signed by someone else is refused" \
		"it verified against an unrelated trust anchor"
else
	t_pass "a bundle signed by someone else is refused"
fi

out=$(run_bundle \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	--keyring "${theirs}/anchor" \
	--output "${work}/unverifiable.raucb" "$dir")
rc=$?
t_fails "packing against a trust anchor that will not verify it fails" "$rc" "$out"
t_eq "and says so" \
	"$(printf '%s\n' "$out" | grep -c 'does not verify against')" 1

# --- what is checked before anything is staged -----------------------------

# Staging copies the whole root filesystem. A missing key discovered after that
# is the same refusal, minutes later and gigabytes heavier, so the signing
# material is settled first and the untouched staging directory is what proves
# the order.
early="${work}/image-early"
mkdir -p "$early"
cp "${dir}/boot.vfat" "${dir}/system.ext4" "${dir}/image.json" "$early/"

out=$(run_bundle --key "${mine}/signing" --output "${work}/early.raucb" "$early")
rc=$?
t_fails "packing with no signing certificate fails" "$rc" "$out"
t_has "and says which knob supplies one" \
	"$out" "no signing certificate"
t_has "and where the pair comes from" \
	"$out" "docs/provisioning.md"
t_eq "having staged nothing" \
	"$([ -e "${early}/bundle-stage" ] || echo gone)" gone

out=$(run_bundle --cert "${mine}/anchor" --key "${work}/absent-key" \
	--output "${work}/early.raucb" "$early")
rc=$?
t_fails "packing with a key that is not there fails" "$rc" "$out"
t_eq "before staging anything either" \
	"$([ -e "${early}/bundle-stage" ] || echo gone)" gone

# --- where the paths come from ---------------------------------------------

# The signing material is three paths that are the same on every run of a given
# build host and are never in the tree, so they are written once into a
# gitignored overlay. Precedence is the one every other lane here uses: an
# exported value is the more specific statement of intent and outranks the
# file.
cat >"$conf" <<CONF
BRENN_BUNDLE_CERT=${mine}/anchor
BRENN_BUNDLE_KEY=${mine}/signing
BRENN_BUNDLE_KEYRING=${theirs}/anchor
CONF

out=$(run_bundle --output "${work}/overlay.raucb" "$dir")
rc=$?
t_fails "the overlay supplies the signing material" "$rc" "$out"
t_eq "including the anchor, which this one names deliberately wrong" \
	"$(printf '%s\n' "$out" | grep -c "does not verify against ${theirs}/anchor")" 1

out=$(t_env_scrubbed BRENN_BUNDLE_ \
	BRENN_BUNDLE_KEYRING="${mine}/anchor" \
	BRENN_BUNDLE_CONF="$conf" \
	"$make_bundle" --output "${work}/overlay.raucb" "$dir" 2>&1)
rc=$?
t_eq "an exported knob outranks the overlay's answer" "$rc" 0
t_contains "and is the anchor the result is verified against" \
	"$out" "make-bundle: verified against ${mine}/anchor"

# The third rung, which the two above leave unstated: a flag is the most
# specific statement of all. Were the overlay ever loaded after the arguments
# were parsed, `make bundle --output …` would quietly stop working on every
# configured build host and this suite would stay green.
out=$(t_env_scrubbed BRENN_BUNDLE_ \
	BRENN_BUNDLE_KEYRING="${theirs}/anchor" \
	BRENN_BUNDLE_CONF="$conf" \
	"$make_bundle" --keyring "${mine}/anchor" \
	--output "${work}/flag.raucb" "$dir" 2>&1)
rc=$?
t_eq "a flag outranks the overlay and the environment together" "$rc" 0
t_contains "and names the anchor the flag chose" \
	"$out" "make-bundle: verified against ${mine}/anchor"

# Empty is not a value: an exported knob with nothing in it reads as one nobody
# set, at every lane's overlay, which is what lets a caller name a tool's whole
# knob set empty to keep a configured host out of a run. The documented
# consequence, asserted here because it is the surprising half — the file still
# answers, and the way past it is the flag above.
out=$(t_env_scrubbed BRENN_BUNDLE_ \
	BRENN_BUNDLE_KEYRING= \
	BRENN_BUNDLE_CONF="$conf" \
	"$make_bundle" --output "${work}/empty.raucb" "$dir" 2>&1)
rc=$?
t_fails "a knob exported empty leaves the overlay's answer standing" "$rc" "$out"
t_eq "which here is the anchor the overlay names deliberately wrong" \
	"$(printf '%s\n' "$out" | grep -c "does not verify against ${theirs}/anchor")" 1
t_lacks "and the unset-keyring default is not what it took" \
	"$out" "BRENN_BUNDLE_KEYRING unset"

t_done
