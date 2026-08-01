# Reading a tracked package manifest. Source, don't execute.
#
# Multiple test lanes read the same manifest files. They must parse them
# identically — an entry one lane strips and the other keeps is an entry only
# one of them checks — so the rule lives here rather than once per reader.

# shellcheck shell=bash

# The package names in the manifest at $1, one per line, sorted and
# deduplicated: comments removed, surrounding whitespace trimmed, blank lines
# dropped.
#
# Whitespace inside a line is left where it is. A package name cannot contain
# one, so a line holding a space is a typo in a file the project treats as
# reviewed truth; closing the gap would turn it into a name nobody wrote and
# hand every reader downstream a package that does not exist.
manifest_entries() {
	sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" |
		grep -v '^$' | sort -u
}
