#!/usr/bin/env bash
#
# What the flashing tool refuses, and what it does when it does not refuse.
#
# The tool writes whole devices. Everything standing between a mistyped device
# name and a workstation's own disk is a guard in that script, so each guard
# gets a case that violates exactly it and nothing else — the conformant setup
# is built once and one property is broken at a time, so that a guard which
# quietly stops being checked shows up as a case that passes for the wrong
# reason.
#
# The guards read the target's identity out of lsblk, so a shim supplies that
# output and the real guards run against it. Nothing here bypasses a check: the
# script under test is unmodified, and its idea of the target is a regular file,
# which is also what the data paths read and write.
#
# What a regular file cannot reach is the block-device-only work: dropping a
# buffer cache and rereading a partition table, neither of which decides whether
# a transfer was correct. The label lookup that follows such a reread, and the
# next-step advice it feeds, are reached another way — the lane sources the tool
# and calls those two functions directly, because what they print is the one
# thing the install procedure promises the operator by name and a file target
# never enters the branch that produces it.
#
# Direct I/O is not in that set — whether the tool reads
# with O_DIRECT here depends on the filesystem the temporary tree lands on, so
# rather than assume either way the lane asserts which one the tool chose
# against a probe of the same file.
#
# Both verification paths get an injected fault, because a verify that cannot
# fail is not a verify. The fault comes from a shim over dd that corrupts a file
# after a transfer, which is what an unreliable USB link does.
#
# The last section leaves the script for the two runbooks that print the same
# provisioning command: what the tool hands the operator only holds if the page
# they are reading agrees with it.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

flash="${BRENN_REPO_ROOT}/scripts/flash.sh"

if [ ! -x "$flash" ]; then
	t_fail "the flashing tool is present and executable" "not at ${flash}"
	t_done
fi

t_require_cmd zstd sha256sum unshare dd find awk

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin="${work}/bin"
mkdir -p "$bin"

# The identity the guards ask about. Each case sets one of these wrong and
# expects a refusal; the good values are spelled out here rather than defaulted
# inside the shim, so the model case really does assert the string the tool
# ships with.
good_model="Raspberry Pi multi-function USB device"
good_serial="10000000decafbad"

cat >"${bin}/lsblk" <<'SHIM'
#!/bin/sh
# Enough of lsblk for the guards: one field at a time, out of the environment.
# -d is honoured rather than ignored, because the mount guard's whole point is
# that it asks without -d and so hears about the children too. A shim that
# answered both the same would let that distinction be edited away unnoticed.
if [ -n "${SHIM_CALL_LOG-}" ]; then
	echo "lsblk $*" >>"$SHIM_CALL_LOG"
fi
field=""
prev=""
whole=0
dev=""
for a in "$@"; do
	if [ "$prev" = "-o" ]; then
		field=$a
	else
		# Whatever is asked about, as opposed to a flag or a flag's value.
		case "$a" in
			-*) ;;
			*) dev=$a ;;
		esac
	fi
	if [ "$a" = "-d" ]; then whole=1; fi
	prev=$a
done
case "$field" in
	TYPE) printf '%s\n' "${SHIM_TYPE-}" ;;
	TRAN) printf '%s\n' "${SHIM_TRAN-}" ;;
	MODEL) printf '%s\n' "${SHIM_MODEL-}" ;;
	SERIAL) printf '%s\n' "${SHIM_SERIAL-}" ;;
	SIZE) printf '%s\n' "${SHIM_SIZE-}" ;;
	MOUNTPOINTS)
		if [ -n "${SHIM_MOUNTPOINTS_FAIL-}" ]; then
			echo "lsblk: unknown column: MOUNTPOINTS" >&2
			exit 1
		fi
		# One line per device, the disk's own first. With -d only the disk
		# answers, which is what a whole-disk query really reports.
		if [ "$whole" = 1 ]; then
			printf '%s\n' "${SHIM_MOUNTPOINTS-}" | head -n1
		else
			printf '%s\n' "${SHIM_MOUNTPOINTS-}"
		fi
		;;
	# The partition table as the tool asks about it after writing one: one line
	# per device, path then label. An empty answer is what a real lsblk gives
	# while udev is still probing, and is the shape the wrong lookup mistook for
	# "no such partition".
	#
	# Answered for the device asked about and no other, the way a real lsblk
	# given a device is. A query naming none answers for every attached medium,
	# so a lookup that dropped the device from its arguments would be handed the
	# whole workstation here — which is the ambiguity this tool exists to avoid.
	PATH,PARTLABEL)
		if [ -z "$dev" ]; then
			printf '%s\n' "${SHIM_PATHLABELS-}"
		else
			printf '%s\n' "${SHIM_PATHLABELS-}" | while IFS= read -r row; do
				case "${row%% *}" in
					"$dev"*) printf '%s\n' "$row" ;;
				esac
			done
		fi
		;;
	*) exit 1 ;;
esac
SHIM

# udev, as far as anything here needs it: something to wait for that answers.
# It is logged rather than merely tolerated, because the order of the wait and
# the query is the property under assertion. Its status is a knob because a wait
# that gives up is a real outcome — a busy queue — and what the tool does with
# that status decides whether a verified write reports as a failure.
cat >"${bin}/udevadm" <<'SHIM'
#!/bin/sh
if [ -n "${SHIM_CALL_LOG-}" ]; then
	echo "udevadm $*" >>"$SHIM_CALL_LOG"
fi
exit "${SHIM_UDEVADM_RC:-0}"
SHIM

# A dd that does the transfer and then breaks something, once. The fault is
# aimed at an invocation whose arguments contain a given fragment — bulk
# transfers name the block size and the alignment probes do not — and at the
# nth such invocation, so that a fault can land after a specific pass rather
# than after a specific call.
cat >"${bin}/dd" <<'SHIM'
#!/bin/sh
real=""
for c in /usr/bin/dd /bin/dd; do
	if [ -x "$c" ]; then real=$c; break; fi
done
if [ -z "$real" ]; then
	echo "dd shim: no real dd on this machine" >&2
	exit 127
fi

"$real" "$@"
rc=$?

if [ -n "${SHIM_DD_FAULT_ON-}" ]; then
	for a in "$@"; do
		case "$a" in
			*"${SHIM_DD_FAULT_ON}"*)
				n=$(cat "${SHIM_DD_FAULT_COUNT}" 2>/dev/null || echo 0)
				n=$((n + 1))
				echo "$n" >"${SHIM_DD_FAULT_COUNT}"
				if [ "$n" -eq "${SHIM_DD_FAULT_AT-1}" ]; then
					printf 'X' | "$real" of="${SHIM_DD_FAULT_PATH}" bs=1 seek=17 \
						conv=notrunc status=none 2>/dev/null
				fi
				break
				;;
		esac
	done
fi
exit $rc
SHIM

# A clock fixed to the second, so that two dumps land on the same name and the
# no-clobber guard is reachable without racing a real one.
cat >"${bin}/date" <<'SHIM'
#!/bin/sh
if [ -n "${SHIM_DATE-}" ]; then
	printf '%s\n' "$SHIM_DATE"
	exit 0
fi
exec /usr/bin/date "$@"
SHIM

chmod +x "${bin}/lsblk" "${bin}/dd" "${bin}/date" "${bin}/udevadm"

# The conformant identity and no fault, restored before every case.
shim_reset() {
	export SHIM_TYPE=disk
	export SHIM_TRAN=usb
	export SHIM_MODEL=$good_model
	export SHIM_SERIAL=$good_serial
	export SHIM_MOUNTPOINTS=""
	export SHIM_MOUNTPOINTS_FAIL=""
	export SHIM_PATHLABELS=""
	export SHIM_UDEVADM_RC=0
	export SHIM_DATE=""
	export SHIM_CALL_LOG="${work}/shim-calls"
	rm -f "$SHIM_CALL_LOG"
	export SHIM_DD_FAULT_ON=""
	export SHIM_DD_FAULT_PATH=""
	export SHIM_DD_FAULT_AT=1
	export SHIM_DD_FAULT_COUNT="${work}/dd-fault-count"
	rm -f "$SHIM_DD_FAULT_COUNT"
	unset BRENN_FLASH_EXPECT_MODEL
}

if ! unshare -r true 2>/dev/null; then
	t_skip "the flashing tool needs root or a user namespace"
fi

out=""
rc=0
verdict=""

# Every run goes through a user namespace: the tool requires uid 0, and nothing
# here should need a lane running as root to be exercised. Not a command
# substitution, because the output and the status of the run are asserted
# separately and a subshell would drop both.
run_flash() {
	rc=0
	out=$(PATH="${bin}:${PATH}" unshare -r "$flash" "$@" 2>&1) || rc=$?
	if [ "$rc" -eq 0 ]; then verdict=accepted; else verdict=refused; fi
}

# Whether the run said a particular thing. A refusal is only useful if it tells
# the operator which assumption broke.
said() {
	if printf '%s\n' "$out" | grep -qF -- "$1"; then echo yes; else echo no; fi
}

present() {
	if [ -e "$1" ]; then echo present; else echo missing; fi
}

# One of the tool's functions, called directly by sourcing the script. The first
# argument is the PATH the case wants — usually the shims ahead of the real
# tools, and for one case a farm holding almost nothing.
#
# A shell of its own per call, because the script sets -e and pipefail as it
# loads and those are not this lane's options: a single failed assertion would
# otherwise end the run instead of being reported. No user namespace either —
# these functions read a device's labels and print advice, and need no uid for
# that.
run_sourced() {
	local path=$1
	shift
	rc=0
	# shellcheck disable=SC2016  # the arguments are the inner shell's, not this one's
	out=$(PATH="$path" "$BASH" -c '. "$1"; shift; "$@"' _ "$flash" "$@" 2>&1) || rc=$?
}

# The wait and the query, in the order the shims saw them, as one line. The
# order is the fix: asking before udev has probed the new partitions is asking
# too early, and gets an answer that looks like "no such partition".
call_order() {
	awk '/^udevadm settle/ { print "settle" }
	     /PATH,PARTLABEL/  { print "query" }' "$SHIM_CALL_LOG" |
		tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# A stand-in for a device, filled with something no two runs share, so that a
# comparison passing is a comparison that happened.
make_source() {
	head -c "$2" /dev/urandom >"$1"
}

# The name the tool derives for a dump: unit, disk and size, so that two
# logical units of one gadget cannot collide.
dump_stem() {
	local stamp=$1 dev=$2
	echo "raspberry-pi-multi-function-usb-device-${good_serial}-${stamp}-emmc-img-$(stat -Lc %s "$dev")"
}

src="${work}/emmc.img"
src_bytes=$((3 * 1024 * 1024 + 7))
make_source "$src" "$src_bytes"

dumps="${work}/dumps"
mkdir -p "$dumps"

image="${work}/brenn-os-reachy.img"
image_bytes=$((512 * 1024))
make_source "$image" "$image_bytes"
image_sha=$(sha256sum <"$image" | cut -d' ' -f1)

target="${work}/target.img"

# --- backup: the conformant case, first. Every refusal below means nothing if
# --- the accepted case does not work.

shim_reset
export SHIM_DATE=20260728-120000
run_flash backup "$src" "$dumps"
t_eq "a dump of a device that answers correctly is taken" "$verdict" accepted

stem=$(dump_stem 20260728-120000 "$src")
run_dir="${dumps}/${stem}"
archive="${run_dir}/${stem}.img.zst"

t_eq "the dump is named for the unit, the disk and its size" "$(present "$run_dir")" present
t_eq "the dump is compressed" "$(present "$archive")" present

if [ -e "$archive" ]; then
	zstd -dc -- "$archive" >"${work}/restored.img" 2>/dev/null
	t_eq "what was stored decompresses to exactly what was read" \
		"$(cmp -s "$src" "${work}/restored.img" && echo identical || echo differs)" identical

	t_eq "the recorded digest of the raw content is the digest of the source" \
		"$(awk '/\.img$/ { print $1 }' "${run_dir}/SHA256SUMS")" \
		"$(sha256sum <"$src" | cut -d' ' -f1)"

	t_eq "the recorded digest of the archive is the digest of the file on disk" \
		"$(awk '/\.img\.zst$/ { print $1 }' "${run_dir}/SHA256SUMS")" \
		"$(sha256sum <"$archive" | cut -d' ' -f1)"

	t_eq "the provenance of the dump is written beside it" \
		"$([ -s "${run_dir}/PROVENANCE.txt" ] && echo present || echo missing)" present
	t_eq "the provenance records the invocation that produced it" \
		"$(grep -c '^invocation:' "${run_dir}/PROVENANCE.txt")" 1
	t_eq "and how to put the dump back" \
		"$(grep -c 'flash.sh write' "${run_dir}/PROVENANCE.txt")" 1

	# Whether the reads went around the page cache or through it is a decision the
	# dump records, and on a regular file it depends on the filesystem under the
	# temporary tree. Pinned against a probe of that same file, so the lane states
	# which path it covered rather than leaving it to the machine it runs on.
	if dd if="$src" of=/dev/null bs=512 count=1 iflag=direct status=none 2>/dev/null; then
		want_read=direct
	else
		want_read=buffered
	fi
	t_eq "the dump records how it read the device, and that is what this filesystem allows" \
		"$(sed -n 's/^read:[[:space:]]*//p' "${run_dir}/PROVENANCE.txt")" "$want_read"
fi

# Same unit, same disk, same second: the name collides, and the one copy that
# will ever exist of what was on a device is not something to write over.
shim_reset
export SHIM_DATE=20260728-120000
run_flash backup "$src" "$dumps"
t_eq "a second dump that would land on the first is refused" "$verdict" refused
t_eq "and the first dump is untouched" \
	"$(sha256sum <"$archive" | cut -d' ' -f1)" \
	"$(awk '/\.img\.zst$/ { print $1 }' "${run_dir}/SHA256SUMS")"

shim_reset
run_flash backup "$src" "${work}/no-such-dir"
t_eq "a dump into a directory that does not exist is refused" "$verdict" refused

# --- identification, one broken property per case ---------------------------

shim_reset
export SHIM_TYPE=part
run_flash write "$src" "$image"
t_eq "a partition is refused; the image carries a partition table" "$verdict" refused

shim_reset
export SHIM_TRAN=nvme
run_flash write "$src" "$image"
t_eq "a device that is not on USB is refused — the workstation's own disks are not" \
	"$verdict" refused

shim_reset
export SHIM_TRAN=""
run_flash write "$src" "$image"
t_eq "a device reporting no transport at all is refused" "$verdict" refused

# The string the vendor's own documentation gives is what an imaging tool
# displays on Windows, and matches nothing Linux reports. A guard holding out
# for it would refuse every real session, so the case is here as itself.
shim_reset
export SHIM_MODEL="RPi-MSD- 0001"
run_flash write "$src" "$image"
t_eq "a device whose model is not the gadget's is refused" "$verdict" refused
t_eq "and the refusal names the override that would allow it" \
	"$(said BRENN_FLASH_EXPECT_MODEL)" yes

shim_reset
export SHIM_MOUNTPOINTS="/run/media/operator/rootfs"
run_flash write "$src" "$image"
t_eq "a device with a filesystem mounted off it is refused" "$verdict" refused

# What an automounter grabs is a partition, not the disk: the disk's own line is
# blank and a child's is not. The guard asks lsblk without -d for exactly that
# reason, and this is the case that keeps the query from being narrowed to the
# disk — with -d it would report nothing mounted and the write would proceed
# over a live read-write mount of the vendor root filesystem.
shim_reset
export SHIM_MOUNTPOINTS=$'\n/run/media/operator/rootfs\n'
run_flash write "$src" "$image"
t_eq "a device whose partition rather than whose disk is mounted is refused" \
	"$verdict" refused
t_eq "and the refusal names what is mounted" \
	"$(said '/run/media/operator/rootfs')" yes

# The mount guard is what stands between an automounted vendor rootfs and a
# whole-device write, so a query that fails to answer has to refuse rather than
# read as "nothing is mounted". The identity fields answer here and only this one
# query fails, which is the shape of an lsblk too old for the column.
shim_reset
export SHIM_MOUNTPOINTS_FAIL=1
run_flash write "$src" "$image"
t_eq "a mount-state query that cannot answer is refused, not read as unmounted" \
	"$verdict" refused
t_eq "and the refusal says it is the mount state it could not read" \
	"$(said 'could not read mount state')" yes

shim_reset
run_flash write "${work}/no-such-device" "$image"
t_eq "a device that does not exist is refused" "$verdict" refused

# The identification guards are shared between the two modes, and a dump is
# where skipping them does the quieter damage: a wrong or mounted target yields
# a plausible-looking artefact rather than an obvious failure, and the operator
# proceeds to the irreversible write having "taken a backup". So the shared
# guards are asserted through backup too, one broken property at a time.
shim_reset
export SHIM_DATE=20260728-150000
export SHIM_TRAN=nvme
run_flash backup "$src" "$dumps"
t_eq "a dump of a device that is not on USB is refused; the guards are shared" \
	"$verdict" refused
t_eq "and nothing that looks like a dump is left behind" \
	"$(find "$dumps" -name '*20260728-150000*' | wc -l)" 0

shim_reset
export SHIM_DATE=20260728-151000
export SHIM_MOUNTPOINTS="/run/media/operator/rootfs"
run_flash backup "$src" "$dumps"
t_eq "a dump of a device with a filesystem mounted off it is refused" "$verdict" refused
t_eq "and nothing was dumped from under the automounter" \
	"$(find "$dumps" -name '*20260728-151000*' | wc -l)" 0

# The override, which is what a renamed gadget costs: one recorded decision,
# not a bypass of the guard.
shim_reset
export SHIM_MODEL="Some Later Gadget"
export BRENN_FLASH_EXPECT_MODEL="Some Later Gadget"
head -c $((1024 * 1024)) /dev/zero >"$target"
run_flash write "$target" "$image"
t_eq "the same device is accepted once the override names what it reports" \
	"$verdict" accepted

# lsblk absent is not a warning. Reached by running with an empty path, which
# is also the assertion that the tool gets that far without needing one.
rc=0
out=$(unshare -r env PATH= "$BASH" "$flash" write "$target" "$image" 2>&1) || rc=$?
t_eq "with no lsblk to identify the target, the tool refuses to run" "$rc" 1
t_eq "and says which tool it wanted" "$(said 'lsblk is not installed')" yes

# Root is needed to read or write a device, and the tool stops before it can do
# either without it.
if [ "$(id -u)" -eq 0 ]; then
	echo "SKIP  the unprivileged refusal (this lane is running as root)"
else
	shim_reset
	rc=0
	out=$(PATH="${bin}:${PATH}" "$flash" write "$target" "$image" 2>&1) || rc=$?
	t_eq "an unprivileged invocation is refused" "$rc" 1
	t_eq "and says root is what is missing" "$(said 'needs root')" yes
fi

shim_reset
sparse="${work}/brenn-os-reachy.img.sparse"
cp "$image" "$sparse"
run_flash write "$target" "$sparse"
t_eq "a sparse image is refused by name, not written literally" "$verdict" refused
t_eq "and the refusal names the converter" "$(said simg2img)" yes

# A sparse container under an innocent name is the same container, and what a
# device would be told to hold is a description of an image rather than one.
shim_reset
misnamed="${work}/looks-raw.img"
printf '\x3a\xff\x26\xed' >"$misnamed"
head -c $((64 * 1024)) /dev/zero >>"$misnamed"
run_flash write "$target" "$misnamed"
t_eq "a sparse image renamed to look raw is refused on its contents" "$verdict" refused

shim_reset
run_flash write "$target" "${work}/no-such.img"
t_eq "an image that does not exist is refused" "$verdict" refused

# The medium has to hold the whole image. The layout's fit is asserted off the
# device too; this is the same question asked of the medium in hand, before
# anything moves.
shim_reset
too_small="${work}/too-small.img"
head -c $((256 * 1024)) /dev/zero >"$too_small"
small_before=$(sha256sum <"$too_small" | cut -d' ' -f1)
run_flash write "$too_small" "$image"
t_eq "an image larger than the medium is refused before a byte is written" \
	"$verdict" refused
t_eq "and the medium is untouched" \
	"$(sha256sum <"$too_small" | cut -d' ' -f1)" "$small_before"

shim_reset
make_source "$target" $((1024 * 1024))
tail_before=$(tail -c +$((image_bytes + 1)) "$target" | sha256sum | cut -d' ' -f1)
run_flash write "$target" "$image"
t_eq "writing an image to a device that answers correctly succeeds" "$verdict" accepted

t_eq "the device holds the image, byte for byte" \
	"$(head -c "$image_bytes" "$target" | sha256sum | cut -d' ' -f1)" "$image_sha"
t_eq "and the digest it reported is the image's own" \
	"$(printf '%s\n' "$out" | sed -n 's/^flash: verified sha256 //p')" "$image_sha"

# Everything past the image is whatever the medium held. The write does not
# reach for it and the verify does not read it.
t_eq "the medium keeps its size" "$(stat -Lc %s "$target")" $((1024 * 1024))
t_eq "and what lay past the end of the image is unchanged" \
	"$(tail -c +$((image_bytes + 1)) "$target" | sha256sum | cut -d' ' -f1)" "$tail_before"

# Which of the two next-step branches printed, not merely that one did. The
# target here is a regular file, so the tool cannot ask a kernel about a
# partition table and the no-path branch is the correct one — and both branches
# name provision.sh, so asking only for that string is an assertion that holds
# just as well while the tool hands the operator a path it was told not to use.
t_eq "and the run says what to do next" "$(said 'flash: next:')" yes
t_eq "by the branch for a target whose partition labels it could not read" \
	"$(said "lsblk -o PATH,PARTLABEL ${target}")" yes
t_eq "and it points at the provisioning step" "$(said 'scripts/provision.sh')" yes
t_lacks "and no next-step advice names the by-partlabel path, which is ambiguous across media" \
	"$out" "by-partlabel"

# The read-back composes its digest from three aligned pieces — bulk blocks,
# whole sectors, then a ragged tail — and every image above is smaller than one
# bulk block, so only the middle piece has ever run. The image this tool exists
# to write is fourteen gigabytes and takes all three on every flash. A mistake
# in the offsets between the pieces reads as a device that does not hold what
# was written, mid-teardown, identically on every retry.
shim_reset
three="${work}/three-piece.img"
three_bytes=$((4194304 + 1024 + 7))
make_source "$three" "$three_bytes"
three_sha=$(sha256sum <"$three" | cut -d' ' -f1)
spanning="${work}/spanning-target.img"
make_source "$spanning" $((8 * 1024 * 1024))
three_tail_before=$(tail -c +$((three_bytes + 1)) "$spanning" | sha256sum | cut -d' ' -f1)
run_flash write "$spanning" "$three"
t_eq "an image spanning bulk blocks, whole sectors and a ragged tail is written" \
	"$verdict" accepted
t_eq "the device holds all three pieces, byte for byte" \
	"$(head -c "$three_bytes" "$spanning" | sha256sum | cut -d' ' -f1)" "$three_sha"
t_eq "and the digest read back across all three is the image's own" \
	"$(printf '%s\n' "$out" | sed -n 's/^flash: verified sha256 //p')" "$three_sha"
t_eq "and what lay past the ragged end is unchanged" \
	"$(tail -c +$((three_bytes + 1)) "$spanning" | sha256sum | cut -d' ' -f1)" \
	"$three_tail_before"

shim_reset
head -c $((1024 * 1024)) /dev/zero >"$target"
export SHIM_DD_FAULT_ON="of=${target}"
export SHIM_DD_FAULT_PATH="$target"
run_flash write "$target" "$image"
t_eq "a device corrupted after the write fails the read-back" "$verdict" refused
t_eq "and the failure says the write did not take" \
	"$(said 'does not hold what was written')" yes

# A source that changes between the two reads is an unstable link. The dump
# would decompress cleanly and be wrong, which is what the second read exists
# to catch. The fault lands after the first bulk read, which is the pass that
# fills the archive.
shim_reset
export SHIM_DATE=20260728-130000
export SHIM_DD_FAULT_ON="bs=4194304"
export SHIM_DD_FAULT_PATH="$src"
export SHIM_DD_FAULT_AT=1
run_flash backup "$src" "$dumps"
t_eq "a source that changes between the two reads fails the dump" "$verdict" refused
t_eq "and it fails on the comparison, not on something earlier" \
	"$(said 'the stored dump does not match the device')" yes
t_eq "and nothing that looks like a dump is left behind" \
	"$(find "$dumps" -name '*20260728-130000*' | wc -l)" 0

make_source "$src" "$src_bytes"

# The comparison runs through the stored archive rather than device against
# device, so a workstation-side corruption of the only copy that will ever
# exist fails the run too. This is the case that distinguishes the two: the
# fault lands after the second bulk read, when the archive is complete and
# about to be read back.
shim_reset
export SHIM_DATE=20260728-140000
stem=$(dump_stem 20260728-140000 "$src")
export SHIM_DD_FAULT_ON="bs=4194304"
export SHIM_DD_FAULT_PATH="${dumps}/${stem}/${stem}.img.zst"
export SHIM_DD_FAULT_AT=2
run_flash backup "$src" "$dumps"
t_eq "a stored dump corrupted after it was written fails the run" "$verdict" refused
t_eq "and it fails on the stored artefact, which reading the device twice would not catch" \
	"$(said 'does not decompress')" yes
t_eq "and the unusable dump is removed rather than left looking like one" \
	"$(find "$dumps" -name '*20260728-140000*' | wc -l)" 0

# --- the label lookup and the next-step advice, called directly ---------------

# What the install procedure promises by name: the device path of the partition
# labelled `persistent` on the medium just written. The rows around the answer are
# the ones a real device gives — a whole-disk row carrying no label at all, a label
# whose first word is not the whole label, and a label that contains the word
# without being it. The last one sits ahead of the answer, so a match loosened to
# "mentions persistent" would hand back the wrong partition here rather than pass.
shim_reset
export SHIM_PATHLABELS=$'/dev/sdx\n/dev/sdx1 firmware\n/dev/sdx2 EFI System Partition\n/dev/sdx3 boot_a\n/dev/sdx4 system_a\n/dev/sdx5 persistent-backup\n/dev/sdx6 persistent'
run_sourced "${bin}:${PATH}" persistent_path /dev/sdx
t_eq "the lookup answers with the path of the partition labelled persistent" "$out" /dev/sdx6

# The reason the wrong answer was possible: the label comes from udev's database,
# which is filled in after the partitions themselves appear, so a query issued
# first gets every path with an empty label and matches none of them.
t_eq "and asks the device only after waiting for udev to have probed it" \
	"$(call_order)" "settle query"

# The whole invocation, not merely that a bound was spelled: an assertion that
# only asked for the flag would hold with the two-minute default written back in.
# This runs at the end of an eight-minute transfer, where a silent stall of that
# length reads as a wedged tool holding a device hostage.
settle_call=$(grep '^udevadm settle' "$SHIM_CALL_LOG")
t_eq "and bounds that wait rather than leaving it at udevadm's two-minute default" \
	"$settle_call" "udevadm settle --timeout=10"
t_le "a bound short enough that waiting it out is not mistaken for a hang" \
	"${settle_call##*--timeout=}" 30

# The lookup names the device it just wrote, so a second medium carrying the same
# label cannot answer for it. That scoping is the whole point of printing a path
# rather than the by-partlabel name, and a lookup that asked the workstation at
# large would resolve to whichever medium came first — here, deliberately, the
# wrong one.
shim_reset
export SHIM_PATHLABELS=$'/dev/sdy\n/dev/sdy6 persistent\n/dev/sdx\n/dev/sdx1 firmware\n/dev/sdx6 persistent'
run_sourced "${bin}:${PATH}" persistent_path /dev/sdx
t_eq "the lookup answers for the device it was given" "$out" /dev/sdx6
run_sourced "${bin}:${PATH}" persistent_path /dev/sdy
t_eq "and for another medium holding that same label, its own path" "$out" /dev/sdy6

# A wait that gives up is not a failure of the flash: the write is verified before
# any of this, and the query that follows may answer anyway. Without that
# tolerance the tool would abort on a good write, at the end of an eight-minute
# transfer, telling the operator a flash failed that did not.
shim_reset
export SHIM_UDEVADM_RC=1
export SHIM_PATHLABELS=$'/dev/sdx\n/dev/sdx6 persistent'
run_sourced "${bin}:${PATH}" persistent_path /dev/sdx
t_eq "a wait that timed out still yields the path" "$out" /dev/sdx6
t_eq "and is not a failure" "$rc" 0
t_eq "and the query happened after the attempt regardless" "$(call_order)" "settle query"

# No such label is an answer, not a fault: a vendor medium has none, and the
# write is verified either way. The caller has something to say for this case, so
# the lookup does not need to fail for it.
shim_reset
export SHIM_PATHLABELS=$'/dev/sdx\n/dev/sdx1 firmware'
run_sourced "${bin}:${PATH}" persistent_path /dev/sdx
t_eq "a device carrying no such label yields no path" "$out" ""
t_eq "and that is not a failure" "$rc" 0

# A host with no udevadm: a container, or an init that is not systemd. There the
# database that lags does not exist — lsblk as root probes the device itself, and
# this tool only ever runs as root — so its absence is tolerated rather than
# refused. The farm holds exactly what the lookup may legitimately need, so a new
# dependency slipped into it surfaces here rather than on such a host.
minimal="${work}/minimal-bin"
mkdir -p "$minimal"
ln -sf "${bin}/lsblk" "${minimal}/lsblk"
ln -sf "$(command -v awk)" "${minimal}/awk"

shim_reset
export SHIM_PATHLABELS=$'/dev/sdx\n/dev/sdx6 persistent'
run_sourced "$minimal" persistent_path /dev/sdx
t_eq "with no udevadm to wait on, the lookup still answers" "$out" /dev/sdx6
t_eq "and its absence is not a failure" "$rc" 0
t_eq "and nothing was waited for, there being nothing to wait for" "$(call_order)" "query"

# Both branches of the advice, as shipped. The first is what a successful flash
# hands the operator and what the install procedure tells them to use; the second
# is what a flash that could not read the labels hands them instead, and it has to
# name the device it just wrote rather than a label that may answer for another
# medium in the same workstation.
shim_reset
run_sourced "${bin}:${PATH}" say_next /dev/sdx /dev/sdx6
t_eq_text "with a path in hand, the tool prints the command that provisions it" "$out" \
	"flash: next: sudo scripts/provision.sh /dev/sdx6 <generation-dir>"

want_fallback="flash: next: the new table is on /dev/sdx, but its partition labels were not readable yet —
flash:       find the persistent partition:  lsblk -o PATH,PARTLABEL /dev/sdx
flash:       then:  sudo scripts/provision.sh <that-path> <generation-dir>"

shim_reset
run_sourced "${bin}:${PATH}" say_next /dev/sdx ""
t_eq_text "with no path, it says so and gives the command that finds one on that device" \
	"$out" "$want_fallback"
t_lacks "and does not send the operator to the by-partlabel name instead" "$out" "by-partlabel"

# --- and what the runbooks tell the operator to type --------------------------

# What the tool prints is half of it. Two runbooks carry the same provisioning
# command, and while either of them leads with the by-partlabel form, an operator
# following that one lands on the ambiguity whatever the tool said. The two had
# drifted into opposite advice once already, and the drift is invisible until a
# workstation holds two labelled media, so it is asserted rather than trusted.
for doc in install provisioning; do
	docfile="${BRENN_REPO_ROOT}/docs/${doc}.md"
	t_eq "docs/${doc}.md tells nobody to provision through the by-partlabel name" \
		"$(grep -cF 'provision.sh /dev/disk/by-partlabel' "$docfile")" 0
	t_eq "and gives the device-path form the flashing tool prints" \
		"$(grep -cF 'provision.sh /dev/sdX6' "$docfile")" 1
done

t_done
