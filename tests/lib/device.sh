# Helpers for asserting against a live unit. Source, don't execute.
#
# This is the only lane that needs something the repository cannot produce: a
# provisioned device, powered on and on the network. Where that device is and
# how to reach it is site information, so it arrives from the environment or
# from a gitignored local file and never from the tree — the same rule every
# other unit-specific value in this project follows.
#
# Everything runs over SSH in batch mode, as the administrative account. A lane
# that can stop and ask for a password is a lane that hangs.
#
# Unconfigured means skipped, and a skipped suite fails the runner: there is no
# arrangement in which this lane reports success without having talked to a
# device.

# shellcheck shell=bash

# What the profile is expected to be, in two halves. The image half is the same
# file the image suite reads, because a device assertion and an image assertion
# about the same property must not be able to disagree; the device half is the
# values that only exist once something has booted.
dev_load_expectations() {
	local image_env="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env"
	local device_env="${BRENN_REPO_ROOT}/tests/device/expected-${BRENN_PROFILE}.env"
	[ -f "$image_env" ] || t_skip "no image expectations for profile '${BRENN_PROFILE}'"
	[ -f "$device_env" ] || t_skip "no device expectations for profile '${BRENN_PROFILE}'"
	# shellcheck disable=SC1090  # path is profile-dependent by design
	. "$image_env"
	# shellcheck disable=SC1090
	. "$device_env"
}

# The target, from the environment or from the local overlay, in that order of
# precedence: an exported value is the more specific statement of intent, and
# is what a one-off run against a second unit uses.
#
# The overlay is a shell fragment because that is the shape every other local
# knob in this project takes, and it holds a host name — site information, and
# the reason the file is gitignored rather than tracked with placeholders.
dev_load_target() {
	local conf env_host env_user env_opts
	conf=${BRENN_DEVICE_CONF:-${BRENN_REPO_ROOT}/.local/device.conf}
	env_host=${BRENN_DEVICE_HOST:-}
	env_user=${BRENN_DEVICE_USER:-}
	env_opts=${BRENN_DEVICE_SSH_OPTS:-}

	if [ -f "$conf" ]; then
		# shellcheck disable=SC1090  # a local overlay, absent from the tree
		. "$conf"
	fi

	DEV_HOST=${env_host:-${BRENN_DEVICE_HOST:-}}
	if [ -z "$DEV_HOST" ]; then
		t_skip "no device configured — set BRENN_DEVICE_HOST or write ${conf} (see README)"
	fi
	DEV_USER=${env_user:-${BRENN_DEVICE_USER:-root}}
	DEV_SSH=${BRENN_DEVICE_SSH:-ssh}
	DEV_CONNECT_TIMEOUT=${BRENN_DEVICE_CONNECT_TIMEOUT:-10}

	# One connection, shared by every assertion that follows. Each assertion is
	# its own ssh command, so a full run over a radio is a hundred key exchanges
	# — minutes of handshake on the loop this lane exists to keep short, and a
	# hundred separate chances for an unrelated radio blip to read as a device
	# finding.
	#
	# Keepalives are what make that safe here: one of these tests drops the
	# association on purpose, and a shared connection that died with it has to
	# be noticed and retired rather than left for every later assertion to wait
	# on. The socket lives in the run's own directory, so nothing outgrows a
	# run; set BRENN_DEVICE_SSH_MULTIPLEX=0 to run each assertion on a
	# connection of its own.
	DEV_MUX_OPTS=()
	if [ "${BRENN_DEVICE_SSH_MULTIPLEX:-1}" != 0 ]; then
		local mux_dir=${BRENN_TEST_RUN_DIR:-}
		if [ -z "$mux_dir" ]; then
			# Run directly rather than through the runner, so this script owns
			# the directory and takes it with it. No device test sets a trap of
			# its own; if one ever does, this is what it has to chain.
			DEV_MUX_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/brenn-device-XXXXXX") ||
				t_skip "cannot create a directory for the shared ssh connection"
			mux_dir=$DEV_MUX_TMPDIR
			trap 'rm -rf "$DEV_MUX_TMPDIR"' EXIT
		fi
		mux_dir="${mux_dir}/ssh"
		mkdir -p "$mux_dir" ||
			t_skip "cannot create ${mux_dir} for the shared ssh connection"
		local mux_socket="${mux_dir}/%C"
		if [ ${#mux_socket} -gt 100 ]; then
			# A unix socket path is capped at just over a hundred characters and
			# the name is a 64-character hash, so a long temporary directory
			# puts the socket over the line. Sharing is an optimisation and
			# running without it is merely slower, which is a better answer than
			# every assertion failing on a path nobody chose — said out loud,
			# because a run that took the slow road should not look like one
			# that did not.
			echo "NOTE  ssh control path too long (${#mux_socket} characters) — each assertion opens its own connection"
		else
			DEV_MUX_OPTS=(
				-o ControlMaster=auto
				-o "ControlPath=${mux_socket}"
				-o ControlPersist=30
				-o ServerAliveInterval=5
				-o ServerAliveCountMax=3
			)
		fi
	fi

	local opts=${env_opts:-${BRENN_DEVICE_SSH_OPTS:-}}
	DEV_SSH_OPTS=()
	if [ -n "$opts" ]; then
		# Split deliberately: the overlay writes ssh options the way ssh takes
		# them on a command line, and they have to arrive as separate
		# arguments.
		# shellcheck disable=SC2206
		DEV_SSH_OPTS=($opts)
	fi

	t_require_cmd "$DEV_SSH"
}

# One command, run by the device's shell, stdout on stdout. The remote exit
# status is this function's exit status, so a test can assert either.
dev_run() {
	"$DEV_SSH" \
		-o BatchMode=yes \
		-o "ConnectTimeout=${DEV_CONNECT_TIMEOUT}" \
		"${DEV_MUX_OPTS[@]}" \
		"${DEV_SSH_OPTS[@]}" \
		"${DEV_USER}@${DEV_HOST}" \
		-- "$1"
}

# The same, with stdout captured in DEV_OUT and the remote stderr folded into
# it: when an assertion fails, what the device said about why is the finding.
dev_capture() {
	DEV_OUT=$(dev_run "$1" 2>&1)
}

# The opening every device test shares. A device that is configured but cannot
# be reached skips here rather than failing every assertion in the suite: one
# notice naming the host is a diagnosis, and thirty failures are not.
#
# 010 is the exception, and asserts reachability rather than skipping on it —
# something has to fail when the device is supposed to be there and is not.
dev_open() {
	dev_load_expectations
	dev_load_target
	if ! dev_run true >/dev/null 2>&1; then
		t_skip "cannot reach ${DEV_USER}@${DEV_HOST} over SSH"
	fi
}

# Assert on what a command printed. A command that fails at all reports its
# status, because "the file was empty" and "the tool is not installed" are
# different findings and only one of them is about the device.
dev_eq() {
	local desc=$1 cmd=$2 expected=$3 status=0
	dev_capture "$cmd" || status=$?
	if [ "$status" -ne 0 ]; then
		t_fail "$desc" "command failed (status ${status}): ${cmd}" "output: ${DEV_OUT}"
		return
	fi
	t_eq "$desc" "$DEV_OUT" "$expected"
}

# The multi-line form, reported as a diff.
dev_eq_text() {
	local desc=$1 cmd=$2 expected=$3 status=0
	dev_capture "$cmd" || status=$?
	if [ "$status" -ne 0 ]; then
		t_fail "$desc" "command failed (status ${status}): ${cmd}" "output: ${DEV_OUT}"
		return
	fi
	t_eq_text "$desc" "$DEV_OUT" "$expected"
}

# A command whose exit status is the assertion.
dev_succeeds() {
	local desc=$1 cmd=$2 status=0
	dev_capture "$cmd" || status=$?
	if [ "$status" -eq 0 ]; then
		t_pass "$desc"
	else
		t_fail "$desc" "status: ${status}" "output: ${DEV_OUT}"
	fi
}

# A command whose nonzero exit status is the assertion.
dev_refuses() {
	local desc=$1 cmd=$2 status=0
	dev_capture "$cmd" || status=$?
	if [ "$status" -ne 0 ]; then
		t_pass "$desc"
	else
		t_fail "$desc" "the command succeeded, and must not have" "output: ${DEV_OUT}"
	fi
}

# Assert on what a command prints once it settles: the command is run until it
# prints the expected value or the window runs out.
#
# This is for the assertions about recovery — a radio that lost its association
# is expected to get it back, not to have it. A command that fails while the
# device is recovering is a retry and not a finding, including the case where
# the failing command is ssh itself: the transport this lane runs over may be
# the thing that is coming back.
dev_wait() {
	local desc=$1 cmd=$2 expected=$3 seconds=$4 start=$SECONDS elapsed
	while :; do
		dev_capture "$cmd" || true
		elapsed=$((SECONDS - start))
		if [ "$DEV_OUT" = "$expected" ]; then
			t_pass "${desc} (after ${elapsed}s)"
			return 0
		fi
		if [ "$elapsed" -ge "$seconds" ]; then
			t_fail "$desc" "gave up after ${elapsed}s of ${seconds}s" \
				"expected: ${expected}" "last:     ${DEV_OUT:-<nothing>}"
			return 1
		fi
		sleep "${DEV_POLL_INTERVAL:-2}"
	done
}

# A path's presence, and its absence. Stated as their own helpers because the
# absence of a mount point or a stray file is as much of an assertion as the
# presence of one, and reads as a wish rather than a check when written inline.
dev_exists() {
	dev_succeeds "$1" "test -e $(dev_quote "$2")"
}

dev_absent() {
	dev_refuses "$1" "test -e $(dev_quote "$2")"
}

# Which partition the firmware handed control to, in DEV_PARTITION. The report
# is a device-tree property — one big-endian cell, printed as a number with
# leading whitespace — and a nonzero status means it could not be read, which is
# a finding rather than a value to carry on with.
#
# It lives here because two tests ask it: the mount census and the update
# mechanism's slot identity. They are the pair that must not be able to disagree
# about which slot is running, and a reading chased down at the bench has to
# change in one place for that to stay true.
dev_firmware_partition() {
	local status=0
	dev_capture "od -An -tu4 --endian=big -N4 $(dev_quote "${EXPECT_DT_BOOTLOADER_DIR}/partition")" ||
		status=$?
	DEV_PARTITION=${DEV_OUT//[^0-9]/}
	[ "$status" -eq 0 ] && [ -n "$DEV_PARTITION" ]
}

# The partition number of a device node, from its trailing digits, so that it
# can be compared as a number: partition 12 does not satisfy an expectation of
# partition 2, and a suffix comparison says it does. Empty for anything that
# does not end in a number.
dev_partition_number() {
	printf '%s' "${1##*[!0-9]}"
}

# Single-quote a value for the device's shell. Paths here come from the
# expectations file rather than from a device, so this is hygiene rather than a
# defence, but a mount option string with a space in it would otherwise arrive
# as two arguments.
dev_quote() {
	printf "'%s'" "${1//\'/\'\\\'\'}"
}
