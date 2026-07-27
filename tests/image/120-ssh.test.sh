#!/usr/bin/env bash
#
# The only way in.
#
# sshd is the single listener the design allows, and it is the whole
# access-control surface of the device: there is no password anywhere, no
# console login worth the name, and nothing else on a port. So what is asserted
# here is not "our drop-in is installed" but the configuration sshd actually
# resolves — first value obtained wins, includes spliced in where they appear —
# because a packaging change that moves the include is a device that accepts
# passwords.
#
# The second half is the identity: the image carries no host key and generates
# none. A key baked into an image is a key on every device built from it, and a
# key generated at first boot is a device whose fingerprint changes under a
# reflash.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

img_open_system_root

units=/etc/systemd/system

if ! resolved=$(img_sshd_lines "$IMG_SPEC" "$EXPECT_SSHD_CONFIG"); then
	t_fail "read ${EXPECT_SSHD_CONFIG}"
	t_done
fi

while IFS='=' read -r keyword expected; do
	[ -n "$keyword" ] || continue
	t_eq "sshd resolves ${keyword} to ${expected}" \
		"$(img_sshd_value "$resolved" "$keyword")" "$expected"
done <<<"$EXPECT_SSHD_SETTINGS"

# Everything above is the global section. A Match block overrides it for the
# connections it matches, so one anywhere in the resolved configuration would
# make every assertion above a statement about a connection nobody makes — a
# `Match Address` re-enabling passwords reads as a clean suite. There is no use
# for one on this device, so any at all is the finding.
matched=$(img_sshd_keywords "$resolved" | grep -cx match) || true
t_eq "the resolved configuration has no Match block" "$matched" 0

# The drop-in has to be reached before anything sets a keyword, for any of the
# above to be what it is. Asserted separately so that a failure says which of
# the two went wrong: the values, or the order they were obtained in.
#
# The question is about settings, not about text: the packaged configuration
# opens with a comment header, and a comment resolves nothing. So the marker is
# located in the resolved stream and every line ahead of it is required to set
# no keyword at all — which is the property the values above rest on, and which
# no comment, ours or the distribution's, can satisfy on its own.
marker=$(printf '%s\n' "$resolved" | grep -nF "brenn-os sshd policy" | head -n1)
if [ -z "$marker" ]; then
	t_fail "the brenn configuration is in what sshd reads" \
		"no drop-in marker in the resolved configuration"
else
	before=$(printf '%s\n' "$resolved" | head -n $((${marker%%:*} - 1)))
	set_ahead=$(img_sshd_keywords "$before" | grep -c .) || true
	if [ "$set_ahead" -eq 0 ]; then
		t_pass "nothing sets a keyword before the brenn configuration"
	else
		t_fail "nothing sets a keyword before the brenn configuration" \
			"$(printf '%s\n' "$before" | grep -n . | sed 's/^/ahead: /')"
	fi
fi

# No host identity in the image. The package generates a key pair when it is
# configured, so this is an assertion about a build step having undone it, not
# about something that never happens.
baked=""
while IFS= read -r name; do
	case "$name" in
		ssh_host_*) baked="${baked} ${name}" ;;
	esac
done < <(img_ext4_ls "$IMG_SPEC" /etc/ssh)

if [ -z "$baked" ]; then
	t_pass "the image carries no host key"
else
	t_fail "the image carries no host key" "found in /etc/ssh:${baked}"
fi

# Nor does it generate one. On a read-only root the attempt would fail anyway;
# masking it says that the failure is the intent rather than an accident of the
# filesystem being read-only.
for masked in $EXPECT_SSH_MASKED_UNITS; do
	if target=$(img_ext4_link "$IMG_SPEC" "${units}/${masked}"); then
		t_eq "${masked} is masked" "$target" /dev/null
	else
		t_fail "${masked} is masked" "no link at ${units}/${masked}"
	fi
done

# sshd only runs where there is something to authenticate with and somebody to
# admit, and it starts after the generation carrying both has been chosen.
dropin="${units}/ssh.service.d/10-brenn-provisioned.conf"
if content=$(img_ext4_cat "$IMG_SPEC" "$dropin"); then
	t_contains "sshd starts after the generation is selected" \
		"$(img_ini_values "$content" After | tr ' ' '\n')" "$EXPECT_SELECT_UNIT"

	conditions=$(img_ini_values "$content" ConditionPathExists)
	for want in $EXPECT_SSHD_CONDITIONS; do
		t_contains "sshd is conditioned on ${want}" "$conditions" "$want"
	done
else
	t_fail "sshd is wired to the provisioning generation" \
		"no drop-in at ${dropin}"
fi

# A service nothing pulls in never runs. The alias is the name the packaged
# unit installs itself under, and the name other units order themselves against.
if link=$(img_ext4_link "$IMG_SPEC" "${units}/multi-user.target.wants/${EXPECT_SSHD_UNIT}"); then
	t_eq "sshd is wanted by multi-user.target" "$link" "$EXPECT_SSHD_UNIT_PATH"
else
	t_fail "sshd is wanted by multi-user.target" "no link in multi-user.target.wants"
fi

if link=$(img_ext4_link "$IMG_SPEC" "${units}/${EXPECT_SSHD_ALIAS}"); then
	t_eq "${EXPECT_SSHD_ALIAS} resolves to the packaged unit" \
		"$link" "$EXPECT_SSHD_UNIT_PATH"
else
	t_fail "${EXPECT_SSHD_ALIAS} resolves to the packaged unit" \
		"no link at ${units}/${EXPECT_SSHD_ALIAS}"
fi

t_eq "the packaged unit is where the wiring says it is" \
	"$(img_ext4_type "$IMG_SPEC" "$EXPECT_SSHD_UNIT_PATH")" regular

t_eq "the ssh server is installed" \
	"$(img_installed_packages "$IMG_SPEC" | awk -v p="$EXPECT_SSH_PACKAGE" '$1 == p { print $1 }')" \
	"$EXPECT_SSH_PACKAGE"

t_done
