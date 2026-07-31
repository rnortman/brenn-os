#!/usr/bin/env bash
#
# The last hook against the root filesystem, exercised without a build.
#
# It stamps the build's version into os-release, which is what lets a device
# answer "which build am I running?" — and it does that by resolving a symlink
# on the build host and writing through it. Both of the ways that can go wrong
# are expensive and neither shows up in a green build: a version that resolved
# to nothing bakes an image that answers the question wrongly forever, and a
# symlink pointing out of the root filesystem writes into the build host's own
# os-release.
#
# A real build exercises the happy path once per image and neither refusal ever.
# So the refusals are exercised here, against a directory shaped like a root
# filesystem, in the lane that runs on every commit.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

hook="${BRENN_REPO_ROOT}/image/post-build.sh"
[ -x "$hook" ] || {
	t_fail "the post-build hook is present and executable" "not at ${hook}"
	t_done
}

# The hook's own dependency, and the only one: it copies /var with rsync.
t_require_cmd rsync

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The shape the builder hands it: a root filesystem with a populated /var and
# Debian's relative os-release symlink. Only what the hook reads is built —
# everything else in a real root filesystem is beside the point here.
distribution="PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"
ID=debian
VERSION_CODENAME=trixie"

new_rootfs() {
	local root="${work}/$1"
	rm -rf "$root"
	mkdir -p "${root}/var/lib/dbus" "${root}/var/log/journal" \
		"${root}/usr/lib" "${root}/etc"
	printf '%s\n' "$distribution" >"${root}/usr/lib/os-release"
	ln -s ../usr/lib/os-release "${root}/etc/os-release"
	printf '%s' "$root"
}

run_hook() {
	local root=$1 version=$2
	if [ "$version" = "<unset>" ]; then
		env -u IGconf_artefact_version "$hook" "$root" 2>&1
	else
		IGconf_artefact_version="$version" "$hook" "$root" 2>&1
	fi
}

stamped_lines() {
	grep -c '^IMAGE_VERSION=' "${1}/usr/lib/os-release"
}

stamped_value() {
	sed -n 's/^IMAGE_VERSION="\(.*\)"$/\1/p' "${1}/usr/lib/os-release"
}

# --- the version is stamped, once, through the link ------------------------

root=$(new_rootfs stamped)
rc=0
out=$(run_hook "$root" 2026.07.30-1) || rc=$?
t_ok "a build with a version stamps it" "$rc" "$out"
t_eq "the value is the version the builder passed" "$(stamped_value "$root")" 2026.07.30-1
t_eq "written to the file behind /etc/os-release" "$(stamped_lines "$root")" 1
t_eq "and /etc/os-release is still the symlink it was" \
	"$(readlink "${root}/etc/os-release")" ../usr/lib/os-release

# What the distribution put in the file has to survive an append that is only
# adding a field to it.
for field in ID VERSION_CODENAME PRETTY_NAME; do
	t_eq "stamping left ${field} in place" \
		"$(grep -c "^${field}=" "${root}/usr/lib/os-release")" 1
done

# A second build against the same root filesystem replaces the line rather than
# adding another: two versions in one file is two answers to a question that has
# one, and whichever a reader took would be a coin toss.
rc=0
out=$(run_hook "$root" 2026.07.30-2) || rc=$?
t_ok "a second run stamps again" "$rc" "$out"
t_eq "and leaves one version line" "$(stamped_lines "$root")" 1
t_eq "naming the version of the run that just happened" \
	"$(stamped_value "$root")" 2026.07.30-2

# The file is rewritten through its own inode rather than replaced, which is the
# only reason its mode and ownership survive the stamp. The obvious
# simplification to a rename changes both, in every image, silently.
root=$(new_rootfs preserved)
chmod 0640 "${root}/usr/lib/os-release"
before=$(stat -c '%i:%a' "${root}/usr/lib/os-release")
rc=0
out=$(run_hook "$root" 2026.07.30-5) || rc=$?
t_ok "stamping a file with a mode of its own succeeds" "$rc" "$out"
t_eq "and leaves the inode and the mode it had" \
	"$(stat -c '%i:%a' "${root}/usr/lib/os-release")" "$before"

# --- what the bake leaves behind -------------------------------------------

# The other half of this hook, which the assertions above run straight past: the
# copy of /var that becomes the read-only lower half of the overlay. Two repo
# invariants live in what it removes, and neither has anywhere else to fail —
# a real build exercises this once per image and never fails on it.
root=$(new_rootfs baked)
rc=0
out=$(run_hook "$root" 2026.07.30-6) || rc=$?
t_ok "baking a populated /var succeeds" "$rc" "$out"
t_eq "the copy is where the overlay's lower half is mounted from" \
	"$([ -d "${root}/usr/share/factory/var" ] && echo yes)" yes

# journald reads the existence of this directory as the instruction to store
# logs on flash. Baked in, a configuration change starts doing that with nothing
# in the tree saying so.
t_eq "no journal directory is baked, so nothing can start logging to flash" \
	"$([ -e "${root}/usr/share/factory/var/log/journal" ] && echo present || echo absent)" \
	absent

# machine-id is identity, not state: a baked one would ship the build host's
# unit identity to every device flashed from the image.
t_eq "the legacy machine-id path is a link rather than a baked identity" \
	"$(readlink "${root}/usr/share/factory/var/lib/dbus/machine-id")" /etc/machine-id

# A root filesystem with no /var is one whose overlay would come up empty, and
# every unit that expects a populated /var fails on the device with no obvious
# cause. The refusal is the only thing between that and a shipped image.
root=$(new_rootfs no-var)
rm -rf "${root:?}/var"
rc=0
out=$(run_hook "$root" 2026.07.30-7) || rc=$?
t_fails "a root filesystem with no /var is refused" "$rc" "$out"
t_has "and says which directory was missing" "$out" /var
t_eq "and nothing was baked" \
	"$([ -e "${root}/usr/share/factory/var" ] && echo present || echo none)" none

# --- the refusals ----------------------------------------------------------

# No version is a build that would produce an image claiming nothing about
# itself. Stopping costs a build; not stopping costs every device flashed from
# that image.
root=$(new_rootfs unversioned)
rc=0
out=$(run_hook "$root" '<unset>') || rc=$?
t_fails "a build that passed no version is refused" "$rc" "$out"
t_has "and says which variable was missing" "$out" IGconf_artefact_version
t_eq "nothing was stamped" "$(stamped_lines "$root")" 0

# os-release values are shell-quoted and everything that reads this field
# sources the file — including the device suite, over SSH, as root. A version
# carrying a quote or a substitution would break the file or smuggle shell into
# it, and the version is a tag name, which may contain both.
root=$(new_rootfs metacharacters)
rc=0
out=$(run_hook "$root" 'v1"; rm -rf /data; "') || rc=$?
t_fails "a version carrying shell syntax is refused" "$rc" "$out"
t_has "and names the characters a version may have" "$out" "A-Za-z0-9"
t_eq "nothing was stamped" "$(stamped_lines "$root")" 0

# What a git description is made of goes through untouched, tag and dirty marker
# and all — a refusal that stopped ordinary builds would be worse than the hole.
root=$(new_rootfs described)
rc=0
out=$(run_hook "$root" 'v0.2.1-4-g2f0a39b110a8-dirty') || rc=$?
t_ok "a git description stamps as it stands" "$rc" "$out"
t_eq "with the version the builder passed" \
	"$(stamped_value "$root")" v0.2.1-4-g2f0a39b110a8-dirty

# An absolute link resolves on the build host, not inside the root filesystem.
# The file it would have written to stands in for the host's own os-release, and
# the assertion is that it is not touched.
root=$(new_rootfs escaping)
outside="${work}/host-os-release"
printf '%s\n' "$distribution" >"$outside"
rm -f "${root}/etc/os-release"
ln -s "$outside" "${root}/etc/os-release"
rc=0
out=$(run_hook "$root" 2026.07.30-3) || rc=$?
t_fails "a link out of the root filesystem is refused" "$rc" "$out"
t_has "and names where it resolved to" "$out" "$outside"
t_eq "the file outside is untouched" "$(grep -c '^IMAGE_VERSION=' "$outside")" 0

# No os-release at all is a root filesystem the hook does not recognise, and
# creating one would invent a distribution.
root=$(new_rootfs no-os-release)
rm -f "${root}/etc/os-release"
rc=0
out=$(run_hook "$root" 2026.07.30-4) || rc=$?
t_fails "a root filesystem with no os-release is refused" "$rc" "$out"
t_has "and says so" "$out" /etc/os-release
t_eq "and none was created" "$([ -e "${root}/etc/os-release" ] && echo yes || echo no)" no

t_done
