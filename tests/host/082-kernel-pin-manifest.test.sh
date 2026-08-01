#!/usr/bin/env bash
#
# The kernel pin and the package manifests name the same kernel.
#
# The kernel version is written down in two tracked files: as a version in the
# apt pin, and inside package *names* in the manifests, because the Raspberry Pi
# archive spells a kernel's version into the name it publishes it under. Bump
# one and forget the other and the image is fine but the manifest is a lie, or
# the pin is — caught by the image suite, which costs a gigabyte-scale build and
# does not run in `make check`.
#
# Both files are in the tree, so the comparison is free and belongs here: a
# half-done bump dies at the commit hook.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/manifest.sh
. "${BRENN_TESTS_LIB}/manifest.sh"
# shellcheck source=tests/lib/pin.sh
. "${BRENN_TESTS_LIB}/pin.sh"

pinfile="${BRENN_REPO_ROOT}/image/layer/brenn/apt/preferences.rpi-pin"
[ -f "$pinfile" ] || {
	t_fail "the pin file is present" "nothing at ${pinfile}"
	t_done
}

# The kernel's stanza is the one whose patterns include linux-image-*; the
# quoted parts of the case pattern are literal, so the glob in the file is
# compared as text rather than matched.
kernel_pins=()
while IFS=$'\t' read -r pattern_set version; do
	case " ${pattern_set} " in
		*' linux-image-* '*) kernel_pins+=("$version") ;;
	esac
done < <(pin_stanzas "$pinfile")

# Without one there is nothing to hold the manifests to, and every assertion
# below would pass over an empty comparison.
if [ ${#kernel_pins[@]} -eq 0 ]; then
	t_fail "the pin file pins a kernel version" \
		"no stanza in ${pinfile} whose Package: patterns include linux-image-*"
	t_done
fi

# apt applies the first record that matches a package and ignores the rest, so a
# second stanza over the same patterns pins nothing while reading as though it
# does. Rather than pick one and hold the manifests to a version the build may
# not install, say that the file has two answers.
if [ ${#kernel_pins[@]} -gt 1 ]; then
	t_fail "one stanza pins the kernel" \
		"${#kernel_pins[@]} stanzas in ${pinfile} have patterns including linux-image-*;" \
		"apt honours the first and ignores the rest" \
		"versions pinned: ${kernel_pins[*]}"
	t_done
fi
pin_version=${kernel_pins[0]}

upstream=$(pin_upstream_version "$pin_version")

# The strip is by grammar, not by a slice of today's literal string, and today's
# tree holds exactly one version to read it on — so the grammar is driven over
# synthetic versions here. A regression to literal slicing would otherwise stay
# green until the archive first ships an epoch or a second revision, which is
# the deliberate bump this file exists to police.
while IFS='|' read -r version want; do
	t_eq "${version} reads as upstream ${want}" \
		"$(pin_upstream_version "$version")" "$want"
done <<-'TABLE'
	1:6.18.39-1+rpt1|6.18.39
	6.18.39-1+rpt1|6.18.39
	2:6.19.0-2+rpt3|6.19.0
	1:6.18.39|6.18.39
TABLE

shopt -s nullglob
manifests=("${BRENN_REPO_ROOT}"/tests/image/expected-*.packages)
shopt -u nullglob

if [ ${#manifests[@]} -eq 0 ]; then
	t_fail "there is a package manifest to hold the pin to" \
		"no tests/image/expected-*.packages"
	t_done
fi

# Every profile's manifest, by glob, so a profile added later is covered without
# an edit here.
for manifest in "${manifests[@]}"; do
	name=$(basename "$manifest")

	entries=$(manifest_entries "$manifest")

	# The versioned names only, across the four families the pin stanza covers.
	# Matching on a digit after the flavour-free prefix keeps this agnostic about
	# which kernel flavour a profile installs — a future rpi-2712 profile passes
	# unedited — while exempting linux-base, linux-image-rpi-v8 and
	# linux-base-rpi-v8, whose names carry no version to drift.
	images=0
	bases=0
	wrong=()
	malformed=()
	while IFS= read -r pkg; do
		[ -n "$pkg" ] || continue

		# A package name holds no space and no capital, so a line that fails the
		# grammar is a typo in a file the project treats as reviewed truth. It is
		# caught here, next to the manifests it applies to, rather than in the
		# image lane as an installed-versus-manifest diff that sends the reader
		# after the build instead of the line.
		if [[ ! $pkg =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
			malformed+=("$pkg")
		fi

		family=""
		case "$pkg" in
			linux-image-[0-9]*)
				images=$((images + 1))
				family=linux-image
				;;
			linux-base-[0-9]*)
				bases=$((bases + 1))
				family=linux-base
				;;
			# Headers and kbuild are pinned by the same stanza and no appliance
			# profile installs them today. Held to the pinned version if a
			# profile ever does, with no presence floor: absent is correct.
			linux-headers-[0-9]*) family=linux-headers ;;
			linux-kbuild-[0-9]*) family=linux-kbuild ;;
			*) continue ;;
		esac
		case "$pkg" in
			"${family}-${upstream}+rpt"*) ;;
			*) wrong+=("$pkg") ;;
		esac
	done <<<"$entries"

	if [ ${#malformed[@]} -eq 0 ]; then
		t_pass "${name} holds package names"
	else
		t_fail "${name} holds package names" \
			"not a Debian package name:" "${malformed[@]}"
	fi

	if [ ${#wrong[@]} -eq 0 ]; then
		t_pass "${name} names the pinned kernel ${upstream}"
	else
		t_fail "${name} names the pinned kernel ${upstream}" \
			"pinned: ${pin_version}, so the entries read ${upstream}+rpt" \
			"entries naming another kernel:" "${wrong[@]}"
	fi

	# A manifest with no versioned kernel entry at all satisfies the check above
	# while asserting nothing, and the kernel going missing from a manifest is
	# itself the kind of thing this file is here to notice.
	t_ge "${name} lists a versioned linux-image entry" "$images" 1
	t_ge "${name} lists a versioned linux-base entry" "$bases" 1
done

t_done
