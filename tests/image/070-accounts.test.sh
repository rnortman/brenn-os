#!/usr/bin/env bash
#
# Who exists on the device, and what they can do.
#
# The account set is baked into the image so that changing it is an A/B system
# update with rollback rather than an edit on a live device, and the
# application account's ids are pinned so that ownership on the persistent
# partition survives updates. Neither property is visible at run time until it
# is wrong, so both are asserted here.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

if ! passwd=$(img_ext4_cat "$IMG_SPEC" /etc/passwd); then
	t_fail "read /etc/passwd from the root filesystem"
	t_done
fi
group=$(img_ext4_cat "$IMG_SPEC" /etc/group) || group=""
shadow=$(img_ext4_cat "$IMG_SPEC" /etc/shadow) || shadow=""

app_line=$(printf '%s\n' "$passwd" | awk -F: -v u="$EXPECT_APP_USER" '$1 == u')
if [ -n "$app_line" ]; then
	IFS=: read -r _ _ app_uid app_gid _ app_home app_shell <<<"$app_line"
	t_eq "${EXPECT_APP_USER} has the pinned uid" "$app_uid" "$EXPECT_APP_UID"
	t_eq "${EXPECT_APP_USER} has the pinned gid" "$app_gid" "$EXPECT_APP_GID"
	t_eq "${EXPECT_APP_USER} has its home on the volatile /var" "$app_home" "$EXPECT_APP_HOME"
	t_eq "${EXPECT_APP_USER} has no interactive shell" "$app_shell" "$EXPECT_APP_SHELL"
else
	t_fail "the ${EXPECT_APP_USER} account exists" "no ${EXPECT_APP_USER} line in /etc/passwd"
fi

t_eq "the ${EXPECT_APP_USER} group has the pinned gid" \
	"$(printf '%s\n' "$group" | awk -F: -v g="$EXPECT_APP_USER" '$1 == g { print $3 }')" \
	"$EXPECT_APP_GID"

# Hardware access is by group membership. A missing group here is a device the
# application cannot open, diagnosed on hardware as a permission error.
for want in $EXPECT_APP_GROUPS; do
	members=$(printf '%s\n' "$group" | awk -F: -v g="$want" '$1 == g { print $4 }')
	if printf '%s' "$members" | tr ',' '\n' | grep -qxF -- "$EXPECT_APP_USER"; then
		t_pass "${EXPECT_APP_USER} is in the ${want} group"
	else
		t_fail "${EXPECT_APP_USER} is in the ${want} group" "members: ${members:-<no such group>}"
	fi
done

# Nothing beyond the system accounts and the application account. The builder's
# own layers create an administrative account by default; it is displaced
# rather than left alongside.
t_eq "the only non-system account is ${EXPECT_APP_USER}" \
	"$(printf '%s\n' "$passwd" | awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' | sort | tr '\n' ' ' | sed 's/ *$//')" \
	"$EXPECT_APP_USER"

# Accounts that can be logged into at all. /bin/sync is Debian's stock
# do-nothing account and is not a shell in any useful sense.
logins=$(printf '%s\n' "$passwd" |
	awk -F: '$7 !~ /(nologin|false|\/sync)$/ { print $1 }' | sort | tr '\n' ' ' | sed 's/ *$//')
t_eq "only the expected accounts have a shell" "$logins" "$EXPECT_LOGIN_ACCOUNTS"

# No password, anywhere, ever: SSH is key-only and the console is a serial
# line. Anything in the password field that is not "no password" (`*`) or
# "locked" (a leading `!`) is something an account can be authenticated with,
# and this is stated as what may be there rather than as a search for what may
# not: a legacy crypt(3) hash carries no marker of any kind, and an empty field
# is not a locked account but an account that needs no password at all.
#
# Account names only in the report. The field itself is a credential.
credentialed=$(printf '%s\n' "$shadow" |
	awk -F: 'NF >= 2 && $2 != "*" && $2 !~ /^!/ { print $1 }' | tr '\n' ' ' | sed 's/ *$//')
if [ -z "$credentialed" ]; then
	t_pass "no account can be authenticated with a password"
else
	t_fail "no account can be authenticated with a password" \
		"accounts whose password field is neither '*' nor locked: ${credentialed}"
fi

# sudo is purged rather than merely unconfigured: privilege belongs to the
# image, which is signed and reversible, not to anything running on top of it.
if img_ext4_exists "$IMG_SPEC" /usr/bin/sudo; then
	t_fail "sudo is not installed" "/usr/bin/sudo is present in the root filesystem"
else
	t_pass "sudo is not installed"
fi

t_done
