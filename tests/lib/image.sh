# Helpers for reading a built image. Source, don't execute.
#
# Everything here reads the image file directly — partition table via sfdisk,
# vfat contents via mtools at a byte offset. Nothing loop-mounts and nothing
# needs root, so the image suite runs the same way on a workstation as in CI.
#
# The decoders for the formats the cross-lane manifest also reads — the sfdisk
# dump, the ext4 reader's location, the dpkg database — come from
# scripts/lib/image-read.sh. What is added here is the suite's half: skipping
# and failing, the expectations, and the readers that only an assertion wants.

# shellcheck shell=bash

# shellcheck source=scripts/lib/image-read.sh
. "${BRENN_REPO_ROOT}/scripts/lib/image-read.sh"

# Expected values per profile live next to the tests, so an assertion failure
# points at one file to reconcile against the hardware.
img_load_expectations() {
	local f="${BRENN_REPO_ROOT}/tests/image/expected-${BRENN_PROFILE}.env"
	[ -f "$f" ] || t_skip "no expectations for profile '${BRENN_PROFILE}'"
	# shellcheck disable=SC1090  # path is profile-dependent by design
	. "$f"
}

# Resolve the image the build wrote into IMG. BRENN_IMAGE overrides, which is
# how a local overlay points the suite at an image built somewhere else.
#
# Sets a variable rather than printing one: skipping has to end the test, and
# an exit from a command substitution only ends the substitution.
img_resolve() {
	if [ -n "${BRENN_IMAGE:-}" ]; then
		[ -f "$BRENN_IMAGE" ] || t_skip "BRENN_IMAGE is set but ${BRENN_IMAGE} does not exist"
		IMG=$BRENN_IMAGE
		return
	fi
	IMG="${BRENN_REPO_ROOT}/work/image-${EXPECT_IMAGE_NAME}/${EXPECT_IMAGE_NAME}.img"
	[ -f "$IMG" ] || t_skip "no built image at ${IMG} — run: make image PROFILE=${BRENN_PROFILE}"
}

# The opening every image test shares: the profile's expectations, the image
# itself, and its partition table. Called at top level, because the skips it
# can reach have to end the test rather than a function.
img_open() {
	img_load_expectations
	img_resolve
	img_read_table "$IMG"
}

# The same, plus IMG_SPEC: the handle for reading the root filesystem. Reading
# slot A stands for both — 015 is what holds the two slots identical, so every
# other test asserts against one of them.
img_open_system_root() {
	img_open
	img_require_ext4
	if ! IMG_SPEC=$(img_ext4_spec "$IMG" system_a); then
		t_fail "locate the system_a partition"
		t_done
	fi
}

# Fills IMG_SECTOR_SIZE and the parallel arrays IMG_PART_NAME / IMG_PART_START /
# IMG_PART_SIZE, all in partition-table order, from the normalised table the
# manifest is recorded from.
img_read_table() {
	local img=$1 line sector
	t_require_cmd sfdisk

	IMG_SECTOR_SIZE=512
	IMG_PART_NAME=()
	IMG_PART_START=()
	IMG_PART_SIZE=()

	while IFS= read -r line; do
		case "$line" in
			"table "*)
				# The decoder supplies the 512-byte default when a dump
				# states no sector size, so both readers of one image
				# resolve the same offsets.
				sector=$(imgread_field "$line" sector-size) || sector=
				[ -z "$sector" ] || IMG_SECTOR_SIZE=$sector
				;;
			"partition "*)
				IMG_PART_START+=("$(imgread_field "$line" start)")
				IMG_PART_SIZE+=("$(imgread_field "$line" size)")
				IMG_PART_NAME+=("$(imgread_field "$line" name)")
				;;
		esac
	done < <(imgread_table "$(sfdisk --dump "$img" 2>/dev/null)")

	if [ ${#IMG_PART_NAME[@]} -eq 0 ]; then
		t_fail "read the partition table from ${img}"
		t_done
	fi
}

img_part_index() {
	local want=$1 i
	for i in "${!IMG_PART_NAME[@]}"; do
		if [ "${IMG_PART_NAME[$i]}" = "$want" ]; then
			printf '%s' "$i"
			return 0
		fi
	done
	return 1
}

img_part_offset_bytes() {
	local i
	i=$(img_part_index "$1") || return 1
	printf '%s' "$((IMG_PART_START[i] * IMG_SECTOR_SIZE))"
}

# Read one file out of a vfat partition, by partition name. Trailing carriage
# returns are stripped: these files are edited on both kinds of host.
#
# Usually called in a command substitution, so it reports by exit status only —
# an assertion helper called from a subshell would count into a lost copy of
# the failure counter.
img_vfat_cat() {
	local img=$1 part=$2 path=$3 offset
	offset=$(img_part_offset_bytes "$part") || return 1
	MTOOLS_SKIP_CHECK=1 mtype -i "${img}@@${offset}" "::${path}" | tr -d '\r'
}

# Locate the ext4 reader and set IMG_DEBUGFS.
#
# Called at top level for the same reason img_resolve is: skipping has to end
# the test, which it cannot do from inside a command substitution.
img_require_ext4() {
	IMG_DEBUGFS=$(imgread_debugfs) ||
		t_skip "requires debugfs (e2fsprogs), which is not installed"
}

# The debugfs handle for a named ext4 partition: the image file plus a byte
# offset. Same posture as the vfat reader — the image is read as a file, so
# nothing loop-mounts and nothing needs root.
img_ext4_spec() {
	local img=$1 part=$2 offset
	offset=$(img_part_offset_bytes "$part") || return 1
	printf '%s?offset=%s' "$img" "$offset"
}

# debugfs reports a missing path on stderr and still exits 0, so callers check
# existence rather than status. Its stdin is closed: called from inside a loop
# reading a directory listing, a tool that consumes stdin eats the listing.
img_ext4_request() {
	"$IMG_DEBUGFS" -R "$2" "$1" 2>/dev/null </dev/null
}

img_ext4_stat() {
	img_ext4_request "$1" "stat $2"
}

img_ext4_exists() {
	img_ext4_stat "$1" "$2" | grep -q '^Inode:'
}

img_ext4_cat() {
	img_ext4_exists "$1" "$2" || return 1
	img_ext4_request "$1" "cat $2"
}

# Directory entries, one name per line, without the . and .. entries. The
# `ls -p` format is /inode/mode/uid/gid/name/len/.
img_ext4_ls() {
	img_ext4_exists "$1" "$2" || return 1
	img_ext4_request "$1" "ls -p $2" |
		awk -F/ 'NF >= 7 && $6 != "." && $6 != ".." { print $6 }'
}

# Where a symlink points. A target short enough is held in the inode; one that
# is not is stored in a block like a file's content and read the same way. The
# type is checked before falling back, so that reading a regular file cannot
# pass for reading a link.
img_ext4_link() {
	local dest
	dest=$(img_ext4_stat "$1" "$2" | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p')
	if [ -z "$dest" ]; then
		[ "$(img_ext4_type "$1" "$2")" = symlink ] || return 1
		dest=$(img_ext4_request "$1" "cat $2")
	fi
	[ -n "$dest" ] || return 1
	printf '%s' "$dest"
}

# The inode type debugfs reports: regular, directory, symlink, ...
img_ext4_type() {
	img_ext4_stat "$1" "$2" | sed -n '1s/.*Type: \([a-z]*\).*/\1/p'
}

# Permission bits, as three or four octal digits without the leading zero.
img_ext4_mode() {
	img_ext4_stat "$1" "$2" |
		sed -n '1s/.*Mode: *0*\([0-7][0-7][0-7][0-7]*\).*/\1/p'
}

# Installed packages as "<name> <version>", one per line. The package database
# lives under the baked /var — the read-only lower half of the /var overlay —
# because image assembly moves /var itself aside.
img_installed_packages() {
	local status
	status=$(img_ext4_cat "$1" "${EXPECT_VAR_LOWERDIR}/lib/dpkg/status") || return 1
	[ -n "$status" ] || return 1
	imgread_dpkg_installed "$status"
}

# Every stanza in the shipped package database as "<name> <status>", whatever
# the status says. The reader above answers "what is installed"; this answers
# "what does the database record", which is a different question — a package
# whose removal was refused stays installed and says so in a status nobody
# reads unless it is asserted on.
img_package_statuses() {
	local status
	status=$(img_ext4_cat "$1" "${EXPECT_VAR_LOWERDIR}/lib/dpkg/status") || return 1
	[ -n "$status" ] || return 1
	imgread_dpkg_statuses "$status"
}

# Every enablement link in the image, as "<target>.wants/<unit>", one per line.
# A unit runs because something wants it, and what wants it is a symlink in a
# directory named for the target — which is how a package's install-time preset
# adds a service to every boot without anything in this repository saying so.
img_enabled_units() {
	local spec=$1 dir=$2 entry unit
	while IFS= read -r entry; do
		case "$entry" in
			*.wants | *.requires) ;;
			*) continue ;;
		esac
		[ "$(img_ext4_type "$spec" "${dir}/${entry}")" = directory ] || continue
		while IFS= read -r unit; do
			[ -n "$unit" ] || continue
			printf '%s/%s\n' "$entry" "$unit"
		done < <(img_ext4_ls "$spec" "${dir}/${entry}")
	done < <(img_ext4_ls "$spec" "$dir")
}

# Paths under <dir> in the root filesystem whose contents contain <needle>, one
# per line, descending <depth> levels. The sweep is how "no file reads the
# store directly" is asserted: naming the offenders is worth more than a count,
# since the answer is either empty or a list to go and fix.
img_sweep_for_string() {
	local dir=$1 needle=$2 depth=${3:-2} name path type content
	[ "$depth" -gt 0 ] || return 0
	while IFS= read -r name; do
		path="${dir}/${name}"
		type=$(img_ext4_type "$IMG_SPEC" "$path")
		case "$type" in
			directory) img_sweep_for_string "$path" "$needle" $((depth - 1)) ;;
			regular)
				content=$(img_ext4_cat "$IMG_SPEC" "$path") || continue
				if printf '%s' "$content" | grep -qF "$needle"; then
					printf '%s\n' "$path"
				fi
				;;
		esac
	done < <(img_ext4_ls "$IMG_SPEC" "$dir")
}

# Copy a directory tree out of the root filesystem into an existing host
# directory, which lands as <dest>/<basename of dir>. A whole-subtree question —
# "is there a key anywhere under /etc" — costs one reader invocation this way
# instead of one per file, and is then answered with find and grep.
img_ext4_rdump() {
	img_ext4_request "$1" "rdump $2 $3"
	[ -e "${3}/$(basename "$2")" ]
}

# Every `Key=value` for one key in an ini-style file's content, one per line.
# systemd merges repeated Before=/After= declarations rather than replacing
# them, so an assertion about ordering has to read all of them.
img_ini_values() {
	printf '%s\n' "$1" |
		sed -n "s/^[[:space:]]*${2}=[[:space:]]*//p" |
		sed 's/[[:space:]]*$//'
}

# An sshd configuration file's lines with its includes spliced in where they
# appear, which is where sshd reads them. Only the `<dir>/*.conf` form is
# expanded — the form the distribution ships — and any other include is left as
# a line, so a change in shape shows up as an unresolved keyword rather than as
# a silently different answer.
img_sshd_lines() {
	local spec=$1 path=$2 content line lower pattern dir base entry
	content=$(img_ext4_cat "$spec" "$path") || return 1
	while IFS= read -r line; do
		lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
		case "$lower" in
			include[[:space:]]*) ;;
			*)
				printf '%s\n' "$line"
				continue
				;;
		esac
		pattern=$(printf '%s\n' "$line" | awk '{print $2}')
		dir=${pattern%/*}
		base=${pattern##*/}
		if [ "$base" != '*.conf' ]; then
			printf '%s\n' "$line"
			continue
		fi
		while IFS= read -r entry; do
			case "$entry" in
				*.conf) ;;
				*) continue ;;
			esac
			img_ext4_cat "$spec" "${dir}/${entry}" || true
		done < <(img_ext4_ls "$spec" "$dir" | sort)
	done <<<"$content"
}

# The keyword each configuration line sets, lower-cased, one per line, blank
# for a line that sets nothing. sshd accepts both `Keyword value` and
# `Keyword=value`, so the separator is normalised here rather than in each
# caller — a drop-in written in the second form would otherwise be invisible to
# everything that reads the resolved configuration.
img_sshd_keywords() {
	printf '%s\n' "$1" | awk '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line ~ /^[A-Za-z0-9]+=/) sub(/=/, " ", line)
			n = split(line, f, /[ \t]+/)
			print (n > 0 && f[1] !~ /^#/) ? tolower(f[1]) : ""
		}
	'
}

# The effective value of one sshd keyword: keywords are case-insensitive and
# the *first* value obtained wins, which is the opposite of how systemd
# resolves a drop-in and the reason this is read rather than assumed.
#
# This reads the global section. sshd also honours Match blocks, which override
# it per connection; callers assert separately that the image ships none, since
# a resolver that ignored one would report a configuration nobody connects with.
img_sshd_value() {
	printf '%s\n' "$1" | awk -v key="$2" '
		BEGIN { key = tolower(key) }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line ~ /^[A-Za-z0-9]+=/) sub(/=/, " ", line)
			n = split(line, f, /[ \t]+/)
			if (n < 1 || tolower(f[1]) != key) next
			sub(/^[^ \t]+[ \t]*/, "", line)
			sub(/[ \t]+$/, "", line)
			print line
			exit
		}
	'
}

# One `Key=value` from inside one `[section]`, last occurrence within it wins.
#
# Needed wherever the same key means different things in different sections —
# four slot sections each naming a `device=` — which a whole-file reader would
# answer with whichever section happened to come last.
img_ini_section_value() {
	printf '%s\n' "$1" | awk -v want="[$2]" -v key="$3" '
		/^[[:space:]]*\[/ {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]+$/, "", line)
			section = line
			next
		}
		section == want {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			if (index(line, key "=") == 1) {
				value = substr(line, length(key) + 2)
				sub(/^[[:space:]]+/, "", value)
				sub(/[[:space:]]+$/, "", value)
			}
		}
		END { if (value != "") print value }
	'
}

# One `Key=value` out of an ini-style file's content, last occurrence wins,
# which is how systemd resolves a repeated key within a file.
img_ini_value() {
	printf '%s\n' "$1" |
		sed -n "s/^[[:space:]]*${2}=[[:space:]]*//p" |
		sed 's/[[:space:]]*$//' | tail -n1
}
