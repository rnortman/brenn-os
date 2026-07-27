#!/usr/bin/env bash
#
# Which lane the builder runs in, and where the build's scratch goes.
#
# Both are decisions the two builder-facing scripts make before they do any
# work, from host facts and one knob each, and both are exactly the kind of
# decision that is otherwise only observed by watching a half-hour build fail on
# the wrong machine. The scripts report what they resolved and what they would
# run instead of running it, so the routing, the refusals, and the scratch knob's
# precedence are all assertable here — no podman, no container, no build.
#
# The scratch knob's export attribute is asserted rather than its value alone:
# TMPDIR must be exported for child processes to inherit it, and an unexported
# value silently leaves them writing to /tmp, which on a workstation is
# commonly RAM.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

t_builder_file "${BRENN_REPO_ROOT}/rpi-image-gen/rpi-image-gen" \
	"the builder is checked out" \
	"both scripts refuse before they route, so there is nothing to assert"

t_require_cmd git

tmp=$(mktemp -d)
# A directory on a filesystem known to be RAM-backed, for the one case that has
# to be: the notice this suite asserts fires on the filesystem type, and $tmp is
# a tmpfs on some machines and a disk on others.
shm_scratch="/dev/shm/brenn-build-lane-test.$$"
trap 'rm -rf "$tmp" "$shm_scratch"' EXIT

# A host the builder supports, and one it does not. Nothing here reads the
# machine the test runs on, so the same assertions hold on a developer
# workstation and on either CI runner.
mkdir -p "${tmp}/bin" "${tmp}/binfmt"
printf 'ID=debian\n' >"${tmp}/os-release.debian"
printf 'ID=fedora\n' >"${tmp}/os-release.fedora"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/podman"
chmod 0755 "${tmp}/bin/podman"
printf 'enabled\ninterpreter /usr/bin/qemu-aarch64-static\nflags: F\n' >"${tmp}/binfmt/qemu-aarch64"

# The knob file the scripts read is the developer's own gitignored overlay, so
# every case below names one explicitly — a machine that has one must not be
# able to change what this test asserts.
none="${tmp}/absent.conf"

# Stand-ins for the two facts the automatic choice is made on, plus the
# prerequisites the container lane refuses without. Cases override by prefixing
# their own assignments.
lane_env=(
	BRENN_BUILD_DRY_RUN=1
	"BRENN_BUILD_CONF=${none}"
	"BRENN_PODMAN=${tmp}/bin/podman"
	"BRENN_BINFMT_DIR=${tmp}/binfmt"
	"BRENN_SCRATCH_DIR=${tmp}/scratch"
)

# Runs one of the two scripts with the fabricated host, capturing the report and
# the status together: a refusal is as much of an outcome as a route.
run_lane() {
	local script=$1
	shift
	local -a extra=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		extra+=("$1")
		shift
	done
	[ $# -gt 0 ] && shift
	out=$(env "${lane_env[@]}" "${extra[@]}" \
		"${BRENN_REPO_ROOT}/scripts/${script}" "$@" 2>&1)
	status=$?
}

field() {
	printf '%s\n' "$out" | sed -n "s/^${1}: //p" | head -n1
}

build() { run_lane build-image.sh "$@" -- reachy; }
lint() { run_lane lint-layers.sh "$@" --; }

# --- the automatic choice --------------------------------------------------

build BRENN_HOST_ARCH=aarch64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian"
t_eq "a Debian arm64 host runs the builder directly" "$(field lane)" native

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora"
t_eq "any other host runs it in the container" "$(field lane)" container

build BRENN_HOST_ARCH=aarch64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora"
t_eq "the right architecture on the wrong distribution is not enough" \
	"$(field lane)" container

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian"
t_eq "nor the right distribution on the wrong architecture" \
	"$(field lane)" container

# 32-bit ARM is the architecture that looks native and is not: a host reporting
# armv7l runs a 32-bit kernel and cannot execute an arm64 binary at all, so it
# needs the emulation every other foreign host needs.
build BRENN_HOST_ARCH=armv7l "BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian"
t_eq "a 32-bit ARM host is not a host the target's binaries run on" \
	"$(field lane)" container

build BRENN_HOST_ARCH=armv7l "BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian" \
	"BRENN_BINFMT_DIR=${tmp}/binfmt-empty"
t_eq "and it is held to the binfmt preflight, not waved through as ARM" \
	"$status" 1

# --- the knob overrides it either way -------------------------------------

build BRENN_BUILD_CONTAINER=never BRENN_HOST_ARCH=x86_64 \
	"BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora"
t_eq "never keeps the builder in the caller's hands, wherever that is" \
	"$(field lane)" native

build BRENN_BUILD_CONTAINER=always BRENN_HOST_ARCH=aarch64 \
	"BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian"
t_eq "always takes the container even where the native lane would work" \
	"$(field lane)" container
t_eq "and needs no binfmt mount when the host is already arm64" \
	"$(printf '%s\n' "$out" | grep -c 'binfmt_misc')" 0

build BRENN_BUILD_CONTAINER=sometimes
t_eq "an unknown value for the lane knob is refused, not guessed" "$status" 1

# --- what the container invocation carries --------------------------------

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora"
cmd=$(field cmd)
tag="brenn-os/builder:$(sha256sum -- "${BRENN_REPO_ROOT}/containers/builder/Containerfile" | cut -c1-12)"
t_eq "the image is named for the content of its definition, so editing it invalidates the cache" \
	"$(printf '%s\n' "$cmd" | grep -cF -- "$tag")" 1
t_eq "the repo is bind-mounted at a fixed path, not the host's" \
	"$(printf '%s\n' "$cmd" | grep -cF -- "--volume ${BRENN_REPO_ROOT}:/src")" 1
t_eq "the host's binfmt registrations are passed in rather than remounted inside" \
	"$(printf '%s\n' "$cmd" | grep -cF -- "--volume ${tmp}/binfmt:/proc/sys/fs/binfmt_misc:ro")" 1
t_eq "the inner invocation is the same script, on the lane it can pass the dependency gate of" \
	"$(printf '%s\n' "$cmd" | grep -cF -- "${tag} /src/scripts/build-image.sh reachy")" 1
t_eq "and it is told to stay there, so the container cannot recurse" \
	"$(printf '%s\n' "$cmd" | grep -cF -- '--env BRENN_BUILD_CONTAINER=never')" 1
t_eq "and the apt package cache lands in the mounted build area" \
	"$(printf '%s\n' "$cmd" | grep -cF -- '--env BRENN_APT_CACHEDIR=/src/work/apt-cache')" 1
t_eq "the bootstrap gets the one capability it needs to mount the chroot" \
	"$(printf '%s\n' "$cmd" | grep -cF -- '--cap-add=SYS_ADMIN')" 1
t_eq "the scratch dir crosses the mount, so the gigabytes stage where the knob says" \
	"$(printf '%s\n' "$cmd" | grep -cF -- "--volume ${tmp}/scratch:/scratch")" 1
t_eq "and the build inside resolves TMPDIR to where it arrived, not to container storage" \
	"$(printf '%s\n' "$cmd" | grep -cF -- '--env BRENN_SCRATCH_DIR=/scratch')" 1
t_eq "and nothing takes the shortcut of running the whole thing privileged" \
	"$(printf '%s\n' "$cmd" | grep -cF -- '--privileged')" 0

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_PODMAN_RUN_FLAGS=--privileged --cap-add=SYS_ADMIN"
t_eq "the privilege ladder the pilot may need is reachable without editing the tree" \
	"$(field cmd | grep -c -- '--privileged --cap-add=SYS_ADMIN')" 1

# The default every developer gets is inside the repo, which is already mounted.
build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_SCRATCH_DIR=${BRENN_REPO_ROOT}/work/scratch"
t_eq "scratch left at its default needs no mount of its own" \
	"$(field cmd | grep -c -- '--volume [^ ]*work/scratch')" 0
t_eq "only the path it has on the other side of the repo's own mount" \
	"$(field cmd | grep -cF -- '--env BRENN_SCRATCH_DIR=/src/work/scratch')" 1

# --- the apt cache knob crosses the mount ----------------------------------
#
# This is the lane every developer workstation takes, so a knob that quietly
# meant something else here would be the one nobody could debug.

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_APT_CACHEDIR=${tmp}/apt-cache-elsewhere"
t_eq "a cache the developer pointed off the repo is mounted rather than discarded" \
	"$(field cmd | grep -cF -- "--volume ${tmp}/apt-cache-elsewhere:/apt-cache")" 1
t_eq "and the build inside is told where it arrived" \
	"$(field cmd | grep -cF -- '--env BRENN_APT_CACHEDIR=/apt-cache')" 1

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_APT_CACHEDIR=${BRENN_REPO_ROOT}/work/apt-cache-under-repo"
t_eq "one already under the repo needs no mount of its own" \
	"$(field cmd | grep -c -- '--volume [^ ]*apt-cache-under-repo')" 0
t_eq "only the path it has on the other side of the repo's own mount" \
	"$(field cmd | grep -cF -- '--env BRENN_APT_CACHEDIR=/src/work/apt-cache-under-repo')" 1
rmdir "${BRENN_REPO_ROOT}/work/apt-cache-under-repo" 2>/dev/null || true

# --- what an earlier definition left behind --------------------------------

# A podman that has never seen this definition and holds one image from an
# older one. Every call it gets is answered here, including the run that would
# otherwise have started a half-hour build.
cat >"${tmp}/bin/podman-stale" <<EOF
#!/bin/sh
case "\$1 \$2" in
	"image exists") exit 1 ;;
esac
case "\$1" in
	build) exit 0 ;;
	images) printf '%s\n' "${tag}" "brenn-os/builder:0123456789ab" ;;
esac
exit 0
EOF
chmod 0755 "${tmp}/bin/podman-stale"

build BRENN_BUILD_DRY_RUN= BRENN_HOST_ARCH=x86_64 \
	"BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_PODMAN=${tmp}/bin/podman-stale"
t_eq "building a new definition names the images it supersedes" \
	"$(printf '%s\n' "$out" | grep -cx '    brenn-os/builder:0123456789ab')" 1
t_eq "the one just built is not among them" \
	"$(printf '%s\n' "$out" | grep -cx "    ${tag}")" 0
t_ge "and the remedy is stated rather than taken — nobody's storage is cleaned out from under them" \
	"$(printf '%s\n' "$out" | grep -c 'rmi')" 1

# --- refusals, each naming its remedy ------------------------------------

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_PODMAN=${tmp}/bin/no-such-podman"
t_eq "a build with no podman is refused" "$status" 1
t_ge "and the refusal names podman" \
	"$(printf '%s\n' "$out" | grep -ci podman)" 1

build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_BINFMT_DIR=${tmp}/binfmt-empty"
t_eq "a build with no aarch64 binfmt registration is refused" "$status" 1
t_ge "and the refusal names the package that provides one" \
	"$(printf '%s\n' "$out" | grep -c qemu-user-static)" 1

mkdir -p "${tmp}/binfmt-noflag"
printf 'enabled\ninterpreter /usr/bin/qemu-aarch64-static\nflags: OC\n' \
	>"${tmp}/binfmt-noflag/qemu-aarch64"
build BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_BINFMT_DIR=${tmp}/binfmt-noflag"
t_eq "a registration without the F flag is refused too — the interpreter would have to exist inside the container" \
	"$status" 1

# --- scratch space -------------------------------------------------------

build BRENN_BUILD_CONTAINER=never BRENN_SCRATCH_DIR=
t_eq "scratch defaults into the gitignored build area, never /tmp" \
	"$(field scratch)" "${BRENN_REPO_ROOT}/work/scratch"

printf 'BRENN_SCRATCH_DIR=%s\n' "${tmp}/from-conf" >"${tmp}/build.conf"
mkdir -p "${tmp}/from-conf" "${tmp}/from-env"
build BRENN_BUILD_CONTAINER=never BRENN_SCRATCH_DIR= "BRENN_BUILD_CONF=${tmp}/build.conf"
t_eq "the local overlay overrides the default" "$(field scratch)" "${tmp}/from-conf"

build BRENN_BUILD_CONTAINER=never "BRENN_SCRATCH_DIR=${tmp}/from-env" \
	"BRENN_BUILD_CONF=${tmp}/build.conf"
t_eq "and an exported value outranks the overlay" "$(field scratch)" "${tmp}/from-env"

t_eq "a child process sees the resolved scratch dir as its TMPDIR" \
	"$(field tmpdir-child)" "${tmp}/from-env"

build BRENN_BUILD_CONTAINER=never "BRENN_SCRATCH_DIR=${tmp}/from-env" \
	"BRENN_BUILD_CONF=${tmp}/build.conf" BRENN_APT_CACHEDIR=
t_eq "the apt cache is opt-in on the native lane, where the builder's own default applies" \
	"$(field apt-cachedir)" ""

build BRENN_BUILD_CONTAINER=never "BRENN_SCRATCH_DIR=${tmp}/from-env" \
	"BRENN_APT_CACHEDIR=${tmp}/apt-cache"
t_eq "and when it is set the builder is told, as an override the caller can still outrank" \
	"$(field cmd | grep -c -- "-- IGconf_sys_apt_cachedir=${tmp}/apt-cache")" 1
t_eq "the directory is created first, because the builder hard-fails on a missing one" \
	"$([ -d "${tmp}/apt-cache" ] && echo yes)" yes

# --- the notice the whole knob exists for ----------------------------------
#
# Building in RAM is allowed; doing it without knowing is the failure this
# closes. The warning is the only thing standing between a developer and an OOM
# half an hour into a build, and it is driven by a filesystem type the resolver
# reads — so it is asserted against a filesystem known to be RAM-backed rather
# than against whatever this machine mounts where.

build BRENN_BUILD_CONTAINER=never BRENN_SCRATCH_DIR=
if [ "$(field scratch-fstype)" != tmpfs ]; then
	t_eq "scratch on a disk-backed filesystem says nothing" \
		"$(printf '%s\n' "$out" | grep -c 'stages gigabytes in RAM')" 0
fi

if [ "$(findmnt -no FSTYPE --target /dev/shm 2>/dev/null)" = tmpfs ]; then
	build BRENN_BUILD_CONTAINER=never "BRENN_SCRATCH_DIR=${shm_scratch}"
	t_eq "a RAM-backed scratch dir is recognised as one" \
		"$(field scratch-fstype)" tmpfs
	t_ge "and said out loud" \
		"$(printf '%s\n' "$out" | grep -c 'stages gigabytes in RAM')" 1
	t_ge "naming the knob that moves it" \
		"$(printf '%s\n' "$out" | grep -c 'BRENN_SCRATCH_DIR')" 1
fi

# --- the layer lint routes the same way ----------------------------------

lint BRENN_HOST_ARCH=aarch64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.debian"
if python3 -c 'import debian.deb822' >/dev/null 2>&1; then
	t_eq "the layer lint runs the builder directly on a host that supports it" \
		"$(field lane)" native
	# The dry run is only worth asserting on if it describes the command that
	# runs. Both lanes run this one, which is why it can be reported at all.
	# shellcheck disable=SC2016  # the loop body is expanded inside the command, not here
	t_eq "and reports the command it runs, which is the one the other lane runs too" \
		"$(field cmd | grep -cF -- 'metadata --lint "$f"')" 1
else
	# The native lane's one remaining skip, and the reason the probe for it sits
	# behind the lane choice: on the container lane the parser comes with the
	# container, so a machine without it locally is not a machine that skips.
	t_eq "a supported host without the linter's parser skips loudly on the native lane" \
		"$(printf '%s\n' "$out" | grep -c 'python3-debian not installed')" 1
fi

lint BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora"
t_eq "and in the container on a host that does not — so the gate is not degraded there" \
	"$(field lane)" container
t_eq "linting every layer in one container rather than one each" \
	"$(field cmd | grep -c 'metadata --lint')" 1

lint BRENN_HOST_ARCH=x86_64 "BRENN_HOST_OS_RELEASE=${tmp}/os-release.fedora" \
	"BRENN_PODMAN=${tmp}/bin/no-such-podman"
t_eq "a host with neither lane skips the lint loudly rather than failing a commit" \
	"$status" 0
t_eq "and says so" \
	"$(printf '%s\n' "$out" | grep -c 'LAYER LINT SKIPPED')" 1

t_done
