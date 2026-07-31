# The firmware and the boot partitions, as a fixture. Source, don't execute.
#
# Everything the tryboot backend reads about the machine it is running on comes
# from two places: the GPT labels, and what the firmware reported when it handed
# over. Both are stood in for by a directory — the labels become symlinks with a
# partition number in the name, the report becomes two files holding the words
# the device tree would have carried.
#
# Shared because two lanes need the same answer from the same backend: the trial
# machinery drives its whole decision table, and the pre-install gate asks it
# which pair is running. A second copy of this layout is how those two come to
# disagree about which slot is which.

# shellcheck shell=bash

# The layout this profile ships: the selector partition first, then the two boot
# partitions. The backend is told none of this — it reads the labels.
declare -A TRYBOOT_PARTITION_OF=(
	[bootconfig]=1
	[boot_a]=2
	[boot_b]=3
	[system_a]=4
	[system_b]=5
	[persistent]=6
)

# The selector file the firmware reads, in the shape the image ships it and the
# shape the backend must keep it in: the committed pair's boot partition outside
# the tryboot section, the candidate's inside it. Written out here as well as in
# the image expectations on purpose — one says what the build produced, this says
# what the update mechanism leaves behind, and the firmware needs them to be the
# same thing.
tryboot_autoboot_text() {
	printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' \
		"$1" "$2"
}

# One value of the firmware's report, 32-bit big-endian as it arrives in the
# device tree.
tryboot_dt_u32() {
	local dir=$1 name=$2 value=$3 escapes
	escapes=$(printf '\\%03o\\%03o\\%03o\\%03o' \
		$(((value >> 24) & 255)) $(((value >> 16) & 255)) \
		$(((value >> 8) & 255)) $((value & 255)))
	printf '%b' "$escapes" >"${dir}/${name}"
}

# Where the last fixture put the two things a caller hands to
# BRENN_TRYBOOT_SLOT_DIR and BRENN_TRYBOOT_DT_DIR. Published rather than left for
# each caller to re-derive: the layout is this file's, and a caller holding its
# own copy of these paths is the same divergence one lane at a time.
tryboot_slots=""
tryboot_dt=""

# A machine the backend can read, under one root: the labelled partitions and the
# firmware's report, at the two paths above. The report says which partition this
# boot came from and whether it took the one-shot tryboot path; both default to an
# ordinary boot of slot A.
tryboot_fixture() {
	local root=$1 booted=${2:-2} flag=${3:-0} label
	tryboot_slots="${root}/dev/disk/by-partlabel"
	tryboot_dt="${root}/dt"
	mkdir -p "$tryboot_slots" "$tryboot_dt"
	for label in "${!TRYBOOT_PARTITION_OF[@]}"; do
		: >"${root}/dev/mmcblk0p${TRYBOOT_PARTITION_OF[$label]}"
		ln -sf "../../mmcblk0p${TRYBOOT_PARTITION_OF[$label]}" \
			"${tryboot_slots}/${label}"
	done
	tryboot_dt_u32 "$tryboot_dt" partition "$booted"
	tryboot_dt_u32 "$tryboot_dt" tryboot "$flag"
}
