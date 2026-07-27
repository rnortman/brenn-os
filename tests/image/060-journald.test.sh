#!/usr/bin/env bash
#
# The journal must be volatile.
#
# Asserted as the *effective* setting rather than as the presence of our own
# drop-in, because the A/B image layout ships a drop-in selecting persistent
# storage and systemd resolves drop-ins in filename order across directories.
# Ours wins by being named to sort last, which is true until an upstream bump
# renames theirs. Reading the merge the way systemd reads it is the only
# assertion that survives that.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

main=/etc/systemd/journald.conf
# Later directories win over earlier ones for a drop-in of the same name.
dropin_dirs=(/usr/lib/systemd/journald.conf.d /etc/systemd/journald.conf.d)

# Collect drop-ins as "<name>:<full path>", so that sorting by name gives
# systemd's merge order and a later directory can displace an earlier file.
declare -A dropin_path=()
found_ours=no
for dir in "${dropin_dirs[@]}"; do
	entries=$(img_ext4_ls "$IMG_SPEC" "$dir") || continue
	while IFS= read -r name; do
		case "$name" in
			*.conf) ;;
			*) continue ;;
		esac
		dropin_path["$name"]="${dir}/${name}"
		[ "$name" = zz-brenn-volatile.conf ] && found_ours=yes
	done <<<"$entries"
done

if [ "$found_ours" = yes ]; then
	t_pass "the volatile-journal drop-in is installed"
else
	t_fail "the volatile-journal drop-in is installed" \
		"nothing named zz-brenn-volatile.conf in ${dropin_dirs[*]}"
fi

# Replay the merge: main configuration first, then drop-ins in name order,
# last assignment of a key winning.
files=("$main")
if [ ${#dropin_path[@]} -gt 0 ]; then
	while IFS= read -r name; do
		files+=("${dropin_path[$name]}")
	done < <(printf '%s\n' "${!dropin_path[@]}" | sort)
fi

storage=""
storage_from=""
for f in "${files[@]}"; do
	content=$(img_ext4_cat "$IMG_SPEC" "$f") || continue
	value=$(img_ini_value "$content" Storage)
	if [ -n "$value" ]; then
		storage=$value
		storage_from=$f
	fi
done

if [ -n "$storage" ]; then
	t_eq "the journal resolves to ${EXPECT_JOURNAL_STORAGE} storage (from ${storage_from})" \
		"$storage" "$EXPECT_JOURNAL_STORAGE"
else
	# journald's own default is "auto", which becomes persistent as soon as
	# /var/log/journal exists — precisely the accident this guards against.
	t_fail "the journal storage is set explicitly" \
		"no Storage= in ${files[*]}"
fi

t_done
