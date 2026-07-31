#!/usr/bin/env bash
#
# The image says which build it is.
#
# Every other place the version exists is on the machine that built the image —
# the bundle's file name, the build's own image.json, the work directory. A
# device has none of them, so "is this unit running what the tree describes?"
# could only be answered by comparing content and guessing. The build stamps the
# version into os-release, and this is what holds it to the version the build
# recorded for itself.
#
# The comparison is against the build's description rather than against a
# version resolved here: an image on disk is as old as the last build, and a
# tree that has moved on since is not a defect in the image.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

# What the build says it stamped.
#
# A missing description is a failure and not a skip: the version is the one
# assertion here, and an image whose build left no record of its version is
# exactly the case this test exists to notice.
desc="$(dirname "$IMG")/image.json"
build_version=$(imgread_image_version "$desc") || build_version=
if [ -z "$build_version" ]; then
	t_fail "the build recorded the version it stamped" \
		"no IGconf_image_version in ${desc}"
	t_done
fi
t_pass "the build recorded the version it stamped (${build_version})"

# The link, before the file behind it. The build-time write resolves this link
# on the host, so a link pointing anywhere but inside the root filesystem would
# send that write to the build host — refused at build time, and pinned here so
# the shape the refusal depends on cannot drift unnoticed.
if link=$(img_ext4_link "$IMG_SPEC" /etc/os-release); then
	t_eq "/etc/os-release points into /usr/lib, relatively" \
		"$link" "$EXPECT_OS_RELEASE_LINK"
else
	t_fail "/etc/os-release points into /usr/lib, relatively" \
		"nothing at /etc/os-release in the root filesystem"
fi

content=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_OS_RELEASE_FILE") || content=
if [ -z "$content" ]; then
	t_fail "the image carries an os-release" "nothing at ${EXPECT_OS_RELEASE_FILE}"
	t_done
fi

# Exactly one, because the field is written by replacing any line already there:
# two would mean a second build wrote into a root filesystem that had been
# stamped once already, and only one of the two is this image's version.
stamped=$(printf '%s\n' "$content" | grep -c '^IMAGE_VERSION=')
t_eq "the version is stamped exactly once" "$stamped" 1

# The value, unquoted. os-release(5) values are shell-quoted, and a comparison
# against the raw line would pass for a version with the quotes baked into it.
version=$(printf '%s\n' "$content" | sed -n 's/^IMAGE_VERSION="\(.*\)"$/\1/p' | tail -n1)
t_eq "the stamped version is the one the build recorded" "$version" "$build_version"

# The stamp is an append to a file the distribution owns, so what was already
# in it has to survive: the fields every reader of os-release starts from.
for field in ID VERSION_CODENAME PRETTY_NAME; do
	if printf '%s\n' "$content" | grep -q "^${field}="; then
		t_pass "stamping left ${field} in place"
	else
		t_fail "stamping left ${field} in place" \
			"no ${field} in ${EXPECT_OS_RELEASE_FILE}"
	fi
done

t_done
