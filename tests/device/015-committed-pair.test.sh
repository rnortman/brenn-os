#!/usr/bin/env bash
#
# The device is running the pair that was committed, and it is the build this
# tree describes.
#
# It runs before anything looks at content, because a device that fell back is
# running the *previous* image and every content assertion in this suite then
# fails against it — a screenful of mismatches that describe the image we
# replaced instead of saying "the update never took". Two readings say it in one
# line each, and they are the two an operator makes by hand: which pair booted,
# and what is in the update mechanism's state directory.
#
# The readings come from the backend and the filesystem rather than from `rauc
# status`: querying RAUC activates its service and writes to the persistent
# partition, which must not happen before 110 measures idle writes.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"
# shellcheck source=tests/lib/device.sh
. "${BRENN_TESTS_LIB}/device.sh"

dev_open

backend=$(dev_quote "$EXPECT_RAUC_BACKEND")

# Which pair booted, and which pair is committed. Both are read before either is
# judged: a reading that failed is empty, and comparing two empty readings
# reports agreement in exactly the case where nothing could be read.
status=0
dev_capture "${backend} get-current" || status=$?
booted=$DEV_OUT
current_status=$status

status=0
dev_capture "${backend} get-primary" || status=$?
primary=$DEV_OUT
primary_status=$status

if [ "$current_status" -ne 0 ] || [ "$primary_status" -ne 0 ] ||
	[ -z "$booted" ] || [ -z "$primary" ]; then
	t_fail "the update mechanism can name the running and committed pairs" \
		"get-current (status ${current_status}): ${booted:-<nothing>}" \
		"get-primary (status ${primary_status}): ${primary:-<nothing>}"
	t_done
fi

if [ "$booted" = "$primary" ]; then
	t_pass "the device is running the committed pair (slot ${booted})"
else
	t_fail "the device is running the committed pair" \
		"booted:    ${booted}" \
		"committed: ${primary}" \
		"the device is on a pair nothing committed to: either a trial is in" \
		"progress this very boot, or an update fell back and left it here"
fi

# The listing is taken once and both assertions read it, so they describe one
# instant.
#
# The directory itself is asserted first: a listing that failed is as empty as a
# device with nothing to report.
state_dir=$EXPECT_RAUC_STATE_DIR
status=0
dev_capture "ls -A $(dev_quote "$state_dir")" || status=$?
entries=$DEV_OUT
if [ "$status" -ne 0 ]; then
	t_fail "the update mechanism's state directory is there to be read" \
		"ls ${state_dir} (status ${status}): ${entries:-<nothing>}"
	t_done
fi
t_pass "the update mechanism's state directory is there to be read (${state_dir})"

markers() {
	local found
	found=$(printf '%s\n' "$entries" | grep "^${1}" | sort | tr '\n' ' ')
	found=${found% }
	printf '%s' "${found:-(none)}"
}

# A refusal is a file, and one that exists on a device nobody refused anything
# on is either an install that died before it finished writing, or a pair that
# was explicitly marked bad.
refused=$(markers bad-)
if [ "$refused" = "(none)" ]; then
	t_pass "neither pair has been refused"
else
	t_fail "neither pair has been refused" \
		"markers: ${refused}" \
		"an install started on that pair and did not reach staging, or" \
		"something refused it after a trial"
fi

# The staging record outlives the trial reboot and is removed only when the
# trial is answered — committed or refused. On a device that has been up a while
# on its committed pair, one still sitting there is the signature of a trial
# that never happened or never committed.
#
# Known and accepted false positive: between `rauc install` and the trial
# reboot, a staged marker is exactly right. This suite is not an in-flight
# update tool, and running it in that window is the one time this reads wrong.
staged=$(markers staged-)
if [ "$staged" = "(none)" ]; then
	t_pass "no staged trial is waiting to be answered"
else
	t_fail "no staged trial is waiting to be answered" \
		"markers: ${staged}" \
		"an update was staged onto that pair and its trial was never answered:" \
		"the trial reboot never happened, or the candidate fell back" \
		"(between 'rauc install' and the trial reboot, this is correct)"
fi

# And which build it is. The same question as the pair above — is this device
# running what we think — asked of the content rather than of the selector, and
# the one that turns "eight content assertions disagree" into "the device runs
# an older image".
#
# The device's shell is what expands this; the single quotes are what stops
# this one from doing it first.
# shellcheck disable=SC2016
dev_capture '. /etc/os-release && printf %s "${IMAGE_VERSION:-}"'
device_version=$DEV_OUT
if [ -z "$device_version" ]; then
	t_fail "the device reports which build it is running" \
		"no IMAGE_VERSION in the device's os-release" \
		"a device flashed before the field shipped answers nothing here," \
		"which is itself the finding: it predates this assertion"
	t_done
fi
t_pass "the device reports which build it is running (${device_version})"

# What the tree describes for itself, resolved the way the build resolves it so
# that the two cannot differ over anything but the source they describe. A
# deliberate cross-version run says so: BRENN_TEST_IMAGE_VERSION=any keeps the
# rest of the suite runnable against a device that is knowingly not this build,
# and any other value is compared as given.
expected=${BRENN_TEST_IMAGE_VERSION:-}
if [ "$expected" = any ]; then
	t_pass "the device's build is not compared (BRENN_TEST_IMAGE_VERSION=any)"
	t_done
fi

if [ -z "$expected" ]; then
	status=0
	expected=$(
		{
			# shellcheck source=scripts/lib/build-lane.sh
			. "${BRENN_REPO_ROOT}/scripts/lib/build-lane.sh"
			lane_load_conf
			lane_version_resolve
			printf '%s' "$BRENN_IMAGE_VERSION"
		} 2>&1
	) || status=$?
	if [ "$status" -ne 0 ] || [ -z "$expected" ]; then
		t_fail "the tree can describe the build it expects" \
			"${expected:-<nothing>}"
		t_done
	fi
fi

if [ "$device_version" = "$expected" ]; then
	t_pass "the device runs the build this tree describes (${expected})"
else
	t_fail "the device runs the build this tree describes" \
		"device: ${device_version}" \
		"tree:   ${expected}" \
		"a tree with uncommitted changes describes itself differently on" \
		"purpose; BRENN_TEST_IMAGE_VERSION=any runs the suite anyway"
fi

t_done
