#!/usr/bin/env bash
#
# Reclaim the build area.
#
#   scripts/clean-work.sh
#
# Removes work/ — the image, the per-version chroot and deploy directories a
# build leaves behind, the build scratch, and the apt package cache when it
# lives there. There is no path argument: this removes the one directory it
# names itself, because a general `rm -rf` wrapper is a footgun.
#
# A plain `rm -rf work` does not do this. Builds run inside a user namespace, so
# files the chroot creates as anything other than root come out owned by
# sub-uids of the invoking user, inside directories that user cannot traverse —
# the removal fails partway on files that look like his own. The removal here
# runs inside such a namespace (`podman unshare`), where those uids are mapped
# and namespace root can traverse everything, and falls back to a plain removal
# where there is no podman: a host with no working podman can only hold a build
# whose files the invoking user owns outright.
#
# Scratch or an apt cache that a knob points outside work/ are named and left
# alone. They are locations somebody chose, possibly shared, and an apt cache
# kept out there is the documented way to survive a reset without re-downloading
# the archive.
#
# Podman's own image storage is untouched; builder images from earlier
# definitions are named, since this is the moment somebody is reclaiming disk,
# but removing them stays their own act.
#
# BRENN_BUILD_DRY_RUN reports what was resolved and what would run instead of
# removing anything.

set -euo pipefail

repo_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck source=scripts/lib/build-lane.sh
. "${repo_root}/scripts/lib/build-lane.sh"

# The knobs are the build's, so a relative value in them resolves the way the
# build resolves it: against the repo root, which is where `make` runs.
cd "$repo_root"

usage() {
	echo "usage: $(basename "$0")" >&2
	echo "removes ${repo_root}/work, and nothing else" >&2
}

case "${1:-}" in
	"") ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "clean-work: takes no arguments" >&2
		usage
		exit 1
		;;
esac

lane_load_conf

workdir="${repo_root}/work"
workdir_present=no
if [ -d "$workdir" ]; then
	workdir_present=yes
	# repo_root is already physical, so the path is too unless work/ is itself a
	# symlink — and only then is resolving it worth a traversal the invoking user
	# may not have. Where it is a symlink that cannot be followed, what a removal
	# would reach cannot be established and the mount guard below has nothing
	# exact to compare against, so that is a refusal rather than a guess.
	if [ -L "$workdir" ]; then
		workdir=$(cd -P -- "$workdir" && pwd -P) ||
			lane_die "${workdir} is a symlink that cannot be followed, so what a removal would reach is unknown." \
				"Its own error is above. Point it somewhere readable, or remove the link." \
				"Nothing was removed."
	fi
elif [ -e "$workdir" ] || [ -L "$workdir" ]; then
	# Something is in work/'s place and it is not a directory — a redirection
	# typo, a dangling link. It is what the next build fails on, so reporting
	# nothing to clean would be false; it goes, like anything else found there.
	workdir_present=not-a-directory
fi

# Live mounts under work/ are the one way a removal here could reach outside its
# own scope: a killed native build can leave the chroot's /proc or /dev bound in,
# and an `rm -rf` through a live bind reaches host state. The container lane's
# mounts die with its namespace, so this fires essentially never; it is cheap
# insurance for the case where it matters.
#
# work/ being a mountpoint *itself* is a different thing — a scratch disk mounted
# there is a plausible setup for exactly this script's audience — and is handled
# below rather than refused.
#
# Only a directory is probed. Something else in work/'s place holds nothing under
# it, and if it is a bind mount of its own then rm cannot unlink it and says so,
# which the ladder's refusal passes on.
mounts_under=()
workdir_mountpoint=no

if [ "$workdir_present" = yes ]; then
	if ! command -v findmnt >/dev/null 2>&1; then
		lane_die "findmnt is not installed, so live mounts under ${workdir} cannot be ruled out." \
			"Removing through a mount a killed build left behind reaches whatever it points at," \
			"so this refuses rather than guessing. Install util-linux and run it again."
	fi

	# A probe that failed is not the same reading as a table with nothing in it,
	# and treating it as one is the way to lose the guard on a host where it
	# matters. The table is read into a variable rather than piped into the loop
	# because a process substitution's exit status never reaches the command it
	# feeds, so there would be nothing left to check.
	if ! mount_table=$(findmnt -rn -o TARGET); then
		lane_die "findmnt could not read the mount table, so live mounts under ${workdir} cannot be ruled out." \
			"Removing through a mount a killed build left behind reaches whatever it points at," \
			"so this refuses rather than guessing. Its own output is above."
	fi

	# findmnt --raw hex-escapes the characters it considers unsafe in a target:
	# a space arrives as \x20, a newline as \x0a, a backslash as \x5c. Since a
	# bare backslash therefore never survives into the output, decoding the
	# sequences back is unambiguous — and it is what makes the comparison exact.
	# Against the raw string, a mount under a path holding any of those
	# characters matches nothing and the guard waves it through.
	while IFS= read -r raw_target; do
		printf -v target '%b' "$raw_target"
		case "$target" in
			"$workdir") workdir_mountpoint=yes ;;
			"${workdir}"/*) mounts_under+=("$target") ;;
		esac
	done <<<"$mount_table"
fi

# Where a knob points, and whether that is inside the area being removed. Judged
# on the physical path rather than on the text: a relative value, or a symlink
# whose target is under work/, is inside, and a textual prefix match would
# misstate what the removal is about to do. Nothing is created here — a cleaner
# that makes directories is not a cleaner — so a knob naming a directory that
# does not exist has nothing to preserve and gets no verdict.
knob_resolve() {
	local dir=$1
	knob_path=$dir
	if [ -z "$dir" ]; then
		knob_state="unset"
		return
	fi
	if [ ! -d "$dir" ]; then
		knob_state=absent
		return
	fi
	# A directory can be seen without being entered: one owned by another user or
	# by a sub-uid, mode 700, answers -d and refuses cd. That is a state to name,
	# not a reason to die here — the verdict is a report either way, since nothing
	# outside work/ is removed and anything inside it goes with work/ whatever
	# this says. Dying would forfeit a removal the namespace rung would manage.
	if ! knob_path=$(cd -P -- "$dir" 2>/dev/null && pwd -P); then
		knob_path=$dir
		knob_state=unresolvable
		return
	fi
	case "$knob_path" in
		"$workdir" | "${workdir}"/*) knob_state=inside ;;
		*) knob_state=outside ;;
	esac
}

knob_resolve "$BRENN_SCRATCH_DIR"
scratch_path=$knob_path
scratch_state=$knob_state

knob_resolve "$BRENN_APT_CACHEDIR"
cache_path=$knob_path
cache_state=$knob_state

# What gets removed. In the mountpoint case the contents go and the directory
# stays: rm cannot unlink a busy mountpoint, and its failure would be reported as
# the sub-uid trouble it is not.
targets=("$workdir")
if [ "$workdir_mountpoint" = yes ]; then
	shopt -s nullglob dotglob
	targets=("${workdir}"/*)
	shopt -u nullglob dotglob
fi

podman_present=no
if command -v -- "$BRENN_PODMAN" >/dev/null 2>&1; then
	podman_present=yes
fi

# The namespace rung is tried first rather than kept as a fallback, so a
# mixed-ownership tree does not spew hundreds of permission errors before the
# rung that works runs.
removal=(rm -rf --)
if [ "$podman_present" = yes ]; then
	removal=("$BRENN_PODMAN" unshare rm -rf --)
fi

# What the report says under `cmd:`. In the three states where no removal runs —
# nothing there, a refusal, nothing left to remove — it says which of them it is,
# in the same order the removal below decides them. A dry run is the preflight
# for an `rm -rf`, so the field naming a removal that would never happen is the
# one thing it must not do.
if lane_dry_run; then
	if [ "$workdir_present" = no ]; then
		cmd_report="(nothing to clean)"
	elif [ ${#mounts_under[@]} -gt 0 ]; then
		noun=mounts
		if [ ${#mounts_under[@]} -eq 1 ]; then
			noun=mount
		fi
		cmd_report="(refused: ${#mounts_under[@]} live ${noun} under ${workdir})"
	elif [ ${#targets[@]} -eq 0 ]; then
		cmd_report="(already empty)"
	else
		cmd_report="${removal[*]} ${targets[*]}"
	fi

	echo "workdir: ${workdir}"
	echo "workdir-present: ${workdir_present}"
	echo "workdir-is-mountpoint: ${workdir_mountpoint}"
	echo "mounts-under: ${#mounts_under[@]}"
	echo "scratch: ${scratch_path}"
	echo "scratch-verdict: ${scratch_state}"
	echo "apt-cachedir: ${cache_path}"
	echo "apt-cachedir-verdict: ${cache_state}"
	echo "cmd: ${cmd_report}"
	exit 0
fi

if [ "$workdir_present" = no ]; then
	echo "clean-work: nothing to clean — ${workdir} does not exist"
	exit 0
fi

if [ ${#mounts_under[@]} -gt 0 ]; then
	lane_die "something is still mounted under ${workdir}; nothing was removed." \
		"${mounts_under[@]}" \
		"A removal through a live mount reaches whatever is on the other side of it." \
		"These are what a killed build leaves behind: unmount them and run it again." \
		"If a build is running, this is that build's — wait for it instead."
fi

report_kept() {
	local what=$1 path=$2 state=$3
	case "$state" in
		outside)
			echo "clean-work: ${what} is ${path}, outside the build area — left alone"
			;;
		unresolvable)
			echo "clean-work: ${what} is ${path}, which cannot be entered — left alone unless it is under the build area, in which case it goes with it"
			;;
	esac
}

report_kept "the build scratch" "$scratch_path" "$scratch_state"
report_kept "the apt package cache" "$cache_path" "$cache_state"

# Each rung's own diagnosis is kept, line by line: what a removal refuses on, and
# on which file, is something rm names precisely and this script can only guess
# at.
removal_output=()
run_removal() {
	local status=0 out
	out=$("$@" 2>&1) || status=$?
	lane_split_lines removal_output "$out"
	return "$status"
}

if [ ${#targets[@]} -eq 0 ]; then
	echo "clean-work: ${workdir} is already empty"
else
	removed=no
	if [ "$podman_present" = yes ]; then
		if run_removal "${removal[@]}" "${targets[@]}"; then
			removed=yes
		else
			echo "clean-work: ${BRENN_PODMAN} unshare could not do it; trying a plain removal" >&2
			if [ ${#removal_output[@]} -gt 0 ]; then
				printf '    %s\n' "${removal_output[@]}" >&2
			fi
		fi
	fi

	if [ "$removed" = no ]; then
		if ! run_removal rm -rf -- "${targets[@]}"; then
			lane_die "could not remove ${workdir}." \
				"${removal_output[@]}" \
				"The build runs in a user namespace, so what it leaves is owned by sub-uids of" \
				"the invoking user — or, if something ran privileged, by uids outside those" \
				"ranges. Either install podman and run it again, so the removal can happen" \
				"inside such a namespace, or remove it by hand from one:" \
				"    unshare --map-root-user --map-auto rm -rf work"
		fi
	fi

	if [ "$workdir_mountpoint" = yes ]; then
		echo "clean-work: emptied ${workdir}; it is a mountpoint, so the directory itself stays"
	else
		echo "clean-work: removed ${workdir}"
	fi
fi

# Reclaiming disk is exactly when a shelf of superseded builder images is worth
# knowing about.
if [ "$podman_present" = yes ]; then
	tag=$(lane_image_tag 2>/dev/null || true)
	if [ -n "$tag" ]; then
		lane_report_superseded "$tag"
	fi
fi
