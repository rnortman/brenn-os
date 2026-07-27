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

# --- sfdisk: one field out of a dump line ----------------------------------

line='start=     7620608, size=    15728640, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=7E7C-1A2B, name="persistent"'

t_eq "a padded numeric field is read without its padding" \
	"$(img_field "$line" start)" 7620608
t_eq "a quoted field is read without its quotes" \
	"$(img_field "$line" name)" persistent
t_eq "a field that is not on the line reads as nothing" \
	"$(img_field "$line" attrs)" ""

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
	"$(img_dpkg_installed "$status")" "openssh-server 1:10.0p1-7
systemd-journal-remote 258.2-1"

t_done
