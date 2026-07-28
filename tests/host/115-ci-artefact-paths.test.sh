#!/usr/bin/env bash
#
# The paths the image lane reads its artefacts from, against the paths a build
# writes them to.
#
# Two of the native lane's steps reach into the build's output by glob: the
# bundle round trip and the SBOM upload. Neither can spell the paths out,
# because the directory names carry a version component the build is given as an
# input — BRENN_IMAGE_VERSION, resolved by the wrapper on the host, and
# constrained to a charset rather than to a shape, so a tag, a commit
# description, or whatever else a caller names. A glob that matches nothing is
# invisible until the build in front of it succeeds for the first time, which on
# a lane this slow can be months.
#
# Where a build puts those files is not this repo's choice; it is the builder's,
# declared in the layer metadata of the pinned submodule, which is in the tree
# whether or not anything has been built. So the expectation is derived from
# that metadata, a work/ tree of empty files is laid out the way it says a build
# leaves one, and the workflow's own globs are expanded against it.
#
# What this establishes: that each glob matches the file the builder's metadata
# names, and matches only that one. What it does not: that the metadata is what
# the builder resolves at run time — the substitution below is a reading of the
# declarations, not the builder's own resolver — nor anything about the
# artefacts' contents.
#
# This is its own file because every assertion in it needs the builder checked
# out, and a missing submodule skips the whole script. The lane and manifest
# chain in 110 reads only the workflow, and stays a hard red on any clone.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

workflow="${BRENN_REPO_ROOT}/.github/workflows/ci.yml"
[ -f "$workflow" ] || {
	t_fail "the workflow is present" "not at ${workflow}"
	t_done
}

# The native lane's body: from its key at two-space indent to the next key at
# that indent. Both globs are that job's, and an assertion made against the
# whole file would be satisfied by the right line in the wrong job.
native=$(awk '
	$0 == "  image:" { injob = 1; next }
	injob && /^  [^ ]/ { exit }
	injob { print }
' "$workflow")

if [ -z "$native" ]; then
	t_fail "the workflow defines the image job" "no such job in ${workflow}"
	t_done
fi

artefact_meta="${BRENN_REPO_ROOT}/rpi-image-gen/layer/base/artefact-base.yaml"
target_meta="${BRENN_REPO_ROOT}/rpi-image-gen/layer/base/target-config.yaml"
sbom_meta="${BRENN_REPO_ROOT}/rpi-image-gen/layer/sbom/sbom.yaml"

for meta in "$artefact_meta" "$target_meta" "$sbom_meta"; do
	t_builder_file "$meta" \
		"the builder declares where a build writes its artefacts" \
		"a bump that moved $(basename "$meta") moved the paths CI reads"
done

# One `X-Env-Var-<name>:` declaration out of a layer's metadata block. Values
# are templates referring to other variables; they are taken unexpanded.
builder_var() {
	sed -n "s/^# X-Env-Var-${2}: //p" "$1" | head -n1
}

declare -A igvar=(
	[IGconf_artefact_target_name]="$(builder_var "$artefact_meta" target_name)"
	[IGconf_artefact_context]="$(builder_var "$artefact_meta" context)"
	[IGconf_target_context]="$(builder_var "$target_meta" context)"
	[IGconf_target_dir]="$(builder_var "$target_meta" dir)"
	[IGconf_sbom_version]="$(builder_var "$sbom_meta" version)"
	[IGconf_sbom_name]="$(builder_var "$sbom_meta" name)"
	[IGconf_sbom_filename]="$(builder_var "$sbom_meta" filename)"
)

# The build's scratch root is this repo's choice, passed to the builder as -B,
# so it is read from the script that passes it rather than from the builder's
# default. Relative, because the workflow's paths are relative to the checkout.
workroot=$(sed -n 's|^workdir=.*/\([^/"]*\)"$|\1|p' \
	"${BRENN_REPO_ROOT}/scripts/build-image.sh" | head -n1)
t_eq "the build's output root is readable from the script that sets it" \
	"$([ -n "$workroot" ] && echo yes)" yes

image_name=$(awk '
	/^[^[:space:]#]/ { section = $1; next }
	section == "image:" && $1 == "name:" { print $2; exit }
' "${BRENN_REPO_ROOT}/image/config/${BRENN_PROFILE}.yaml")
t_eq "the profile names the image its output directory is named for" \
	"$([ -n "$image_name" ] && echo yes)" yes

if [ -z "$workroot" ] || [ -z "$image_name" ]; then
	t_done
fi

# Substitute until nothing is left to substitute. A name with no declaration is
# a metadata chain this test no longer understands, which is a failure and not a
# path to guess at.
expand() {
	local s=$1 name needle i open="\${"
	for ((i = 0; i < 16; i++)); do
		case "$s" in
			*"$open"*) ;;
			*)
				printf '%s' "$s"
				return 0
				;;
		esac
		name=${s#*"$open"}
		name=${name%%\}*}
		[ -n "${igvar[$name]+set}" ] || return 1
		needle="${open}${name}}"
		s=${s//"$needle"/${igvar[$name]}}
	done
	return 1
}

# Where a build with this version stamp writes its SBOM, relative to the
# checkout: the build context directory, and the filename the SBOM layer gives
# it.
sbom_relpath() {
	igvar[IGconf_sys_workroot]=$workroot
	igvar[IGconf_artefact_version]=$1
	expand "${igvar[IGconf_target_dir]}/${igvar[IGconf_sbom_filename]}"
}

# A work/ tree of empty files, shaped the way a finished build leaves one. The
# neighbours are the point as much as the artefacts: the deploy directory holds
# a compressed copy of the same SBOM, and a glob that reaches it would upload
# the wrong file under the right name.
lane_tree() {
	local root=$1 version=$2 sbom=$3 imagedir="$1/${workroot}/image-${image_name}"
	mkdir -p "${root}/$(dirname "$sbom")" "$imagedir" \
		"${root}/${workroot}/deploy-${version}" \
		"${root}/${workroot}/cache" "${root}/${workroot}/scratch"
	: >"${root}/${sbom}"
	: >"${root}/${workroot}/deploy-${version}/$(basename "$sbom").zst"
	: >"${imagedir}/${image_name}.img"
	: >"${imagedir}/${image_name}.img.sparse"
	: >"${imagedir}/image.json"
	: >"${imagedir}/${image_name}-${version}.raucb"
}

sbom_step=$(printf '%s\n' "$native" | awk '
	$0 == "      - name: Upload the SBOM" { instep = 1; next }
	instep && /^      - / { exit }
	instep { print }
')
sbom_glob=$(printf '%s\n' "$sbom_step" | sed -n 's/^          path: //p' | head -n1)
bundle_glob=$(printf '%s\n' "$native" |
	sed -n 's/^.*rauc info .* \(work[^ ]*\)$/\1/p' | head -n1)

t_eq "the lane uploads the SBOM from a path" \
	"$([ -n "$sbom_glob" ] && echo yes)" yes
t_eq "and verifies the bundle it just packed from one" \
	"$([ -n "$bundle_glob" ] && echo yes)" yes

# An artefact that went missing has to be a red job. Without this the upload
# succeeds with nothing in it, which is how a glob that matches nothing survives
# a green run.
t_eq "an SBOM the upload cannot find fails the job" \
	"$(printf '%s\n' "$sbom_step" | grep -c '^          if-no-files-found: error$')" 1

# Two dissimilar version strings, because the globs have to hold for any of
# them: the wrapper resolves a description of the checkout, and a caller may
# name anything the charset admits instead. A path that assumes one shape is a
# lane that works on one build.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for version in v0.3.1-4-gdeadbee 1970-01-01; do
	tree="${tmp}/${version}"
	sbom=$(sbom_relpath "$version")
	if [ -z "$sbom" ]; then
		t_fail "the builder's metadata says where the SBOM lands" \
			"a variable in the chain to ${target_meta} has no declaration"
		break
	fi
	lane_tree "$tree" "$version" "$sbom"

	matched=$(cd -- "$tree" && compgen -G "$sbom_glob")
	t_eq "the SBOM upload finds the one the build wrote (version ${version})" \
		"$matched" "$sbom"

	matched=$(cd -- "$tree" && compgen -G "$bundle_glob")
	t_eq "the bundle check finds the one the build packed (version ${version})" \
		"$matched" "${workroot}/image-${image_name}/${image_name}-${version}.raucb"
done

t_done
