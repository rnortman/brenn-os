#!/usr/bin/env bash
#
# The two image lanes in CI, and the job that holds them to each other.
#
# The product is built two ways: natively on an arm64 Debian runner, which is
# the release-shaped lane, and through the pinned container on an amd64 runner,
# which is the lane every developer workstation takes. The whole value of the
# second is the claim that it produces the same image as the first, and that
# claim is only made if three things line up across a single workflow file —
# each build job records a manifest, each uploads it under the name the
# comparison downloads, and the comparison job waits for both.
#
# A rename in one of those places does not break a workflow: it produces a
# comparison job that never runs, or one that compares a file against itself. So
# the chain is asserted here, where a broken link is a red gate rather than a
# green run that checked nothing.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

workflow="${BRENN_REPO_ROOT}/.github/workflows/ci.yml"
[ -f "$workflow" ] || {
	t_fail "the workflow is present" "not at ${workflow}"
	t_done
}

# One job's body: from its key at two-space indent to the next key at that
# indent. Jobs are what this test reasons about, and an assertion made against
# the whole file would be satisfied by the right line in the wrong job.
job_block() {
	awk -v want="  $1:" '
		$0 == want { injob = 1; next }
		injob && /^  [^ ]/ { exit }
		injob { print }
	' "$workflow"
}

native=$(job_block image)
container=$(job_block image-container)
identity=$(job_block image-identity)

for pair in "image:$native" "image-container:$container" "image-identity:$identity"; do
	if [ -z "${pair#*:}" ]; then
		t_fail "the workflow defines the ${pair%%:*} job" "no such job in ${workflow}"
		t_done
	fi
done

# --- the two image lanes ---------------------------------------------------

t_eq "the release-shaped lane still builds on an arm64 runner" \
	"$(printf '%s\n' "$native" | grep -c '^    runs-on: ubuntu-24.04-arm$')" 1
t_eq "and still builds natively — a container there would prove something else" \
	"$(printf '%s\n' "$native" | grep -c 'BRENN_BUILD_CONTAINER')" 0

t_eq "the container lane builds on an amd64 runner, which the builder does not support" \
	"$(printf '%s\n' "$container" | grep -c '^    runs-on: ubuntu-24.04$')" 1
t_eq "and forces the container rather than letting the lane be chosen for it" \
	"$(printf '%s\n' "$container" | grep -c 'BRENN_BUILD_CONTAINER: always')" 1

# The container carries no qemu: arm64 binaries in the target root filesystem
# run through the host's registration, which is only usable from inside a
# container when it carries the F flag. Checked before the build, because the
# failure without it arrives an hour in and names something else.
t_eq "the host's qemu is installed for the container to borrow" \
	"$(printf '%s\n' "$container" | grep -c 'qemu-user-static')" 1
t_eq "and the flag that makes it usable from a container is asserted" \
	"$(printf '%s\n' "$container" | grep -c "flags:.*F")" 1

# mtools is how the image suite reads the vfat partitions, and is not on the
# runner. Without it those assertions skip, and a suite that skips some of its
# tests still passes — which is the failure mode this lane exists to avoid.
t_eq "the tools the image suite reads with are installed on this lane too" \
	"$(printf '%s\n' "$container" | grep -c 'apt-get install .*mtools')" 1

# Every binary in the target root filesystem runs under emulation on this lane,
# so the build is slow by nature. A timeout sized for the native lane would kill
# it mid-build and report it as a lane failure.
timeout=$(printf '%s\n' "$container" | sed -n 's/^    timeout-minutes: //p' | head -n1)
t_eq "the container lane sets a timeout" "$([ -n "$timeout" ] && echo yes)" yes
t_ge "and one sized for an emulated build" "${timeout:-0}" 180

# Both builds run only when the path filter says the image lane changed. Drop
# that and every push spends hours of shared runner time, with a green run and
# nothing to point at — the kind of change that reads as correct on review
# because the job itself still looks right.
for pair in "image:${native}" "image-container:${container}"; do
	job=${pair%%:*}
	block=${pair#*:}
	t_eq "the ${job} job is gated on the path filter's answer" \
		"$(printf '%s\n' "$block" | grep -c '^    needs: image-scope$')" 1
	t_eq "and asks for it rather than building unconditionally" \
		"$(printf '%s\n' "$block" | grep -cF "if: needs.image-scope.outputs.build == 'true'")" 1
done

# --- the chain the comparison hangs on -------------------------------------

# This is also what gates the comparison: a job whose needs are all skipped is
# skipped too, so image-identity carries no condition of its own.
t_eq "the comparison waits for both lanes" \
	"$(printf '%s\n' "$identity" | grep -c '^    needs: \[image, image-container\]$')" 1

compare_line=$(printf '%s\n' "$identity" | tr '\n' ' ' | tr -s ' ')
t_eq "and runs the comparison rather than reimplementing it" \
	"$(printf '%s\n' "$compare_line" | grep -c 'scripts/image-manifest.sh compare')" 1

# Each half of the chain, end to end: the file the build job writes, the
# artifact name it uploads under, the name the comparison downloads, and the
# path it hands to the comparison. Four spellings of one name, in three jobs.
check_lane() {
	local lane=$1 block=$2
	local file="manifest-${lane}.txt"

	t_eq "the ${lane} lane records a manifest of what it built" \
		"$(printf '%s\n' "$block" | grep -c "image-manifest.sh emit --output \"\$RUNNER_TEMP/${file}\"")" 1
	t_eq "and uploads it as manifest-${lane}" \
		"$(printf '%s\n' "$block" | grep -c "^          name: manifest-${lane}$")" 1
	t_eq "from the file it just wrote" \
		"$(printf '%s\n' "$block" | grep -c "^          path: \${{ runner.temp }}/${file}$")" 1
	t_eq "which the comparison downloads" \
		"$(printf '%s\n' "$identity" | grep -c "^          name: manifest-${lane}$")" 1
	t_eq "into the directory it compares from" \
		"$(printf '%s\n' "$compare_line" | grep -c "manifests/${file}")" 1
}

check_lane native "$native"
check_lane container "$container"

# The comparison is between two lanes, so two different files: pointing both
# arguments at one of them is a job that is green by construction.
t_eq "the two arguments are different manifests" \
	"$(printf '%s\n' "$compare_line" |
		grep -o 'manifests/manifest-[a-z]*\.txt' | sort -u | wc -l)" 2

t_done
