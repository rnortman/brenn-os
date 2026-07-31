#!/usr/bin/env bash
#
# Pack the last build's slot images into a signed RAUC update bundle.
#
#   scripts/make-bundle.sh [options] [<image-output-dir>]
#
# The bundle carries one boot partition image and one system partition image —
# the pair the firmware flips to together — so a single install replaces the
# kernel, the boot firmware and the root filesystem of the inactive slot at
# once.
#
# Signing material never lives in this tree. The certificate and private key
# come from the environment or the command line, which is how a release lane
# passes real keys and CI passes a throwaway pair it generated for that run.
#
# The positional argument is the directory the build wrote its images into. It
# defaults to the profile's output directory, and taking it as the first
# argument is also the shape an image post-build hook is called with. Run with
# --help for the options.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=scripts/lib/image-read.sh
. "${repo_root}/scripts/lib/image-read.sh"
# shellcheck source=scripts/lib/overlay-conf.sh
. "${repo_root}/scripts/lib/overlay-conf.sh"

# The compatible string identifies which devices may install a bundle. It is
# read out of the image's own update configuration rather than repeated here,
# so a bundle and the device it is meant for cannot come to disagree.
system_conf="${repo_root}/image/layer/brenn/rauc.rootfs-overlay/etc/rauc/system.conf"

# Where the build left its images. The default is the directory `make image`
# writes into; the override is for a build that ran somewhere else.
workroot=${BRENN_WORK_DIR:-${repo_root}/work}

profile=${BRENN_PROFILE:-}

# The signing knobs, resolved once, through the shared overlay precedence: an
# exported value outranks the local overlay, which outranks the default. A flag
# outranks them all, later, at parse time.
#
# The overlay carries *paths* — where this build host keeps its signing
# material — and never the material itself. A key under the repo root is a file
# that would need scrubbing back out, gitignored or not.
conf=${BRENN_BUNDLE_CONF:-${repo_root}/.local/bundle.conf}
overlay_load_conf "$conf" \
	BRENN_BUNDLE_CERT= \
	BRENN_BUNDLE_KEY= \
	BRENN_BUNDLE_KEYRING= \
	BRENN_BUNDLE_VERSION= \
	BRENN_BUNDLE_OUTPUT=

cert=$BRENN_BUNDLE_CERT
key=$BRENN_BUNDLE_KEY
keyring=$BRENN_BUNDLE_KEYRING
version=$BRENN_BUNDLE_VERSION
output=$BRENN_BUNDLE_OUTPUT
stage_only=no
indir=

die() {
	echo "make-bundle: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-EOF
	usage: $(basename "$0") [options] [<image-output-dir>]

	  --profile <name>   which profile's build output to pack (default: \$BRENN_PROFILE)
	  --cert <file>      signing certificate       (\$BRENN_BUNDLE_CERT)
	  --key <file>       signing private key       (\$BRENN_BUNDLE_KEY)
	  --keyring <file>   verify the result against this trust anchor
	                     (\$BRENN_BUNDLE_KEYRING; default: the signing cert)
	  --version <string> bundle version            (\$BRENN_BUNDLE_VERSION)
	  --output <file>    where to write the bundle (\$BRENN_BUNDLE_OUTPUT)
	  --stage-only       assemble the bundle inputs and stop, without signing

	The \$BRENN_BUNDLE_* knobs can also be written into ${conf}
	(gitignored, paths only — no key material under this tree). A non-empty
	exported value outranks that file; a flag outranks both. Exporting a knob
	empty reads as not setting it, so the way past a keyring the file names is
	--keyring, not an empty \$BRENN_BUNDLE_KEYRING.

	\$BRENN_WORK_DIR points at the directory the build wrote into, for a build
	that did not land in ${workroot}.

	Getting the result onto a device is docs/update.md.
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--profile)
			profile=${2:?--profile needs a value}
			shift 2
			;;
		--cert)
			cert=${2:?--cert needs a value}
			shift 2
			;;
		--key)
			key=${2:?--key needs a value}
			shift 2
			;;
		--keyring)
			keyring=${2:?--keyring needs a value}
			shift 2
			;;
		--version)
			version=${2:?--version needs a value}
			shift 2
			;;
		--output)
			output=${2:?--output needs a value}
			shift 2
			;;
		--stage-only)
			stage_only=yes
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			usage
			die "unknown option: $1"
			;;
		*)
			[ -z "$indir" ] || die "more than one output directory given"
			indir=$1
			shift
			;;
	esac
done

# Everything the signing path needs, settled before any work is done: staging a
# bundle copies gigabytes, and finding out afterwards that there is no key is
# the same failure half an hour later. Same rule the slot images get below.
#
# --stage-only assembles the inputs and stops, which needs neither rauc nor
# signing material, so none of this is required in that mode.
if [ "$stage_only" = no ]; then
	command -v rauc >/dev/null 2>&1 ||
		die "rauc is not installed — it is what packs and signs a bundle"

	[ -n "$cert" ] ||
		die "no signing certificate — pass --cert or set BRENN_BUNDLE_CERT (see docs/provisioning.md — the update-signing keypair)"
	[ -n "$key" ] ||
		die "no signing key — pass --key or set BRENN_BUNDLE_KEY (see docs/provisioning.md — the update-signing keypair)"
	[ -f "$cert" ] || die "no certificate at ${cert}"
	[ -f "$key" ] || die "no key at ${key}"

	# No anchor named means verify against the certificate that signed it,
	# said out loud: a transcript must never show verification against an
	# anchor the operator did not knowingly choose. In the bring-up
	# configuration the cert and the device's keyring are the same file, so
	# this is the answer that costs nothing and skips nothing.
	#
	# What it buys is a round trip, not an independent check: it catches a
	# packing failure, a corrupted result and a wrong compatible string, not a
	# bundle signed with a key the fleet does not trust. Lifting that limit is
	# TODO(rauc-ca-hierarchy) below.
	if [ -z "$keyring" ]; then
		keyring=$cert
		echo "make-bundle: BRENN_BUNDLE_KEYRING unset; verifying against the signing cert (single-pair bring-up)"
	fi
	[ -f "$keyring" ] || die "no keyring at ${keyring}"
fi

# The image name a profile builds under, out of its config. Read with the block
# structure honoured, so a `name:` belonging to some other section cannot be
# mistaken for this one.
profile_image_name() {
	local config="${repo_root}/image/config/${1}.yaml"
	[ -f "$config" ] || return 1
	awk '
		/^[^[:space:]#]/ { section = $1; next }
		section == "image:" && $1 == "name:" { print $2; exit }
	' "$config"
}

if [ -z "$indir" ]; then
	[ -n "$profile" ] || die "no output directory given and no profile set — pass one, or --profile <name>"
	name=$(profile_image_name "$profile") ||
		die "no such profile: ${profile}"
	[ -n "$name" ] ||
		die "profile '${profile}' declares no image name — pass the build output directory instead"
	indir="${workroot}/image-${name}"
fi

[ -d "$indir" ] ||
	die "no build output at ${indir} — run: make image${profile:+ PROFILE=$profile}"
indir=$(cd -- "$indir" && pwd)

# The images the update installs, by the names the layout's own image
# description gives them: one boot filesystem, one root filesystem. Both are
# written raw by the build; the sparse copies alongside them are for flashing a
# whole device, not for updating one slot.
declare -A slot_image=(
	[boot]=boot.vfat
	[rootfs]=system.ext4
)
declare -A slot_sparse=(
	[boot]=boot.sparse
	[rootfs]=system.sparse
)

# A raw slot image, converting one that is only present in sparse form. The
# conversion exists because an image layout is free to emit only the sparse
# copy; the tool for it is not a build dependency until that happens.
resolve_slot_image() {
	local class=$1 raw="${indir}/${slot_image[$1]}" sparse="${indir}/${slot_sparse[$1]}"
	if [ -f "$raw" ]; then
		printf '%s' "$raw"
		return
	fi
	[ -f "$sparse" ] ||
		die "the build wrote no ${class} image: neither ${raw} nor ${sparse}"
	command -v simg2img >/dev/null 2>&1 ||
		die "${class} is only present as a sparse image and simg2img (android-sdk-libsparse-utils) is not installed"
	simg2img "$sparse" "$raw" >&2 || die "converting ${sparse} to a raw image"
	printf '%s' "$raw"
}

# The version the build stamped on the image, out of the description it writes
# next to it. A bundle version that did not come from a build names nothing, so
# an unreadable one is an error rather than a default.
if [ -z "$version" ]; then
	version=$(imgread_image_version "${indir}/image.json") || true
	[ -n "$version" ] ||
		die "no version in ${indir}/image.json — pass --version"
fi

[ -f "$system_conf" ] || die "the update configuration is missing at ${system_conf}"
compatible=$(awk -F= '
	/^[[:space:]]*\[/ { section = $0; next }
	section ~ /^\[system\]/ && $1 == "compatible" { print $2; exit }
' "$system_conf")
[ -n "$compatible" ] ||
	die "no compatible string in ${system_conf}"

if [ -z "$output" ]; then
	output="${indir}/$(basename "$indir" | sed 's/^image-//')-${version}.raucb"
fi

# Resolved before anything is staged, so a build that is missing an image fails
# without leaving a half-assembled bundle behind.
declare -A resolved=()
for class in boot rootfs; do
	resolved[$class]=$(resolve_slot_image "$class")
done

# The bundle's contents are exactly what is in this directory, so it is built
# from scratch every time: a leftover from an earlier run would be packed and
# shipped. It sits beside the images it links so that linking works.
stage="${indir}/bundle-stage"
rm -rf "$stage"
mkdir -p "$stage"

for class in boot rootfs; do
	# Hard-linked rather than copied: a root filesystem image is gigabytes, and
	# the bundle is built from a snapshot of it that nothing writes to.
	cp -l "${resolved[$class]}" "${stage}/${slot_image[$class]}" 2>/dev/null ||
		cp --reflink=auto "${resolved[$class]}" "${stage}/${slot_image[$class]}"
done

# verity: the bundle carries a hash tree over its payload, so the installer can
# verify what it reads as it reads it rather than trusting a whole file it
# already wrote.
cat >"${stage}/manifest.raucm" <<-EOF
	[update]
	compatible=${compatible}
	version=${version}

	[bundle]
	format=verity

	[image.rootfs]
	filename=${slot_image[rootfs]}

	[image.boot]
	filename=${slot_image[boot]}
EOF

if [ "$stage_only" = yes ]; then
	echo "make-bundle: inputs staged at ${stage}"
	exit 0
fi

# TODO(rauc-ca-hierarchy): a single signing pair, verified against itself, is
# what a bring-up has. Graduating to a root certificate authority with
# intermediates is what makes a signing key replaceable and revocable.
#
# --signing-keyring makes the packer check its own output before it hands it
# back, which is why an anchor that will not verify the signature fails here
# rather than two steps later.
rm -f "$output"
rauc bundle --cert="$cert" --key="$key" --signing-keyring="$keyring" "$stage" "$output" ||
	die "packing the bundle — signing failed, or the signed result does not verify against ${keyring}"

rm -rf "$stage"

# Verification is part of producing a bundle, not a separate ceremony: a bundle
# that the device's own tool cannot verify is not a release, and finding that
# out here costs nothing. The pack step above checked itself; this is the same
# read the device makes, of the finished artifact, and it is the one the
# success line vouches for.
info=$(rauc info --keyring="$keyring" --output-format=shell "$output") ||
	die "the bundle does not verify against ${keyring}"
# Compared after the quoting is taken off, because whether a value comes
# back quoted differs between rauc versions and this check is about the
# value. A build host that spells it the other way would otherwise fail
# every bundle with a message about compatibility.
verified=$(printf '%s\n' "$info" |
	sed -n "s/^RAUC_MF_COMPATIBLE=//p" | head -n1 | sed "s/^'//; s/'\$//")
if [ "$verified" != "$compatible" ]; then
	die "the verified bundle is not compatible with '${compatible}'"
fi

# Two lines with a verb, because a bare path says nothing about whether it was
# checked, and stdout and stderr arrive interleaved in a terminal.
echo "make-bundle: verified against ${keyring}"
echo "make-bundle: wrote ${output}"
