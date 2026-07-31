#!/usr/bin/env bash
#
# What `make clean` would remove, and how it would go about it.
#
# The script under assertion removes the build area, so every case here is a dry
# run: it reports what it resolved and which removal it would start with — or, in
# the states where it would start none, which of those it is — and touches
# nothing. That claim is held to account rather than trusted: a canary file under
# work/ is asserted still there after the first invocation, which bounds any
# damage to one, and again at the end. That the gate does not run this lane at
# all is asserted in the gate itself (tests/host/120-clean-out-of-gate.test.sh);
# the reason is that the gate runs on every commit and this script empties the
# build area.
#
# Both facts the report is built from are reachable from outside, so the states
# that matter need neither a live mount nor a build's leftovers: the mount probe
# is `findmnt` on PATH, stubbed here from a fixture table, and the script derives
# its root from its own location, so a copy of it in a temporary tree has a build
# area this suite owns outright. Against the real repo root the stub is what makes
# the readings deterministic — the machine running this may have anything mounted
# anywhere.
#
# What that leaves review-verified rather than asserted, recorded so nobody
# mistakes these fields for coverage: the removal ladder's second rung and its
# refusal text, which need a build's leftovers to reach, and the wet path's own
# removals, which this lane never runs.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

# The mount probe is a refusal when it cannot run, and one case here deliberately
# uses the real one, so a host without it is a host this suite cannot say
# anything about.
t_require_cmd findmnt

tmp=$(mktemp -d)

# A directory under the build area, for the cases that have to be inside it: the
# knob resolution rule is about physical paths, and only a real directory under
# work/ can tell a correct judgment from a textual prefix match. The file in it is
# the canary. The dry run removes nothing, so both are safe; they are cleaned up
# here either way.
inside_dir="${BRENN_REPO_ROOT}/work/brenn-clean-test.$$"
canary="${inside_dir}/canary"
work_existed=yes
[ -d "${BRENN_REPO_ROOT}/work" ] || work_existed=no
mkdir -p "$inside_dir"
: >"$canary"

# On a checkout that has never built, the mkdir above creates work/ itself, and a
# suite that leaves it behind has every later run reporting a build area no build
# made. It goes back only if this run is what made it, and by rmdir, which
# refuses a directory with anything in it — so a real build tree is untouched.
trap 'rm -rf "$tmp"; rm -f "$canary"; rmdir "$inside_dir" 2>/dev/null || true;
	[ "$work_existed" = yes ] || rmdir "${BRENN_REPO_ROOT}/work" 2>/dev/null || true' EXIT

mkdir -p "${tmp}/bin" "${tmp}/scratch-elsewhere" "${tmp}/cache-elsewhere"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/podman"
chmod 0755 "${tmp}/bin/podman"

# The mount probe, answered from a fixture instead of from this machine. The
# guard's entire input is the target listing, and it is reached by bare name on
# PATH, exactly like the podman above: BRENN_TEST_MOUNTS names the listing (no
# file means an empty table), BRENN_TEST_MOUNTS_ERR what the probe complains
# about, and BRENN_TEST_MOUNTS_STATUS makes it fail.
mkdir -p "${tmp}/bin-findmnt"
cat >"${tmp}/bin-findmnt/findmnt" <<'EOF'
#!/bin/sh
if [ -f "${BRENN_TEST_MOUNTS:-}" ]; then
	cat -- "$BRENN_TEST_MOUNTS"
fi
if [ -n "${BRENN_TEST_MOUNTS_ERR:-}" ]; then
	echo "$BRENN_TEST_MOUNTS_ERR" >&2
fi
exit "${BRENN_TEST_MOUNTS_STATUS:-0}"
EOF
chmod 0755 "${tmp}/bin-findmnt/findmnt"
stub_path="${tmp}/bin-findmnt:${PATH}"

# A PATH with no mount probe on it at all. Everything the script resolves through
# PATH before the refusal has to be on this one, or the refusal is never reached:
# `bash`, because `#!/usr/bin/env bash` looks the interpreter up here too and a
# PATH without it fails the exec instead of running the script; `dirname`, for the
# script's own root; and `basename`, for the library's program name. Nothing else
# runs before the refusal, and no `findmnt` is here, which is the point.
mkdir -p "${tmp}/bin-bare"
for c in bash dirname basename; do
	ln -s -- "$(command -v -- "$c")" "${tmp}/bin-bare/${c}"
done

# The paths the script reports are physical, so the expectations are too.
repo_real=$(cd -P -- "${BRENN_REPO_ROOT}" && pwd -P)
workdir=$(cd -P -- "${BRENN_REPO_ROOT}/work" && pwd -P)
scratch_elsewhere=$(cd -P -- "${tmp}/scratch-elsewhere" && pwd -P)
cache_elsewhere=$(cd -P -- "${tmp}/cache-elsewhere" && pwd -P)
inside_real=$(cd -P -- "$inside_dir" && pwd -P)

# The overlay file the script reads is the developer's own, so every case names
# one explicitly, and every knob is named even where the value is empty: one
# exported in the developer's environment would otherwise reach the script and
# change what these cases assert.
none="${tmp}/absent.conf"

clean_env=(
	BRENN_BUILD_DRY_RUN=1
	"BRENN_BUILD_CONF=${none}"
	"BRENN_PODMAN=${tmp}/bin/podman"
	BRENN_SCRATCH_DIR=
	BRENN_APT_CACHEDIR=
	BRENN_IMAGE_VERSION=
	BRENN_BUILD_CONTAINER=
	BRENN_PODMAN_RUN_FLAGS=
	BRENN_TEST_MOUNTS=
	BRENN_TEST_MOUNTS_ERR=
	BRENN_TEST_MOUNTS_STATUS=
)

# Runs the script and captures its report and its status together. The status is
# held here rather than left to each case: a refusal leaves every field lookup
# empty, and a case that only compares fields would report five empty-string
# mismatches instead of the one refusal that caused them. `--refuses` says a
# refusal is the expected outcome, `--script` runs a copy of the script somewhere
# else. Environment assignments come before `--`, script arguments after it.
run_clean() {
	local expect=0 script="${BRENN_REPO_ROOT}/scripts/clean-work.sh"
	local -a extra=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		case "$1" in
			--refuses) expect=1 ;;
			--script)
				shift
				script=$1
				;;
			*) extra+=("$1") ;;
		esac
		shift
	done
	[ $# -gt 0 ] && shift
	out=$(env "${clean_env[@]}" "${extra[@]}" "$script" "$@" 2>&1)
	status=$?
	if [ "$status" != "$expect" ]; then
		t_fail "clean-work exited ${status} where ${expect} was expected — what follows is not this case's answer" \
			"$out"
	fi
}

# The same invocation with the mount table answered from the fixture, whose
# content each case below writes.
run_clean_mounts() {
	run_clean "PATH=${stub_path}" "BRENN_TEST_MOUNTS=${tmp}/mounts" "$@"
}

field() {
	printf '%s\n' "$out" | sed -n "s/^${1}: //p" | head -n1
}

# The header's claim, asserted rather than described.
assert_untouched() {
	t_eq "$1" "$([ -f "$canary" ] && [ -d "$workdir" ] && echo yes)" yes
}

# --- the real probe, once --------------------------------------------------
#
# Every case after this one stubs the mount probe, which leaves the probe's own
# invocation unasserted — and a probe this script cannot read is a refusal, so
# getting its arguments wrong would take out `make clean` on every host. This
# case runs the real one and holds it to a successful report.

run_clean
t_eq "a dry run reports rather than removes, and says so successfully" "$status" 0
t_eq "and names the one directory it is about" "$(field workdir)" "$workdir"
assert_untouched "the build area, and the file this suite put in it, are still there"

# --- what the report says about the area ------------------------------------
#
# The three readings the removal's shape follows from. Stubbed to an empty table:
# on the machine running this, the real one is whatever it happens to be.

: >"${tmp}/mounts"
run_clean_mounts
t_eq "the build area this suite has a directory in is reported present" \
	"$(field workdir-present)" yes
t_eq "an empty mount table is nothing mounted under it, not a table nobody read" \
	"$(field mounts-under)" 0
t_eq "and not a mountpoint itself, so the directory is what would go" \
	"$(field workdir-is-mountpoint)" no
t_eq "an apt cache nobody configured is reported unset, not as a directory that is missing" \
	"$(field apt-cachedir-verdict)" unset
t_eq "with no path invented for it" "$(field apt-cachedir)" ""

# --- the removal ladder ----------------------------------------------------
#
# The namespace rung is what makes this work at all: a build leaves files owned
# by sub-uids of the invoking user, and only from inside a namespace where those
# are mapped can they be removed. It is tried first rather than kept as a
# fallback, so a mixed-ownership tree does not spew errors before the rung that
# works runs. The operand is asserted, not just the command: what an `rm -rf` is
# aimed at is the one field of this report nobody should have to infer.

run_clean_mounts
t_eq "with podman available the removal runs inside a user namespace" \
	"$(field cmd)" "${tmp}/bin/podman unshare rm -rf -- ${workdir}"

run_clean_mounts "BRENN_PODMAN=${tmp}/bin/no-such-podman"
t_eq "without podman it is a plain removal, which is enough where no namespace was used" \
	"$(field cmd)" "rm -rf -- ${workdir}"
t_eq "and nothing pretends to enter a namespace that is not available" \
	"$(printf '%s\n' "$out" | grep -c unshare)" 0

# --- the guard, which is the only thing here that touches host state --------
#
# A killed native build can leave the chroot's /proc or /dev bound in, and an
# `rm -rf` through a live bind reaches whatever is on the other side of it. So a
# mount strictly under the build area is a refusal, and the count is part of the
# report.

printf '%s\n' "${workdir}/chroot-x/proc" >"${tmp}/mounts"
run_clean_mounts
t_eq "one live mount under the build area is counted" "$(field mounts-under)" 1
t_eq "and reported as the refusal it would be, rather than as a removal" \
	"$(field cmd)" "(refused: 1 live mount under ${workdir})"

printf '%s\n' "${workdir}/chroot-x/proc" "${workdir}/chroot-x/dev" >"${tmp}/mounts"
run_clean_mounts
t_eq "two of them are two" "$(field mounts-under)" 2
t_eq "said in the plural, which is all that branch does" \
	"$(field cmd)" "(refused: 2 live mounts under ${workdir})"

# findmnt --raw hex-escapes what it considers unsafe in a target, so the guard
# decodes before comparing. Against the raw string a mount under a path with a
# space in it matches nothing and is waved through.
printf '%s\n' "${workdir}/a\x20b/proc" >"${tmp}/mounts"
run_clean_mounts
t_eq "an escaped target is decoded before it is compared, not counted as zero" \
	"$(field mounts-under)" 1

# A neighbour is not a child: the comparison carries the separator.
printf '%s\n' "${workdir}2/proc" >"${tmp}/mounts"
run_clean_mounts
t_eq "a mount under a directory whose name merely starts the same is not under this one" \
	"$(field mounts-under)" 0

printf '%s\n' "" >"${tmp}/mounts"
run_clean_mounts --refuses BRENN_TEST_MOUNTS_STATUS=1 \
	"BRENN_TEST_MOUNTS_ERR=findmnt: cannot read /proc/self/mountinfo"
t_eq "a probe that failed is not a table with nothing in it — it is a refusal" "$status" 1
t_ge "carrying the probe's own account of why" \
	"$(printf '%s\n' "$out" | grep -c 'cannot read /proc/self/mountinfo')" 1
t_eq "and saying nothing about a removal, since none would run" \
	"$(printf '%s\n' "$out" | grep -c '^cmd: ')" 0

run_clean --refuses "PATH=${tmp}/bin-bare"
t_eq "a host with no mount probe at all is refused too, not waved through" "$status" 1
t_ge "and told where one comes from" \
	"$(printf '%s\n' "$out" | grep -c util-linux)" 1
t_eq "with nothing reported about a removal" \
	"$(printf '%s\n' "$out" | grep -c '^cmd: ')" 0

# --- the build area mounted from somewhere else -----------------------------
#
# A scratch disk mounted at work/ is a plausible setup for exactly this script's
# audience, so it is a reading rather than a refusal: rm cannot unlink a busy
# mountpoint, so the contents go and the directory stays. Reported as such, or
# the removal's failure would read as the sub-uid trouble it is not.

printf '%s\n' "$workdir" >"${tmp}/mounts"
shopt -s nullglob dotglob
work_entries=("${workdir}"/*)
shopt -u nullglob dotglob
run_clean_mounts
t_eq "the build area being a mountpoint itself is a reading, not a refusal" \
	"$(field workdir-is-mountpoint)" yes
t_eq "and nothing is counted as being under it" "$(field mounts-under)" 0
t_eq "what would be removed is everything in it, dotfiles included — never the mountpoint" \
	"$(field cmd)" "${tmp}/bin/podman unshare rm -rf -- ${work_entries[*]}"

# --- a build area that is not there, and one with nothing left in it --------
#
# Both are ordinary states — a second `make clean` in a row lands in the first —
# and neither is reachable against the real repo root while this suite has a
# directory in it. The script derives its root from its own location, so a copy
# of it in a temporary tree has a build area this suite owns.

mkdir -p "${tmp}/fakeroot/scripts/lib"
cp -- "${BRENN_REPO_ROOT}/scripts/clean-work.sh" "${tmp}/fakeroot/scripts/"
cp -- "${BRENN_REPO_ROOT}/scripts/lib/build-lane.sh" \
	"${BRENN_REPO_ROOT}/scripts/lib/overlay-conf.sh" "${tmp}/fakeroot/scripts/lib/"
fake_script="${tmp}/fakeroot/scripts/clean-work.sh"
fake_root=$(cd -P -- "${tmp}/fakeroot" && pwd -P)

: >"${tmp}/mounts"
run_clean_mounts --script "$fake_script"
t_eq "a build area no build made is reported absent" "$(field workdir-present)" no
t_eq "and named anyway, so the report says which directory it looked for" \
	"$(field workdir)" "${fake_root}/work"
t_eq "with no removal named, because none would run" \
	"$(field cmd)" "(nothing to clean)"

mkdir -p "${fake_root}/work"
printf '%s\n' "${fake_root}/work" >"${tmp}/mounts"
run_clean_mounts --script "$fake_script"
t_eq "a mounted build area with nothing in it is neither emptied nor refused" \
	"$(field cmd)" "(already empty)"
t_eq "and is still the mountpoint it was read as" \
	"$(field workdir-is-mountpoint)" yes

# The default knob lands in the build area, and is judged from where it actually
# is — asserted here, where this suite owns the directory it names.
: >"${tmp}/mounts"
mkdir -p "${fake_root}/work/scratch"
run_clean_mounts --script "$fake_script"
t_eq "scratch left at its default is in the build area" \
	"$(field scratch)" "${fake_root}/work/scratch"
t_eq "and judged inside it, which is why it needs no separate mention" \
	"$(field scratch-verdict)" inside

# Something in work/'s place that is not a directory is what the next build fails
# on, so "nothing to clean" would be a dead end: it goes, like anything else
# found there.
rm -rf -- "${fake_root}/work"
: >"${fake_root}/work"
run_clean_mounts --script "$fake_script"
t_eq "a work/ that is not a directory is not reported as absent" \
	"$(field workdir-present)" not-a-directory
t_eq "and is removed like anything else in its place" \
	"$(field cmd)" "${tmp}/bin/podman unshare rm -rf -- ${fake_root}/work"
rm -f -- "${fake_root}/work"

# --- where the knobs point -------------------------------------------------

: >"${tmp}/mounts"
printf 'BRENN_SCRATCH_DIR=%s\nBRENN_APT_CACHEDIR=%s\n' \
	"$scratch_elsewhere" "$cache_elsewhere" >"${tmp}/outside.conf"
run_clean_mounts "BRENN_BUILD_CONF=${tmp}/outside.conf"
t_eq "scratch the developer pointed off the build area is named" \
	"$(field scratch)" "$scratch_elsewhere"
t_eq "and reported as outside it, which is what keeps it" \
	"$(field scratch-verdict)" outside
t_eq "so is an apt cache kept out there — the way to reset without re-downloading the archive" \
	"$(field apt-cachedir)" "$cache_elsewhere"
t_eq "and it is judged the same way" "$(field apt-cachedir-verdict)" outside

# A knob is judged on where it physically resolves, not on how it is spelled. A
# relative value is relative to the repo root, which is where the build resolves
# it, and lands inside the area being removed — where a textual comparison
# against an absolute path would have called it outside and reported that a
# directory about to be deleted was being kept.
run_clean_mounts "BRENN_APT_CACHEDIR=work/$(basename -- "$inside_dir")"
t_eq "a relative knob resolves against the repo root, as the build resolves it" \
	"$(field apt-cachedir)" "$inside_real"
t_eq "and is reported as inside the build area, whatever its spelling" \
	"$(field apt-cachedir-verdict)" inside

# Nothing to preserve and nothing to judge: a directory that does not exist is
# not a location somebody is keeping things in.
run_clean_mounts "BRENN_SCRATCH_DIR=${tmp}/never-created"
t_eq "a knob naming a directory that is not there is reported absent" \
	"$(field scratch-verdict)" absent
t_eq "and the cleaner did not create it on the way past — the build's resolver does that, not this one" \
	"$([ -d "${tmp}/never-created" ] && echo yes || echo no)" no

# --- the interface ---------------------------------------------------------
#
# A namespace-aware `rm -rf` that takes a path is a footgun, so there is no path
# to give it — and the help text is what says so to whoever is looking.

run_clean -- -h
t_eq "the help text is part of the interface, and succeeds" "$status" 0
t_ge "naming the one directory this removes and the fact that it is the only one" \
	"$(printf '%s\n' "$out" | grep -cF -- "removes ${repo_real}/work, and nothing else")" 1

run_clean --refuses -- "${tmp}/scratch-elsewhere"
t_eq "a path argument is refused" "$status" 1
t_eq "before anything is resolved, let alone removed" \
	"$(printf '%s\n' "$out" | grep -c '^cmd: ')" 0
t_eq "and the directory named is still there" \
	"$([ -d "${tmp}/scratch-elsewhere" ] && echo yes)" yes

assert_untouched "and after every case above, the real build area is as it was"

t_done
