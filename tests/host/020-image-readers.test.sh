#!/usr/bin/env bash
#
# The parsers every image assertion's verdict comes out of.
#
# The image suite does not compare files, it compares resolved values: what
# systemd makes of a drop-in, what sshd makes of an include, what dpkg's status
# database says is installed. The rules it replays are subtle and some of them
# are inverted with respect to each other — systemd takes the last assignment of
# a key within a file, sshd takes the first, and systemd merges repeated
# ordering keys rather than replacing them. An error in any of that produces a
# suite that is confidently wrong and still green, which is worse than a suite
# that is red.
#
# So the rules are asserted here, against strings, in the lane that runs on
# every commit. No image, no reader for one, nothing that needs a build.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

# --- systemd: last assignment within a file wins ---------------------------

unit="[Unit]
Description=  padded value
After=a.target b.target
After=c.target

[Service]
ExecStart=
ExecStart=/bin/true
Restart=on-failure	"

t_eq "the last assignment of a key is the effective one" \
	"$(img_ini_value "$unit" ExecStart)" /bin/true
t_eq "leading whitespace in a value is not part of it" \
	"$(img_ini_value "$unit" Description)" "padded value"
t_eq "nor is trailing whitespace" \
	"$(img_ini_value "$unit" Restart)" on-failure
t_eq "a key that is not there resolves to nothing" \
	"$(img_ini_value "$unit" ConditionPathExists)" ""

# Ordering keys accumulate instead of replacing, so a reader that took only the
# last one would report an ordering the unit does not have.
t_eq_text "every occurrence of a key is reported, in order" \
	"$(img_ini_values "$unit" After)" "a.target b.target
c.target"
t_eq_text "including the empty reset that precedes a replacement" \
	"$(img_ini_values "$unit" ExecStart)" "
/bin/true"

# --- ini sections: the same key, several answers ---------------------------

# RAUC's configuration names a device in each of four slot sections. A reader
# that ignored sections would report the last one for all of them, and the
# assertion that each slot points at the right partition would pass whatever
# the file said.
sectioned="[system]
compatible=brenn-os/cm4

[slot.rootfs.0]
device=/dev/disk/by-partlabel/system_a
bootname=A

[slot.rootfs.1]
device=/dev/disk/by-partlabel/system_b
bootname=B"

t_eq "a key is read from the section it is in" \
	"$(img_ini_section_value "$sectioned" slot.rootfs.0 device)" \
	/dev/disk/by-partlabel/system_a
t_eq "and not from a later section setting the same key" \
	"$(img_ini_section_value "$sectioned" slot.rootfs.1 device)" \
	/dev/disk/by-partlabel/system_b
t_eq "a key absent from the named section reads as nothing" \
	"$(img_ini_section_value "$sectioned" slot.rootfs.0 parent)" ""
t_eq "a section that is not there reads as nothing" \
	"$(img_ini_section_value "$sectioned" slot.boot.0 device)" ""

# --- sshd: first value obtained wins, keywords are case-insensitive --------

sshd="# a comment
PasswordAuthentication no
passwordauthentication yes
PermitRootLogin=prohibit-password
AuthenticationMethods publickey
Match Address 10.0.0.0/8
    PasswordAuthentication yes"

t_eq "the first value obtained for a keyword is the effective one" \
	"$(img_sshd_value "$sshd" PasswordAuthentication)" no
t_eq "a keyword is matched whatever its case" \
	"$(img_sshd_value "$sshd" passwordauthentication)" no
t_eq "the Keyword=value form sshd also accepts is read as a setting" \
	"$(img_sshd_value "$sshd" PermitRootLogin)" prohibit-password
t_eq "a keyword nobody set resolves to nothing" \
	"$(img_sshd_value "$sshd" X11Forwarding)" ""

# A Match block is not a setting and is not resolvable as one; it is reported so
# a test can refuse the whole configuration.
t_eq "a Match block is visible as a keyword" \
	"$(img_sshd_keywords "$sshd" | grep -cx match)" 1
t_eq "a comment sets nothing" \
	"$(img_sshd_keywords "$sshd" | head -n1)" ""

# --- sfdisk: the dump both the suite and the manifest are read from --------

# The image suite locates a filesystem through this, and the cross-lane
# comparison records it; they share one decode so that they cannot resolve the
# same partition to different offsets.
dump='label: gpt
label-id: 11111111-2222-3333-4444-555555555555
device: /work/brenn-os-reachy.img
unit: sectors
first-lba: 2048
last-lba: 31266782
sector-size: 512

/work/brenn-os-reachy.img1 : start=        8192, size=      131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAA1111-0000-0000-0000-000000000001, name="config", attrs="LegacyBIOSBootable"
/work/brenn-os-reachy.img2 : start=     7620608, size=    15728640, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAA1111-0000-0000-0000-000000000002, name="persistent"'

table=$(imgread_table "$dump")

t_eq_text "the table is normalised to its geometry and one line per partition" \
	"$table" 'table label=gpt sector-size=512 first-lba=2048 last-lba=31266782
partition 1 name=config start=8192 size=131072 type=0FC63DAF-8483-4772-8E79-3D69D8477DE4 attrs=LegacyBIOSBootable
partition 2 name=persistent start=7620608 size=15728640 type=0FC63DAF-8483-4772-8E79-3D69D8477DE4 attrs='

# Which partition the firmware may boot is exactly the kind of difference the
# cross-lane comparison exists to see, and it lives in the attribute bits rather
# than in anything the build wrote down. Several of them are space-separated in
# the dump, which the normalised form cannot carry, so they arrive comma-joined.
multi=${dump/attrs=\"LegacyBIOSBootable\"/attrs=\"RequiredPartition LegacyBIOSBootable\"}
t_eq "several attributes on one partition stay one field" \
	"$(imgread_field "$(imgread_table "$multi" | sed -n '2p')" attrs)" \
	RequiredPartition,LegacyBIOSBootable

# uuidgen writes a new one of each per build, so a comparison that carried them
# would be red every time and stop being read.
t_eq "the table's generated id is not carried" \
	"$(printf '%s\n' "$table" | grep -c 11111111-2222)" 0
t_eq "nor is a partition uuid" \
	"$(printf '%s\n' "$table" | grep -c AAAA1111)" 0

# The dump pads its numbers and quotes its names; a reader that kept either
# would compare a value to a differently-spelled copy of itself.
last=$(printf '%s\n' "$table" | tail -n1)
t_eq "a padded numeric field is read without its padding" \
	"$(imgread_field "$last" start)" 7620608
t_eq "a quoted name is read without its quotes" \
	"$(imgread_field "$last" name)" persistent
t_eq "a field that is not on the line reads as nothing" \
	"$(imgread_field "$last" uuid)" ""
t_eq "a field that is on it but empty reads as empty too" \
	"$(imgread_field "$last" attrs)" ""
t_eq "and one field cannot be read as the tail of another" \
	"$(imgread_field 'table label=gpt sector-size=512 first-lba=2048 last-lba=99' size)" ""

t_eq "a partition's offset is its start in bytes, at the table's own sector size" \
	"$(imgread_part_offset_bytes "$table" persistent)" $((7620608 * 512))
t_eq "a partition that is not in the table has no offset" \
	"$(imgread_part_offset_bytes "$table" system_a)" ""

# A name with a space would truncate in the normalised form, and a truncated
# name is a filesystem read at the wrong offset.
t_eq "a partition name the form cannot represent is refused, not truncated" \
	"$(imgread_table "${dump/name=\"persistent\"/name=\"two words\"}" 2>/dev/null; echo $?)" 1

# A comma inside a quoted value truncates it in the same way and for the same
# reason — the dump is split on commas — and the truncated remainder carries no
# `=`, so nothing further would notice.
t_eq "nor one containing the separator the dump is split on" \
	"$(imgread_table "${dump/name=\"persistent\"/name=\"two,parts\"}" 2>/dev/null; echo $?)" 1

# sfdisk's dumps state a sector size, and its own default when one does not is
# 512. The two callers resolve offsets from this one answer rather than each
# supplying a default, so a dump that omits it cannot send them to different
# places in the same image.
nosector=$(printf '%s\n' "$dump" | grep -v '^sector-size:')
t_eq "a dump that states no sector size is read as a 512-byte one" \
	"$(imgread_field "$(imgread_table "$nosector" | head -n1)" sector-size)" 512
t_eq "and an offset still resolves, at that size" \
	"$(imgread_part_offset_bytes "$(imgread_table "$nosector")" persistent)" $((7620608 * 512))

# --- dpkg: what the status database says is installed ----------------------

# Four stanzas: installed, removed-but-configured, unpacked-without-version, and
# a last one with no trailing blank line — the shape the end of a real database
# has, and the one an awk state machine forgets.
status="Package: openssh-server
Status: install ok installed
Version: 1:10.0p1-7

Package: wireless-regulatory
Status: deinstall ok config-files
Version: 1.2

Package: half-installed-thing
Status: install ok unpacked

Package: systemd-journal-remote
Status: install ok installed
Version: 258.2-1"

t_eq_text "only fully installed packages with a version are reported" \
	"$(imgread_dpkg_installed "$status")" "openssh-server 1:10.0p1-7
systemd-journal-remote 258.2-1"

# The other question the same database answers: not what is installed, but what
# the database records, which is how a removal that was refused stays visible.
t_eq_text "every stanza's recorded status is reported, whatever it says" \
	"$(imgread_dpkg_statuses "$status")" "openssh-server install ok installed
wireless-regulatory deinstall ok config-files
half-installed-thing install ok unpacked
systemd-journal-remote install ok installed"

t_done
