#!/usr/bin/env bash
#
# What goes into an update bundle, assembled off the build.
#
# A bundle is the whole update: get its contents wrong and the device installs
# something that does not boot, which costs a trial boot to discover and a
# rollback to survive. The half of that decided by our own tooling — which
# images are packed, what the manifest claims about them, which devices may
# install it, and which version it says it is — is decided here, against a
# directory shaped like a build's output rather than against a real one.
#
# The signing half is 075; this test is what still runs where rauc is not
# installed.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

make_bundle="${BRENN_REPO_ROOT}/scripts/make-bundle.sh"
[ -x "$make_bundle" ] || {
	t_fail "the bundle tool is present and executable" "not at ${make_bundle}"
	t_done
}

# The compatible string the built image is held to. Reading it here is what
# closes the loop: the image suite ties the device's configuration to this
# value, and this ties the bundle to the same one, so a device and the bundles
# meant for it cannot drift apart silently.
expectations="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env"
[ -f "$expectations" ] || t_skip "no expectations for profile '${BRENN_PROFILE}'"
# shellcheck disable=SC1090  # path is profile-dependent by design
. "$expectations"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

err=""
rc=0

# A directory shaped like the one the build writes: the two raw slot images,
# the sparse copies that are for flashing a whole device rather than updating
# one slot, and the description the build stamps the version into.
new_output_dir() {
	local dir="${work}/$1"
	mkdir -p "$dir"
	printf 'boot filesystem %s' "$1" >"${dir}/boot.vfat"
	printf 'root filesystem %s' "$1" >"${dir}/system.ext4"
	printf 'sparse boot' >"${dir}/boot.sparse"
	printf 'sparse system' >"${dir}/system.sparse"
	cat >"${dir}/image.json" <<-EOF
		{
		    "IGversion": "2.2.0",
		    "IGmeta": {
		        "IGconf_device_class": "cm4",
		        "IGconf_image_version": "$2",
		        "IGconf_image_outputdir": "${dir}"
		    }
		}
	EOF
	printf '%s' "$dir"
}

# What the tool says is asserted through its refusals, so its complaint is kept
# and its ordinary output is not.
#
# The knobs are cleared and the local overlay is pointed at a path that does not
# exist, so a build host with signing material configured — which is every host
# that has ever cut a release — asserts the same thing a bare clone does.
run_bundle() {
	env -u BRENN_BUNDLE_CERT -u BRENN_BUNDLE_KEY -u BRENN_BUNDLE_KEYRING \
		-u BRENN_BUNDLE_VERSION -u BRENN_BUNDLE_OUTPUT \
		BRENN_BUNDLE_CONF="${work}/no-such.conf" \
		"$make_bundle" "$@" >/dev/null 2>"${work}/err"
	rc=$?
	err=$(cat "${work}/err")
	return 0
}

dir=$(new_output_dir good 2026.07.26-1)
run_bundle --stage-only "$dir"
t_eq "staging a build's output succeeds" "$rc" 0

stage="${dir}/bundle-stage"
t_eq "the inputs are staged beside the images" "$([ -d "$stage" ] && echo yes)" yes

expected_manifest=$(
	cat <<-EOF
		[update]
		compatible=${EXPECT_RAUC_COMPATIBLE}
		version=2026.07.26-1

		[bundle]
		format=verity

		[image.rootfs]
		filename=system.ext4

		[image.boot]
		filename=boot.vfat
	EOF
)
t_eq_text "the manifest names both slot images, the format and the version" \
	"$(cat "${stage}/manifest.raucm")" "$expected_manifest"

t_eq "the root filesystem image is staged verbatim" \
	"$(cat "${stage}/system.ext4")" "root filesystem good"
t_eq "the boot filesystem image is staged verbatim" \
	"$(cat "${stage}/boot.vfat")" "boot filesystem good"

# Gigabytes are not copied to be packed. Losing the link is not a wrong bundle,
# but it is a build that needs twice the disk and the time to write it.
t_eq "the images are linked rather than copied" \
	"$(stat -c %i "${stage}/system.ext4")" "$(stat -c %i "${dir}/system.ext4")"

t_eq "nothing else is packed" \
	"$(find "$stage" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ')" \
	"boot.vfat manifest.raucm system.ext4 "

dir=$(new_output_dir override 2026.07.26-2)
run_bundle --stage-only --version 9.9.9-local "$dir"
t_eq "an explicit version is taken" \
	"$(sed -n 's/^version=//p' "${dir}/bundle-stage/manifest.raucm")" 9.9.9-local

dir=$(new_output_dir unversioned 2026.07.26-3)
rm -f "${dir}/image.json"
run_bundle --stage-only "$dir"
t_eq "a build that stamped no version is refused" "$([ "$rc" -ne 0 ] && echo yes)" yes
t_eq "and says what is missing" \
	"$(printf '%s' "$err" | grep -c 'no version in')" 1
t_eq "and stages nothing" "$([ -e "${dir}/bundle-stage" ] || echo none)" none

dir=$(new_output_dir noimages 2026.07.26-4)
rm -f "${dir}/system.ext4" "${dir}/system.sparse"
run_bundle --stage-only "$dir"
t_eq "a build with no root filesystem image is refused" "$([ "$rc" -ne 0 ] && echo yes)" yes
t_eq "and names the class that is missing" \
	"$(printf '%s' "$err" | grep -c 'no rootfs image')" 1
t_eq "and stages nothing" "$([ -e "${dir}/bundle-stage" ] || echo none)" none

run_bundle --stage-only "${work}/never-built"
t_eq "a directory that does not exist is refused" "$([ "$rc" -ne 0 ] && echo yes)" yes

run_bundle --stage-only --profile no-such-profile
t_eq "a profile that does not exist is refused" "$([ "$rc" -ne 0 ] && echo yes)" yes

# The profile is what turns `make bundle` into a path. Asserted against a build
# root of our own, so the mapping from a profile name to the directory that
# profile's build wrote is exercised rather than assumed.
build_root="${work}/elsewhere"
mkdir -p "$build_root"
dir=$(new_output_dir "elsewhere/image-${EXPECT_IMAGE_NAME}" 2026.07.26-6)
export BRENN_WORK_DIR="$build_root"
run_bundle --stage-only --profile "$BRENN_PROFILE"
unset BRENN_WORK_DIR
t_eq "a profile resolves to its own build output directory" "$rc" 0
t_eq "and the inputs are staged there" \
	"$([ -f "${dir}/bundle-stage/manifest.raucm" ] && echo yes)" yes

# A build that wrote only the sparse copy. The layout is free to do that, and
# then the raw image the bundle needs has to be made — packing a sparse file as
# if it were a filesystem gives a bundle that signs and verifies and installs a
# slot that will not boot, which costs a trial boot and a rollback to find out.
stub_bin="${work}/bin"
mkdir -p "$stub_bin"
cat >"${stub_bin}/simg2img" <<-EOF
	#!/bin/sh
	printf '%s\n' "\$*" >"${work}/simg2img-args"
	printf 'root filesystem converted' >"\$2"
EOF
chmod 0755 "${stub_bin}/simg2img"

dir=$(new_output_dir sparseonly 2026.07.26-7)
rm -f "${dir}/system.ext4"
saved_path=$PATH
PATH="${stub_bin}:${PATH}"
run_bundle --stage-only "$dir"
PATH=$saved_path
t_eq "a build that wrote only a sparse root filesystem is converted, not refused" "$rc" 0
t_eq "and the conversion is asked for sparse first, raw second" \
	"$(cat "${work}/simg2img-args" 2>/dev/null)" \
	"${dir}/system.sparse ${dir}/system.ext4"
t_eq "and what is staged is the converted image" \
	"$(cat "${dir}/bundle-stage/system.ext4" 2>/dev/null)" "root filesystem converted"

if command -v simg2img >/dev/null 2>&1; then
	echo "SKIP  simg2img is installed here, so its absence cannot be shown"
else
	dir=$(new_output_dir noconverter 2026.07.26-8)
	rm -f "${dir}/system.ext4"
	run_bundle --stage-only "$dir"
	t_eq "the same build with no converter installed is refused" \
		"$([ "$rc" -ne 0 ] && echo yes)" yes
	t_eq "and names the tool it needs" \
		"$(printf '%s' "$err" | grep -c 'simg2img')" 1
fi

dir=$(new_output_dir stale 2026.07.26-5)
mkdir -p "${dir}/bundle-stage"
printf 'left over from a previous run' >"${dir}/bundle-stage/leftover.ext4"
run_bundle --stage-only "$dir"
t_eq "staging over an earlier attempt succeeds" "$rc" 0
t_eq "and the earlier attempt's contents are gone" \
	"$([ -e "${dir}/bundle-stage/leftover.ext4" ] || echo gone)" gone

t_done
