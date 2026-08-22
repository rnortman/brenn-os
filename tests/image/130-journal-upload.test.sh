#!/usr/bin/env bash
#
# Logs leave the device or they do not exist.
#
# The journal is volatile (see 060), which is what keeps the flash idle and
# also what makes an upload the only way a log survives a reboot. The uploader
# is therefore not an optional extra: without it a device that reboots has told
# nobody why.
#
# What is asserted here is the wiring — the collector comes from the selected
# generation, the connection waits for a clock it can judge a certificate with,
# an unreachable collector is retried forever — and the absence of the two
# listeners the same package brings with it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system
dropin="${units}/systemd-journal-upload.service.d/10-brenn-provisioned.conf"

# The uploader's whole configuration is the provisioned file, reached through
# the published path so that it follows the generation this boot selected.
t_eq "the uploader's configuration is a link" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_UPLOAD_CONF")" symlink
if target=$(img_ext4_link "$IMG_SPEC" "$EXPECT_UPLOAD_CONF"); then
	t_eq "it reads the selected generation" "$target" "$EXPECT_UPLOAD_SOURCE"
else
	t_fail "the uploader's configuration is a link into the generation" \
		"nothing at ${EXPECT_UPLOAD_CONF}"
fi

# No collector is named by the image. An address here would be site
# configuration in a generic artefact, and it would be the wrong one.
baked=""
check_no_url() {
	local path=$1 content
	[ "$(img_ext4_type "$IMG_SPEC" "$path")" = regular ] || return 0
	content=$(img_ext4_cat "$IMG_SPEC" "$path") || return 0
	if printf '%s\n' "$content" | grep -Eq '^[[:space:]]*URL='; then
		baked="${baked} ${path}"
	fi
}

for dir in $EXPECT_UPLOAD_CONF_DIRS; do
	while IFS= read -r name; do
		case "$name" in
			*.conf) check_no_url "${dir}/${name}" ;;
		esac
	done < <(img_ext4_ls "$IMG_SPEC" "$dir")
done
check_no_url "$EXPECT_UPLOAD_CONF"
check_no_url "$EXPECT_UPLOAD_PACKAGED_CONF"

if [ -z "$baked" ]; then
	t_pass "the image names no collector of its own"
else
	t_fail "the image names no collector of its own" "URL= in:${baked}"
fi

# The packaged unit is what all of the above configures, and its ordering is
# part of the answer: read the merge rather than only our half of it.
packaged=$(img_ext4_cat "$IMG_SPEC" "$EXPECT_UPLOAD_UNIT_PATH") ||
	t_fail "the packaged uploader unit is at ${EXPECT_UPLOAD_UNIT_PATH}"

if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	after=$(printf '%s\n%s\n' "$(img_ini_values "${packaged:-}" After)" \
		"$(img_ini_values "$content" After)" | tr ' ' '\n' | grep -v '^$')
	for want in $EXPECT_UPLOAD_AFTER; do
		t_contains "the upload waits for ${want}" "$after" "$want"
	done

	t_eq "the upload runs only where a collector was provisioned" \
		"$(img_ini_value "$content" ConditionPathExists)" "$EXPECT_UPLOAD_SOURCE"

	# The retry interval grows on its own; what this removes is the start
	# limit, which would otherwise turn a long outage into a dead service
	# that nobody notices until the logs are wanted.
	t_eq "no start limit ends the retrying" \
		"$(img_ini_value "$content" StartLimitIntervalSec)" 0

	# Removing the start limit only means something if something restarts the
	# unit, and what does is the packaged unit — a fact this tree does not own
	# and therefore reads rather than assumes. Drop Restart= upstream and the
	# first collector outage kills log shipping until the next reboot, with the
	# journal volatile, which is to say: a device that then crashes has told
	# nobody why.
	merged() {
		local v
		v=$(img_ini_value "$content" "$1")
		[ -n "$v" ] || v=$(img_ini_value "${packaged:-}" "$1")
		printf '%s' "$v"
	}

	restart=$(merged Restart)
	case "$restart" in
		on-failure | always)
			t_pass "an uploader that exits is started again (Restart=${restart})"
			;;
		*)
			t_fail "an uploader that exits is started again" \
				"Restart= resolves to '${restart}' in the packaged unit plus drop-in"
			;;
	esac

	for key in $EXPECT_UPLOAD_BACKOFF_KEYS; do
		value=$(merged "$key")
		if [ -n "$value" ]; then
			t_pass "the retry interval grows to a ceiling (${key}=${value})"
		else
			t_fail "the retry interval grows to a ceiling" \
				"no ${key}= in the packaged unit or the drop-in"
		fi
	done
else
	t_fail "the uploader is wired to the provisioning generation" \
		"no drop-in at ${dropin}"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_UPLOAD_UNIT}"); then
	t_eq "the upload is wanted by multi-user.target" "$link" "$EXPECT_UPLOAD_UNIT_PATH"
else
	t_fail "the upload is wanted by multi-user.target" \
		"no link in multi-user.target.wants"
fi

# The same package ships a journal receiver and a journal gateway. Both accept
# connections, and no connection-accepting service but sshd is admitted.
for masked in $EXPECT_UPLOAD_MASKED_UNITS; do
	if target=$(img_ext4_link "$IMG_SPEC" "${units}/${masked}"); then
		t_eq "${masked} is masked" "$target" /dev/null
	else
		t_fail "${masked} is masked" "no link at ${units}/${masked}"
	fi
done

t_eq "the journal uploader is installed" \
	"$(img_installed_packages "$IMG_SPEC" | awk -v p="$EXPECT_UPLOAD_PACKAGE" '$1 == p { print $1 }')" \
	"$EXPECT_UPLOAD_PACKAGE"

t_done
