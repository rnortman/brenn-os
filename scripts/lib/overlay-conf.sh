# The gitignored .local overlay, resolved the same way for every lane that has
# one. Source, don't execute.
#
# Three files carry knobs this way — .local/build.conf, .local/bundle.conf and
# .local/device.conf — under one precedence rule: an exported value is the more
# specific statement of intent and outranks the overlay, which outranks the
# built-in default. A second implementation of that rule is how two lanes come
# to disagree about which value won.
#
# An overlay carries paths and names, never key material: a key under the repo
# root is a file that would need scrubbing back out, gitignored or not.

# shellcheck shell=bash

# overlay_load_conf <conf-file> <NAME>[=<default>]...
#
# Each named variable is left holding the winner, whether or not the file
# exists. The pre-source value is captured first because the file assigns to
# those same names, and that capture is the whole of what keeps an exported
# value ahead of the overlay's.
#
# Empty is not a value here, at either level: a knob exported empty reads as one
# nobody set, and so does one the file assigns nothing to, and in both cases the
# next answer down wins. That is what lets a caller name every knob a tool reads,
# empty, to keep the ambient environment out of a run without also having to know
# each one's default (tests/host/100-build-lane.test.sh does exactly this). The
# cost is that no exported value can mean "empty on purpose"; a tool with a knob
# whose empty value is meaningful needs a flag for it, not a variable.
#
# A name with no `=` defaults to empty, which is how a knob that has to stay
# unset on a host that cannot produce a value is declared.
#
# The locals are prefixed because the file being sourced runs in this function's
# scope and would otherwise be able to shadow them.
overlay_load_conf() {
	local overlay_conf=$1
	shift
	local overlay_spec overlay_name overlay_default overlay_i

	local -a overlay_saved=()
	for overlay_spec in "$@"; do
		overlay_name=${overlay_spec%%=*}
		overlay_saved+=("${!overlay_name-}")
	done

	if [ -f "$overlay_conf" ]; then
		# shellcheck disable=SC1090  # a local overlay, absent from the tree
		. "$overlay_conf"
	fi

	overlay_i=0
	for overlay_spec in "$@"; do
		overlay_name=${overlay_spec%%=*}
		overlay_default=''
		[ "$overlay_spec" = "$overlay_name" ] ||
			overlay_default=${overlay_spec#*=}
		printf -v "$overlay_name" '%s' \
			"${overlay_saved[overlay_i]:-${!overlay_name:-${overlay_default}}}"
		overlay_i=$((overlay_i + 1))
	done
}
