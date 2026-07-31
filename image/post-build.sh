#!/bin/sh
#
# The last hook that runs against the finished root filesystem: it bakes /var
# into it as /usr/share/factory/var, and stamps the build's version into
# os-release.
#
# At run time /var is an overlay whose read-only lower half is that copy and
# whose upper half is RAM (see the brenn-state layer). The copy has to be
# taken here, at the last hook that runs against the root filesystem, because
# the A/B image layout's own assembly step moves /var onto the persistent
# partition and leaves an empty skeleton behind — which would make the
# overlay's lower half empty, and every unit that expects a populated /var
# fail on a device with no obvious cause.
#
# Invoked by the builder with the root filesystem directory as the first
# argument.

set -eu

rootfs=${1:?usage: post-build.sh <rootfs>}
factory="${rootfs}/usr/share/factory/var"

[ -d "${rootfs}/var" ] || {
	echo "post-build: no /var under ${rootfs}" >&2
	exit 1
}

rm -rf "$factory"
mkdir -p "${rootfs}/usr/share/factory"
rsync -aHAXS --numeric-ids --delete "${rootfs}/var/" "${factory}/"

# The systemd package ships an empty /var/log/journal, and journald reads the
# existence of that directory as the instruction to store logs on disk. The
# journal here is volatile and uploaded, so the directory has no use and is a
# standing invitation for a configuration change to start writing logs to flash
# without anything saying so.
rm -rf "${factory}/log/journal"

# machine-id is identity, not state: the copy must not carry one, and the
# legacy path stays a symlink to the one place it is resolved from.
if [ -d "${factory}/lib/dbus" ]; then
	rm -f "${factory}/lib/dbus/machine-id"
	ln -s /etc/machine-id "${factory}/lib/dbus/machine-id"
fi

echo "post-build: baked $(du -sh "$factory" | cut -f1) of /var as the overlay lower layer"

# Which build this is, where a running system can report it. Everywhere else
# the version exists — the bundle's name, the build's own image.json, the work
# directory — is on the machine that built the image and not on the device, so
# "is this unit running what the tree describes?" had no answer over SSH.
# IMAGE_VERSION is os-release(5)'s own field for it.
#
# The value comes from the builder rather than from a guess here: it is the
# same string the chroot, the deploy directory and the bundle are named after,
# and an image stamped with an empty one answers the question wrongly, which is
# worse than a build that stops.
version=${IGconf_artefact_version:-}
[ -n "$version" ] || {
	echo "post-build: IGconf_artefact_version is unset, so the image would carry no version" >&2
	exit 1
}

# os-release(5) values are shell-quoted, and everything that reads this field
# sources the file — tools on the device, and the device suite over SSH as root.
# A version carrying a quote, a backslash or a substitution would break the file
# or smuggle shell into it, so the character set is held to what a version is
# made of. A wrong answer here is worse than a build that stops, the same way an
# empty one is.
case "$version" in
	*[!A-Za-z0-9._+~-]*)
		echo "post-build: IGconf_artefact_version '${version}' has characters os-release cannot carry (A-Za-z0-9 . _ + ~ - only)" >&2
		exit 1
		;;
esac

# /etc/os-release is a relative symlink into /usr/lib, so the write lands in
# the file behind it and inside this root filesystem. An absolute link would
# resolve to the build host's own os-release, so where it points is checked
# before anything is written rather than assumed.
osrel="${rootfs}/etc/os-release"
[ -e "$osrel" ] || {
	echo "post-build: no /etc/os-release under ${rootfs}" >&2
	exit 1
}
rootfs_real=$(readlink -f "$rootfs")
osrel_real=$(readlink -f "$osrel")
case "$osrel_real" in
	"${rootfs_real}"/*) ;;
	*)
		echo "post-build: /etc/os-release resolves to ${osrel_real}, outside ${rootfs_real}" >&2
		exit 1
		;;
esac

# By replacement rather than by appending, so that a second run against one
# root filesystem leaves a single version line instead of a stack of them. The
# content is written back through the same inode, which keeps the file's mode
# and ownership.
stamped="${osrel_real}.brenn-stamp"
{
	sed '/^IMAGE_VERSION=/d' "$osrel_real"
	printf 'IMAGE_VERSION="%s"\n' "$version"
} >"$stamped"
cat "$stamped" >"$osrel_real"
rm -f "$stamped"

echo "post-build: stamped IMAGE_VERSION=${version} into ${osrel_real#"$rootfs_real"}"
