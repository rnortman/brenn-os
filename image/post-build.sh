#!/bin/sh
#
# Bakes the finished /var into the root filesystem as /usr/share/factory/var.
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
