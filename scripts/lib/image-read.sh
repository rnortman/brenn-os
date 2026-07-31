# Readers for a built image. Source, don't execute.
#
# An image is read as a file — the partition table with sfdisk, an ext4
# filesystem with debugfs at a byte offset — so nothing here loop-mounts and
# nothing needs root.
#
# Two callers decode the same formats: the image test suite, which asserts what
# shipped, and the cross-lane manifest, which records it so two lanes can be
# held to building the same product. The decoders live here because a second
# copy of one is a way for those two to read the same image differently and for
# the comparison to agree with nobody.
#
# Nothing here ends a test or exits a script: every function prints its answer
# and reports by status, leaving each caller to decide whether a missing tool is
# a skip or a refusal.

# shellcheck shell=bash

# The shipped package database, as the reducer addresses it. Image assembly
# moves /var aside and mounts a RAM-backed overlay over it, so what describes
# the installed set lives in the read-only lower half rather than at
# /var/lib/dpkg. The image suite reaches the same file through the profile's
# own EXPECT_VAR_LOWERDIR, because where the lower half is mounted is one of
# the things that suite exists to assert.
#
# shellcheck disable=SC2034  # read by a sourcing script, which the linter cannot see
imgread_dpkg_status_path=/usr/share/factory/var/lib/dpkg/status

# The version the build stamped on an image, out of the description the layout
# writes beside it. Canonical: callers that need this field must read it through
# here so they cannot disagree. Empty output with a zero status is a description
# that records no version, which is a caller's decision to make.
imgread_image_version() {
	local desc=$1
	[ -f "$desc" ] || return 1
	sed -n 's/^[[:space:]]*"IGconf_image_version"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$desc" |
		head -n1
}

# An e2fsprogs tool by name. They install into /sbin on some distributions and
# /usr/sbin on others, and neither is always on a non-root PATH, so this looks
# rather than assuming.
imgread_find_tool() {
	local candidate
	for candidate in "$1" "/usr/sbin/$1" "/sbin/$1"; do
		if command -v -- "$candidate" >/dev/null 2>&1; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

imgread_debugfs() {
	imgread_find_tool debugfs
}

# An sfdisk dump, normalised: a `table` line carrying the geometry, then one
# `partition` line per entry in table order, values unquoted and unpadded.
#
#   table label=gpt sector-size=512 first-lba=2048 last-lba=31266782
#   partition 1 name=config start=8192 size=131072 type=<uuid> attrs=
#
# Generated identifiers are dropped: the table id and each partition uuid are
# minted per build, so nothing that compares two builds can carry them. The
# partition type is a constant naming a kind of partition and is kept, and so are
# the GPT attribute bits — a lane that marked a different partition bootable
# would otherwise compare as having built the same image. Several attributes are
# separated by spaces in the dump and by commas here, so that the normalised line
# stays one field per value.
#
# A dump that states no sector size is a 512-byte one, which is sfdisk's own
# default; the value is supplied here rather than by each caller, so that a
# caller recording the table and a caller reading a filesystem out of it cannot
# resolve the same offset differently.
#
# The form is space-separated, so a partition name containing whitespace cannot
# be represented — that is refused rather than silently truncated, since a
# truncated name is a filesystem read at the wrong offset. A quoted value
# containing the separator this splits on truncates the same way and is refused
# the same way: an unbalanced quote in a field is what that looks like here.
imgread_table() {
	printf '%s\n' "$1" | awk '
		/^label:/ { label = $2 }
		/^sector-size:/ { sector = $2 }
		/^first-lba:/ { first = $2 }
		/^last-lba:/ { last = $2 }
		/: start=/ {
			n++
			sub(/^[^:]*: /, "")
			start = ""; size = ""; type = ""; name = ""; attrs = ""
			fields = split($0, f, ",")
			for (i = 1; i <= fields; i++) {
				kv = f[i]
				gsub(/^[ \t]+|[ \t]+$/, "", kv)
				quotes = gsub(/"/, "\"", kv)
				if (quotes % 2 == 1) {
					print "image-read: partition field is cut by a comma inside quotes: " kv > "/dev/stderr"
					bad = 1
				}
				eq = index(kv, "=")
				if (eq == 0) continue
				k = substr(kv, 1, eq - 1)
				v = substr(kv, eq + 1)
				gsub(/^[ \t"]+|[ \t"]+$/, "", v)
				if (k == "start") start = v
				else if (k == "size") size = v
				else if (k == "type") type = v
				else if (k == "name") name = v
				else if (k == "attrs") { gsub(/[ \t]+/, ",", v); attrs = v }
			}
			if (name ~ /[ \t]/) {
				print "image-read: partition name contains whitespace: " name > "/dev/stderr"
				bad = 1
			}
			parts[n] = sprintf("partition %d name=%s start=%s size=%s type=%s attrs=%s", n, name, start, size, type, attrs)
		}
		END {
			if (bad) exit 1
			if (sector == "") sector = 512
			printf "table label=%s sector-size=%s first-lba=%s last-lba=%s\n", label, sector, first, last
			for (i = 1; i <= n; i++) print parts[i]
		}
	'
}

# One `key=value` out of a normalised line. Matching is on a whole field, so
# `size` cannot pick up `sector-size`, and a field that is present but empty
# reads as empty rather than as the next field along.
imgread_field() {
	local line=$1 key=$2 tok
	local -a toks=()
	read -r -a toks <<<"$line"
	for tok in "${toks[@]}"; do
		case "$tok" in
			"${key}="*)
				printf '%s' "${tok#"${key}="}"
				return 0
				;;
		esac
	done
	return 1
}

# Where a named partition starts, in bytes, out of a normalised table — so a
# caller recording the table and a caller reading a filesystem out of the same
# image resolve the offset the same way.
imgread_part_offset_bytes() {
	local table=$1 want=$2 line sector="" start="" name
	while IFS= read -r line; do
		case "$line" in
			"table "*)
				sector=$(imgread_field "$line" sector-size) || return 1
				;;
			"partition "*)
				name=$(imgread_field "$line" name) || continue
				[ "$name" = "$want" ] || continue
				start=$(imgread_field "$line" start) || return 1
				;;
		esac
	done <<<"$table"
	[ -n "$sector" ] && [ -n "$start" ] || return 1
	printf '%s' "$((start * sector))"
}

# What a dpkg status database says shipped, as "<name> <version>" per stanza.
# A stanza that was never unpacked carries no version and did not ship.
#
# Independent of any image reader so the host lane can hold it to its rules
# without an image: every verdict about the package set is only as good as
# this parsing.
imgread_dpkg_installed() {
	printf '%s\n' "$1" | awk '
		/^Package: / { pkg = $2; ver = ""; ok = 0 }
		/^Status: / { ok = ($0 ~ / installed$/) }
		/^Version: / { ver = $2 }
		/^$/ { if (ok && pkg != "" && ver != "") print pkg, ver; pkg = ""; ver = ""; ok = 0 }
		END { if (ok && pkg != "" && ver != "") print pkg, ver }
	'
}

# Every stanza as "<name> <status>", whatever the status says — a different
# question from what is installed, since a package whose removal was refused
# stays installed and says so in a status nobody reads unless it is asserted on.
#
# Continuation lines are indented, so a keyword match anchored at the start of a
# line cannot pick one up out of a description.
imgread_dpkg_statuses() {
	printf '%s\n' "$1" | awk '
		/^Package: / { pkg = $2; st = "" }
		/^Status: / { st = substr($0, length("Status: ") + 1) }
		/^$/ { if (pkg != "") print pkg, st; pkg = ""; st = "" }
		END { if (pkg != "") print pkg, st }
	'
}
