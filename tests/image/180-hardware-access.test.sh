#!/usr/bin/env bash
#
# How the application reaches the carrier's hardware.
#
# The payload runs as an unprivileged account that arrives over the network, so
# every device it may touch is a deliberate grant. The grants are group
# memberships: the account set is baked and its ids are pinned, and a rule that
# names a group the account is in says what it may reach without saying that
# anything else may.
#
# What this defends against is the vendor image's answer — MODE="0666" on the
# USB audio devices, which is every account on the device. The rules are read
# whole, and every file in the directory is swept for a mode that grants more
# than a group, so a rule added later cannot quietly restore it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

dir=$EXPECT_UDEV_RULES_DIR

# The whole directory, not only the file we ship: a rule file is a grant, and
# an unexpected one is the finding this test exists for.
if listing=$(img_ext4_ls "$IMG_SPEC" "$dir" | sort); then
	t_eq_text "the image ships exactly the device rules this profile declares" \
		"$listing" \
		"$(printf '%s\n' "$EXPECT_UDEV_RULES_FILES" | sort)"
else
	t_fail "the image ships exactly the device rules this profile declares" \
		"no ${dir} in the image"
	t_done
fi

# Every rule file in the directory, concatenated with its comments dropped, is
# what udev acts on. Read from the listing rather than from the expectations,
# so that the sweep below covers a file that arrived from somewhere else — the
# assertion above is what says there should not be one, and this is what says
# what it would have granted.
rules=""
while IFS= read -r file; do
	[ -n "$file" ] || continue
	t_eq "${file} is readable by udev and writable by nobody" \
		"$(img_ext4_mode "$IMG_SPEC" "${dir}/${file}")" "$EXPECT_UDEV_RULES_MODE"
	content=$(img_ext4_cat "$IMG_SPEC" "${dir}/${file}") || content=""
	rules+=$(printf '%s\n' "$content" | sed -e 's/#.*//' -e '/^[[:space:]]*$/d')
	rules+=$'\n'
done <<<"$listing"

# Each USB audio device: one rule, granting the group and nothing wider. The
# ids are the hardware's own and are the only way a rule can name these
# devices — a rule matching on anything else would match on how they happen to
# be plugged in.
while IFS= read -r id; do
	[ -n "$id" ] || continue
	vendor=${id%%:*}
	product=${id##*:}
	line=$(printf '%s\n' "$rules" |
		grep -F "ATTR{idVendor}==\"${vendor}\"" |
		grep -F "ATTR{idProduct}==\"${product}\"")
	if [ -z "$line" ]; then
		t_fail "USB device ${id} has an access rule" "no rule matches both ids"
		continue
	fi
	if [ "$(printf '%s\n' "$line" | wc -l)" -ne 1 ]; then
		t_fail "USB device ${id} has one access rule" \
			"$(printf '%s\n' "$line" | sed 's/^/rule: /')"
		continue
	fi

	t_eq "USB device ${id} is matched on the USB subsystem" \
		"$(printf '%s\n' "$line" | grep -o 'SUBSYSTEM=="[^"]*"')" \
		'SUBSYSTEM=="usb"'
	t_eq "USB device ${id} is readable and writable by its group only" \
		"$(printf '%s\n' "$line" | grep -o 'MODE="[^"]*"')" \
		"MODE=\"${EXPECT_USB_AUDIO_MODE}\""
	t_eq "USB device ${id} belongs to the group the application account is in" \
		"$(printf '%s\n' "$line" | grep -o 'GROUP="[^"]*"')" \
		"GROUP=\"${EXPECT_USB_AUDIO_GROUP}\""
done <<<"$EXPECT_USB_AUDIO_IDS"

# The grant only means anything if the account is in the group, and the two are
# declared in different layers — the account set in the base, the rules in the
# profile. A profile naming a group nobody is in grants nothing.
t_contains "the application account is a member of that group" \
	"$(printf '%s\n' "$EXPECT_APP_GROUPS" | tr ' ' '\n')" \
	"$EXPECT_USB_AUDIO_GROUP"

# Access by group, and by group alone. An OWNER= assignment would hand a device
# to one account by name, which is a second mechanism saying the same thing and
# a second place for it to drift from the baked account set.
mapfile -t owned < <(printf '%s\n' "$rules" | grep 'OWNER=')
if [ "${#owned[@]}" -gt 0 ]; then
	t_fail "no rule assigns a device to an account by name" "${owned[@]}"
else
	t_pass "no rule assigns a device to an account by name"
fi

# The vendor's answer, and everything shaped like it. Access wider than the
# group is the thing this whole file exists to keep out of the image, and it is
# read out of the mode rather than looked up in a list of spellings: udev takes
# MODE="0666", MODE:="666" and MODE="0602" as the same kind of grant, and a
# denylist sees only the ones somebody thought to write down. What is examined
# is the last octal digit of every mode any rule assigns — the bits everyone on
# the device gets — and the assertion is that it grants nothing at all.
mapfile -t wide < <(printf '%s\n' "$rules" | awk '
	{
		rest = $0
		while (match(rest, /MODE[[:space:]]*[:+]?=[[:space:]]*"?[0-7]+"?/)) {
			mode = substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
			# Everything that is not an octal digit is syntax: the key, the
			# assignment and the quotes, whichever of them this rule used.
			# What is left is the mode as udev reads it — an octal number of
			# whatever length the author wrote, so MODE="66" is 066 and its
			# last digit is the others digit exactly as in MODE="0066".
			gsub(/[^0-7]/, "", mode)
			if (substr(mode, length(mode)) != "0") {
				print
				next
			}
		}
	}
')
if [ "${#wide[@]}" -gt 0 ]; then
	t_fail "no rule grants a device to accounts outside its group" "${wide[@]}"
else
	t_pass "no rule grants a device to accounts outside its group"
fi

t_done
