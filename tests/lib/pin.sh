# Reading the apt preferences file that pins archive versions. Source, don't
# execute.
#
# Two lanes read the same pin file — the host lane holds the tracked manifests
# to the kernel pin, the image lane holds the installed versions to every pin.
# A stanza one lane sees and the other misses is a stanza only one of them
# checks, so the parse lives here rather than once per reader.

# shellcheck shell=bash

# The version pins in the preferences file at $1, one stanza per line, as the
# Package: patterns and the pinned version separated by a tab. A `Pin: version`
# with no Package: line above it belongs to no stanza and is dropped.
pin_stanzas() {
	local line pending=""
	while IFS= read -r line; do
		case "$line" in
			'Package: '*) pending=${line#Package: } ;;
			'Pin: version '*)
				[ -n "$pending" ] || continue
				printf '%s\t%s\n' "$pending" "${line#Pin: version }"
				pending=""
				;;
		esac
	done <"$1"
}

# The upstream version inside a Debian version string: the epoch runs to the
# first ':', the revision from the last '-'. 1:6.18.39-1+rpt1 -> 6.18.39, which
# is what the Raspberry Pi archive spells into its kernel package names. Read by
# grammar rather than by slicing today's literal string, so a new epoch or a
# second revision still parses.
pin_upstream_version() {
	local version=${1#*:}
	printf '%s\n' "${version%-*}"
}
