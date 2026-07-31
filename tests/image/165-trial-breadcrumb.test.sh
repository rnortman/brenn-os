#!/usr/bin/env bash
#
# The one thing a trial boot can say before the network exists.
#
# This hardware has no serial header and no persistent journal, so a candidate
# pair that dies early leaves nothing behind but a staged trial nobody answered
# — which is exactly what a trial that was never taken leaves. The initramfs
# writes one file on the selector partition to separate the two.
#
# That reading only works in one direction if the writer is provably in the
# shipped initramfs. An absent breadcrumb after a fallback means "the boot died
# before the initramfs" only when the alternative — "the build never carried the
# writer" — has been ruled out, and ruling it out is what this test is for. It
# unpacks the initramfs the firmware actually loads rather than reading the
# sources it was assembled from, because everything between those two is where
# the writer goes missing: a hook that did not run, an overlay applied after
# update-initramfs, a submodule bump that took the tools with it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/image.sh
. "${BRENN_TESTS_LIB}/image.sh"

t_require_cmd mcopy cpio
img_open_system_root

overlay="${BRENN_REPO_ROOT}/image/layer/brenn/rauc.rootfs-overlay"

# --- what the build was given ------------------------------------------------

# The hook and the boot script reach the initramfs by being in the root
# filesystem before update-initramfs runs. Their presence here is not the claim
# this test makes — it is what makes a failure below readable as "the assembly
# dropped them" rather than "they were never shipped".
for path in "$EXPECT_BREADCRUMB_HOOK" "$EXPECT_BREADCRUMB_SCRIPT"; do
	t_eq "${path} is installed" "$(img_ext4_type "$IMG_SPEC" "$path")" regular
	t_eq "${path} is executable" "$(img_ext4_mode "$IMG_SPEC" "$path")" 755
done

# One record, three programs: the initramfs writes it, the reporter reads it out
# into the next boot's journal, and the backend removes it when a pair is
# committed. A rename in one of them is silent and reads as evidence either way
# — a record the backend no longer clears becomes testimony about a boot that
# never happened, and one the reporter no longer finds becomes a trial that
# never reached the initramfs. So the three are held to one literal.
for path in "$EXPECT_BREADCRUMB_SCRIPT" "$EXPECT_TRIAL_REPORT_EXEC" \
	"$EXPECT_RAUC_BACKEND"; do
	if content=$(img_ext4_cat "$IMG_SPEC" "$path"); then
		t_contains "${path} names the record ${EXPECT_BREADCRUMB_FILE}" \
			"$content" "breadcrumb_name=${EXPECT_BREADCRUMB_FILE}"
	else
		t_fail "${path} names the record ${EXPECT_BREADCRUMB_FILE}" \
			"cannot read ${path}"
	fi
done

# --- and what it produced ----------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! img_vfat_copy "$IMG" "$EXPECT_INITRAMFS_PART" "$EXPECT_INITRAMFS_FILE" \
	"${work}/initramfs"; then
	t_fail "the firmware has an initramfs to load" \
		"no ${EXPECT_INITRAMFS_FILE} on ${EXPECT_INITRAMFS_PART}"
	t_done
fi

if ! img_initramfs_unpack "${work}/initramfs" "${work}/root"; then
	t_fail "the initramfs unpacks" \
		"cannot read ${EXPECT_INITRAMFS_FILE} as a concatenated cpio"
	t_done
fi

ird="${work}/root"
script_name=${EXPECT_BREADCRUMB_SCRIPT##*/}
inside="${ird}/scripts/local-premount/${script_name}"

if [ ! -f "$inside" ]; then
	t_fail "the trial breadcrumb writer is in the initramfs" \
		"nothing at scripts/local-premount/${script_name}"
	t_done
fi
t_pass "the trial breadcrumb writer is in the initramfs"

# The same file, not merely a file of the same name: initramfs-tools copies boot
# scripts from /etc or from its own /usr/share depending on which exists, and a
# stale copy in the wrong one is a writer that silently is not this one.
t_eq_text "and it is the one this tree ships" \
	"$(cat "$inside")" "$(cat "${overlay}${EXPECT_BREADCRUMB_SCRIPT}")"

# The writer asks the same program the units on the running system are gated on.
# Two readers of the firmware's tryboot flag is how the initramfs and the commit
# come to disagree about whether a boot was a trial.
check="${ird}${EXPECT_TRYBOOT_CHECK}"
if [ -f "$check" ]; then
	t_pass "the tryboot reader came with it"
	t_eq_text "and is the one the running system uses" \
		"$(cat "$check")" "$(cat "${overlay}${EXPECT_TRYBOOT_CHECK}")"
else
	t_fail "the tryboot reader came with it" "nothing at ${EXPECT_TRYBOOT_CHECK}"
fi

# Everything the writer calls. Each of these is in the initramfs because some
# hook asked for it, and a diagnostic that works only because another layer
# happened to want the same tool is one a submodule bump removes silently.
while IFS= read -r tool; do
	[ -n "$tool" ] || continue
	if [ -e "${ird}${tool}" ]; then
		t_pass "the writer's ${tool} came with it"
	else
		t_fail "the writer's ${tool} came with it" "nothing at ${tool}"
	fi
done <<<"$EXPECT_INITRAMFS_TOOLS"

# --- before the check that reboots -------------------------------------------

# The A/B root check reboots the machine when the active slot's link is missing.
# Running after it would mean the one failure it exists for is also the one that
# leaves no record. mkinitramfs writes the order it resolved into the initramfs,
# so the order is read rather than assumed from the file names.
order="${ird}/scripts/local-premount/ORDER"
if [ -f "$order" ]; then
	sequence=$(sed -n 's#^/scripts/local-premount/\([^ ]*\) .*#\1#p' "$order")
	t_contains "the writer is in the boot's script order" "$sequence" "$script_name"
	t_contains "and so is the A/B root check" "$sequence" "$EXPECT_AB_ROOT_SCRIPT"

	writer_at=$(printf '%s\n' "$sequence" | grep -nxF -- "$script_name" | cut -d: -f1)
	check_at=$(printf '%s\n' "$sequence" | grep -nxF -- "$EXPECT_AB_ROOT_SCRIPT" | cut -d: -f1)
	# Both positions or a failure. A lookup that came back empty — a rename, a
	# suffix on an ORDER line — would otherwise retire the file's load-bearing
	# claim without anything going red, which is the shape of a green result
	# that checked nothing.
	if [ -n "$writer_at" ] && [ -n "$check_at" ]; then
		t_le "the record is written before the check that reboots on it" \
			"$writer_at" "$((check_at - 1))"
	else
		t_fail "the record is written before the check that reboots on it" \
			"the resolved order does not name both as whole lines" \
			"writer: '${writer_at}'  check: '${check_at}'"
	fi
else
	t_fail "the initramfs has a resolved script order" "nothing at ${order}"
fi

# --- and can write where it has to -------------------------------------------

# The selector partition is FAT. The support may arrive as a module inside the
# initramfs or built into the kernel; what matters to the reading is that it is
# there, so both answers are accepted and the absence of both is the failure.
if find "$ird" -name 'vfat.ko*' -print -quit 2>/dev/null | grep -q .; then
	t_pass "the initramfs can mount the selector partition (vfat module)"
else
	builtin_ok=no
	for version in $(img_ext4_ls "$IMG_SPEC" /usr/lib/modules); do
		list=$(img_ext4_cat "$IMG_SPEC" "/usr/lib/modules/${version}/modules.builtin") ||
			continue
		if printf '%s\n' "$list" | grep -q '/vfat\.ko$'; then
			builtin_ok=yes
			break
		fi
	done
	t_eq "the initramfs can mount the selector partition (vfat built into the kernel)" \
		"$builtin_ok" yes
fi

t_done
