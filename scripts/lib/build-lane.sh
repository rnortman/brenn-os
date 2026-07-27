# Lane selection and build scratch for the two operations that need the image
# builder — a build and a metadata lint. Source, don't execute.
#
# The builder probes its dependencies with `dpkg -s` and installs them with
# `apt`, so a host that is not Debian-family arm64 cannot pass its own gate no
# matter what is installed. On such a host the operation runs in the pinned
# container this repo builds (containers/builder/Containerfile) with the repo
# bind-mounted, and arm64 execution rides the host's binfmt_misc registration.
# Everything else in the repo runs natively.
#
# Knobs, environment first and .local/build.conf second, that file being the
# gitignored local overlay:
#
#   BRENN_BUILD_CONTAINER   auto (default) | never | always
#   BRENN_SCRATCH_DIR       build scratch; default <repo>/work/scratch
#   BRENN_APT_CACHEDIR      host-side apt package cache the builder bind-mounts
#                           into the chroot. Unset, the native lane leaves the
#                           cache in the chroot — the builder's own default —
#                           and the container lane puts it under work/, so an
#                           emulated build does not re-download the archive on
#                           every run. Set, both lanes use the directory named;
#                           the container mounts it if it is outside the repo
#   BRENN_PODMAN            the podman to run (default podman)
#   BRENN_PODMAN_RUN_FLAGS  extra flags for `podman run`, word-split
#
# Four more variables exist so that the routing can be asserted on a host that
# has neither podman nor a builder, and are the only reason they exist:
# BRENN_BUILD_DRY_RUN reports the resolved facts and the command instead of
# running it, and BRENN_HOST_ARCH, BRENN_HOST_OS_RELEASE and BRENN_BINFMT_DIR
# stand in for the host facts the lane is chosen on. BRENN_BUILD_CONF names the
# overlay file, for the same reason.

# shellcheck shell=bash

lane_repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lane_prog=$(basename -- "$0")

# Where the repo appears inside the container. A fixed path rather than the
# host's, so that whatever the build records of its own paths is the same on
# every machine that runs this lane.
lane_container_repo=/src

lane_die() {
	echo "${lane_prog}: $1" >&2
	shift
	local line
	for line in "$@"; do
		echo "    ${line}" >&2
	done
	exit 1
}

# The knobs, resolved once. An exported value is the more specific statement of
# intent and outranks the overlay file; the overlay outranks the default.
lane_load_conf() {
	local conf env_lane env_scratch env_cache env_podman env_flags
	conf=${BRENN_BUILD_CONF:-${lane_repo_root}/.local/build.conf}
	env_lane=${BRENN_BUILD_CONTAINER:-}
	env_scratch=${BRENN_SCRATCH_DIR:-}
	env_cache=${BRENN_APT_CACHEDIR:-}
	env_podman=${BRENN_PODMAN:-}
	env_flags=${BRENN_PODMAN_RUN_FLAGS:-}

	if [ -f "$conf" ]; then
		# shellcheck disable=SC1090  # a local overlay, absent from the tree
		. "$conf"
	fi

	BRENN_BUILD_CONTAINER=${env_lane:-${BRENN_BUILD_CONTAINER:-auto}}
	BRENN_SCRATCH_DIR=${env_scratch:-${BRENN_SCRATCH_DIR:-${lane_repo_root}/work/scratch}}
	BRENN_APT_CACHEDIR=${env_cache:-${BRENN_APT_CACHEDIR:-}}
	BRENN_PODMAN=${env_podman:-${BRENN_PODMAN:-podman}}
	BRENN_PODMAN_RUN_FLAGS=${env_flags:-${BRENN_PODMAN_RUN_FLAGS:-}}

	case "$BRENN_BUILD_CONTAINER" in
		auto | never | always) ;;
		*)
			lane_die "BRENN_BUILD_CONTAINER is '${BRENN_BUILD_CONTAINER}'" \
				"expected one of: auto never always"
			;;
	esac
}

# Scratch space, pointed into the build area and exported.
#
# TMPDIR must be exported: child processes inherit it from the environment, and
# an unexported value silently leaves them writing to /tmp. The build stages
# gigabytes under this directory, and /tmp on a workstation is commonly a tmpfs,
# so the default would run the build in RAM.
lane_scratch_setup() {
	mkdir -p -- "$BRENN_SCRATCH_DIR"
	lane_scratch=$(cd -- "$BRENN_SCRATCH_DIR" && pwd)
	TMPDIR="$lane_scratch"
	export TMPDIR

	if [ -n "$BRENN_APT_CACHEDIR" ]; then
		# The cache directory must exist before the build starts, so a fresh
		# clone or a deleted work/ must not be able to kill the first build.
		# Canonicalised because lane_mount_path prefix-matches it against the
		# repo root.
		mkdir -p -- "$BRENN_APT_CACHEDIR"
		BRENN_APT_CACHEDIR=$(cd -- "$BRENN_APT_CACHEDIR" && pwd)
	fi

	lane_scratch_fstype=$(findmnt -no FSTYPE --target "$lane_scratch" 2>/dev/null || echo unknown)
	if [ "$lane_scratch_fstype" = tmpfs ]; then
		echo "${lane_prog}: build scratch is on tmpfs — this build stages gigabytes in RAM" >&2
		echo "${lane_prog}: scratch is ${lane_scratch}; move it with BRENN_SCRATCH_DIR or .local/build.conf" >&2
	fi
}

# Whether this host is one the builder's own dependency gate can pass on.
#
# Only a 64-bit ARM host builds the target root filesystem without emulation. A
# host reporting armv7l or armv8l runs a 32-bit kernel and cannot execute an
# arm64 binary at all, so it takes the container lane and the binfmt preflight
# with it, like any other foreign architecture.
lane_host_supported() {
	local arch osrel
	arch=${BRENN_HOST_ARCH:-$(uname -m)}
	case "$arch" in
		aarch64 | arm64) ;;
		*) return 1 ;;
	esac
	osrel=${BRENN_HOST_OS_RELEASE:-/etc/os-release}
	[ -r "$osrel" ] || return 1
	grep -Eq '^(ID|ID_LIKE)=.*debian' "$osrel"
}

lane_select() {
	case "$BRENN_BUILD_CONTAINER" in
		never) echo native ;;
		always) echo container ;;
		*)
			if lane_host_supported; then
				echo native
			else
				echo container
			fi
			;;
	esac
}

# Whether the container lane can run here, with what is missing and how to fix
# it left in lane_unmet. A build that starts without these dies deep inside a
# bootstrap instead, with a message about something else. The caller decides
# whether an unmet prerequisite is a refusal or a loud skip.
lane_container_check() {
	# shellcheck disable=SC2034  # read by the caller, which the linter cannot see
	lane_unmet=

	if ! command -v -- "$BRENN_PODMAN" >/dev/null 2>&1; then
		lane_unmet=$(printf '%s\n' \
			"the image builder needs a Debian host, so it runs in a container here — and ${BRENN_PODMAN} is not installed." \
			"    Install podman, or set BRENN_BUILD_CONTAINER=never to run the builder directly and watch its own dependency check fail.")
		return 1
	fi

	# An arm64 host runs the target's binaries directly, so it needs no
	# registration. Every other architecture, 32-bit ARM included, does.
	local arch
	arch=${BRENN_HOST_ARCH:-$(uname -m)}
	case "$arch" in
		aarch64 | arm64) return 0 ;;
	esac

	# arm64 binaries in the target root filesystem need the host's binfmt_misc
	# interpreter, and the build requires a registration to be visible. The
	# container carries no qemu of its own, and the F
	# flag is what makes the host's registration usable from inside one: it opens
	# the interpreter at registration time, so the interpreter does not have to
	# exist in the container's filesystem.
	local dir reg
	dir=${BRENN_BINFMT_DIR:-/proc/sys/fs/binfmt_misc}
	for reg in "${dir}"/qemu-aarch64*; do
		[ -f "$reg" ] || continue
		grep -qx enabled "$reg" 2>/dev/null || continue
		grep -q '^flags:.*F' "$reg" 2>/dev/null || continue
		lane_binfmt_dir=$dir
		return 0
	done

	# shellcheck disable=SC2034  # read by the caller, which the linter cannot see
	lane_unmet=$(printf '%s\n' \
		"no usable aarch64 binfmt_misc registration under ${dir}, so an arm64 root filesystem cannot be built on this ${arch} host." \
		"    Install qemu-user-static, then check that the aarch64 registration is enabled and carries the F flag:" \
		"        cat ${dir}/qemu-aarch64" \
		"    Fedora registers it that way by default; on Debian and Ubuntu the qemu-user-static package does.")
	return 1
}

# The image is named for the content of its definition, so editing the file or
# bumping a pin in it invalidates the cached image rather than silently reusing
# one built from an older definition.
lane_image_tag() {
	local digest
	digest=$(sha256sum -- "${lane_repo_root}/containers/builder/Containerfile" | cut -c1-12)
	echo "brenn-os/builder:${digest}"
}

lane_ensure_image() {
	local tag=$1
	if "$BRENN_PODMAN" image exists "$tag"; then
		return 0
	fi
	echo "${lane_prog}: building the builder image ${tag} — first use of this definition" >&2
	"$BRENN_PODMAN" build \
		--tag "$tag" \
		--file "${lane_repo_root}/containers/builder/Containerfile" \
		-- "${lane_repo_root}/containers/builder"
	lane_report_superseded "$tag"
}

# Every earlier definition is still in podman storage, several hundred MB each,
# and a pin bump mints a new one. Nothing is removed here — an image a developer
# may still want to build against is theirs to keep — but a year of them is not
# something to discover as an unattributed disk-full.
lane_report_superseded() {
	local tag=$1 stale line
	stale=$("$BRENN_PODMAN" images --format '{{.Repository}}:{{.Tag}}' -- brenn-os/builder 2>/dev/null |
		grep -vxF -- "$tag" || true)
	[ -n "$stale" ] || return 0

	echo "${lane_prog}: builder images from earlier definitions are still in podman storage:" >&2
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		echo "    ${line}" >&2
	done <<<"$stale"
	echo "${lane_prog}: remove the ones you no longer need with: ${BRENN_PODMAN} rmi <image>" >&2
}

# Where a host directory a knob names appears inside the container, left in
# lane_mount_result. One under the repo arrives with the repo's own mount and is
# rewritten to the fixed path; anything else is mounted at <fallback>, the mount
# appended to lane_argv. Without this an inner invocation would resolve a host
# path against the container's own filesystem and write somewhere nobody named.
lane_mount_path() {
	local host=$1 fallback=$2
	case "$host" in
		"${lane_repo_root}/"*)
			lane_mount_result=${lane_container_repo}/${host#"${lane_repo_root}/"}
			;;
		*)
			lane_mount_result=$fallback
			lane_argv+=(--volume "${host}:${fallback}")
			;;
	esac
}

# The command that runs `$@` inside the container, left in lane_argv.
#
# Rootless podman on the host, uid 0 inside its user namespace — host-side
# this grants nothing beyond the invoking user's own privileges. SELinux
# labelling is disabled for this container rather than relabelling the
# developer's repo, which is what mounting it with :z would do. SYS_ADMIN is
# the one capability podman's default set is missing that the bootstrap
# needs — `unshare --mount` fails without it. One capability, not --privileged.
lane_container_argv() {
	local tag=$1
	shift

	lane_argv=("$BRENN_PODMAN" run --rm --security-opt label=disable --cap-add=SYS_ADMIN)
	lane_argv+=(--volume "${lane_repo_root}:${lane_container_repo}")

	local scratch_in_container cache_in_container
	lane_mount_path "$lane_scratch" /scratch
	scratch_in_container=$lane_mount_result

	cache_in_container=${lane_container_repo}/work/apt-cache
	if [ -n "$BRENN_APT_CACHEDIR" ]; then
		lane_mount_path "$BRENN_APT_CACHEDIR" /apt-cache
		cache_in_container=$lane_mount_result
	fi

	# binfmt_misc must be visible inside the container. Passing the host's
	# own mount in preserves the registrations a fresh mount inside the
	# namespace would hide.
	if [ -n "${lane_binfmt_dir:-}" ]; then
		lane_argv+=(--volume "${lane_binfmt_dir}:/proc/sys/fs/binfmt_misc:ro")
	fi

	lane_argv+=(--workdir "$lane_container_repo")
	lane_argv+=(--env BRENN_BUILD_CONTAINER=never)
	lane_argv+=(--env "BRENN_SCRATCH_DIR=${scratch_in_container}")
	lane_argv+=(--env "BRENN_APT_CACHEDIR=${cache_in_container}")

	if [ -n "$BRENN_PODMAN_RUN_FLAGS" ]; then
		local -a extra=()
		read -r -a extra <<<"$BRENN_PODMAN_RUN_FLAGS"
		lane_argv+=("${extra[@]}")
	fi

	lane_argv+=("$tag" "$@")
}

# What was resolved and what would run, for the dry run. The value TMPDIR has
# in a child process is the one fact here that cannot be read off the code: an
# unexported assignment prints the same thing everywhere else and moves nothing.
lane_report() {
	local lane=$1
	shift
	echo "lane: ${lane}"
	echo "scratch: ${lane_scratch}"
	echo "scratch-fstype: ${lane_scratch_fstype}"
	echo "tmpdir-child: $(bash -c 'printf "%s" "${TMPDIR-}"')"
	echo "apt-cachedir: ${BRENN_APT_CACHEDIR}"
	echo "cmd: $*"
}

lane_dry_run() {
	[ -n "${BRENN_BUILD_DRY_RUN:-}" ]
}
