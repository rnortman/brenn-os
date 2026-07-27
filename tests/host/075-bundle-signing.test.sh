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

t_require_cmd openssl rauc mksquashfs

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

out=$("$make_bundle" \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	--keyring "${mine}/anchor" \
	--output "$bundle" "$dir" 2>&1)
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

out=$("$make_bundle" \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	"$default_dir" 2>&1)
rc=$?
t_eq "packing without being told where to write it succeeds" "$rc" 0
t_eq "and the bundle is beside the build, named for the image and the version" \
	"$([ -f "${default_dir}/${EXPECT_IMAGE_NAME}-2026.07.26-signing.raucb" ] && echo yes)" yes

# The whole point of signing: an anchor that did not sign this bundle refuses
# it. A device trusts exactly one keyring, and this is what that buys.
if rauc info --keyring="${theirs}/anchor" --output-format=shell "$bundle" >/dev/null 2>&1; then
	t_fail "a bundle signed by someone else is refused" \
		"it verified against an unrelated trust anchor"
else
	t_pass "a bundle signed by someone else is refused"
fi

out=$("$make_bundle" \
	--cert "${mine}/anchor" --key "${mine}/signing" \
	--keyring "${theirs}/anchor" \
	--output "${work}/unverifiable.raucb" "$dir" 2>&1)
rc=$?
t_eq "packing against a trust anchor that will not verify it fails" \
	"$([ "$rc" -ne 0 ] && echo yes)" yes
t_eq "and says so" \
	"$(printf '%s\n' "$out" | grep -c 'does not verify against')" 1

t_done
