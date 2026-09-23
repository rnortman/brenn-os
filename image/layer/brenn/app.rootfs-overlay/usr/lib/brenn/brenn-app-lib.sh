# The part of obtaining a payload that does not depend on where it came from.
# Source, don't execute.
#
# A payload reaches the RAM store as an archive by one of three doors — the
# fetch, the stage from the baked store on flash, and a bake — and from there
# on each of them does the same thing: unpack it into a fresh release directory
# and hand that to the activate step. Doing it here, once, is what keeps the
# three from drifting into three subtly different payloads.
#
# Callers set `brenn_app_activate` to the activate program before calling
# brenn_app_install; everything else is read from the environment:
#
#   BRENN_APP_DIR    the RAM payload store (default /run/brenn-app)
#   BRENN_BAKED_DIR  the baked store on flash (default /data/baked)

# shellcheck shell=sh

brenn_app_dir=${BRENN_APP_DIR:-/run/brenn-app}
brenn_baked_dir=${BRENN_BAKED_DIR:-/data/baked}

brenn_app_note() {
	echo "$(basename -- "$0"): $*" >&2
}

# The SHA-256 of a file, as the 64 hex digits and nothing else.
brenn_app_digest() {
	sha256sum <"$1" | cut -d' ' -f1
}

# A name that sorts by when it was taken and cannot collide with a release in
# either store. The prefix says which door the payload came in by, so that
# `readlink current` answers that question on a running device.
brenn_app_release_id() {
	id_stamp="${1}-$(date -u +%Y%m%dT%H%M%SZ)"
	id_base=$id_stamp
	id_n=0
	while [ -e "${brenn_app_dir}/releases/${id_stamp}" ] ||
		[ -e "${brenn_baked_dir}/releases/${id_stamp}" ]; do
		id_n=$((id_n + 1))
		id_stamp="${id_base}-${id_n}"
	done
	printf '%s' "$id_stamp"
}

# True if the device is baked: the selecting link resolves to a release. A
# dangling link is not baked mode, the same reading the units' conditions give
# it. This is the one place the question is spelled.
brenn_app_baked_active() {
	[ -d "${brenn_baked_dir}/active" ]
}

# Take the payload store lock on fd 9 for the rest of the calling shell, and
# export BRENN_APP_LOCK_HELD=yes so the activate step it runs does not block on
# it. The one lock covers both stores. Returns nonzero, having said so, if the
# lock cannot be taken.
brenn_app_lock() {
	lock_path="${brenn_app_dir}/.lock"
	exec 9>"$lock_path"
	if ! flock 9; then
		brenn_app_note "could not take the payload store lock at ${lock_path}"
		return 1
	fi
	BRENN_APP_LOCK_HELD=yes
	export BRENN_APP_LOCK_HELD
}

# Run a cleanup command when the calling shell exits, a signal included. A trap
# on a signal replaces what the signal would have done, so after cleaning up
# the signal is raised again with its default action: the program still ends,
# and ends as killed by that signal, which is what a service manager stopping
# it expects to see.
# shellcheck disable=SC2064  # the traps are built now; the command's own variables expand when they fire
brenn_app_on_exit() {
	trap "$1" EXIT
	for on_exit_sig in HUP INT TERM; do
		trap "$1; trap - EXIT ${on_exit_sig}; kill -${on_exit_sig} \$\$" "$on_exit_sig"
	done
}

# Remove the downloads and uploads that a fetch or a bake killed before its
# own cleanup left in the RAM store. Each is the size of a payload, and the
# store is capped, so every writer sweeps them rather than only the next of its
# kind. The caller holds the store lock, so none of them is still being
# written.
brenn_app_sweep() {
	rm -f -- "${brenn_app_dir}"/.download.* "${brenn_app_dir}"/.bake.*
}

# Unpack an archive into releases/<release-id> and make it current. On any
# failure the directory this call created is removed and the call returns
# nonzero, so a half-unpacked tree is never left to be mistaken for a payload
# — except the tree `current` names: an activate step that fails after its
# switch has made it the payload that runs, and removing it would leave
# `current` naming nothing.
#
# The directory is created rather than reused: a name already taken is a
# second writer in a store that is supposed to have one, and unpacking into
# somebody else's tree is how two payloads become one that matches neither
# digest. A refused mkdir touches nothing.
#
# The caller holds the store lock, taken with brenn_app_lock.
brenn_app_install() {
	install_archive=$1
	install_dir="${brenn_app_dir}/releases/${2}"

	if ! mkdir -- "$install_dir"; then
		brenn_app_note "could not make a release directory at ${install_dir}"
		return 1
	fi

	# Ownership comes from this side, not from whoever built the archive: the
	# payload is read-only to the account that runs it.
	if ! tar -xf "$install_archive" -C "$install_dir" --no-same-owner --no-same-permissions; then
		brenn_app_note "could not unpack the payload"
		rm -rf -- "$install_dir"
		return 1
	fi

	if ! "${brenn_app_activate:?brenn_app_activate is not set}" "$install_dir"; then
		if [ "$(readlink -- "${brenn_app_dir}/current" 2>/dev/null || :)" = "releases/${2}" ]; then
			brenn_app_note "${2} is current, but its activation did not finish"
		else
			rm -rf -- "$install_dir"
		fi
		return 1
	fi

	return 0
}
