#!/usr/bin/env bash
#
# Lint every shell script in the tree.
#
# "Every" is the point: scripts installed into an image are named for the
# command they provide, not for the language they are written in, so a glob on
# *.sh would quietly leave the ones that run on the device unlinted. What is
# enumerated is therefore tracked files that start with a shell shebang, plus
# the *.sh files that are sourced libraries and have no shebang at all.
#
# Enumerated from the index rather than the working tree, so a new script
# cannot join the tree unlinted, and the pre-commit run lints what is staged.
#
# The linter is optional here — a machine without it is not blocked from
# committing — but the skip is loud, and CI pins the linter so the check cannot
# skip its way to merge.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "lint-shell: shellcheck not installed — SHELL LINT SKIPPED (pinned and enforced in CI)"
	exit 0
fi

scripts=()
while IFS= read -r -d '' f; do
	# A symlink to a script is the same script under a second name — a program
	# installed into the image under /usr/lib and put on the path as well. It is
	# linted where it really lives: from the link's directory, the siblings it
	# sources are not there, and the linter reports a file it cannot follow.
	if [ -L "$f" ]; then
		continue
	fi
	scripts+=("$f")
done < <(
	{
		git ls-files -z '*.sh' .githooks
		# A shebang on the first line, naming any shell. Read with `head` so a
		# tracked binary is not slurped in its entirety looking for one.
		git ls-files -z | while IFS= read -r -d '' f; do
			case "$(head -c 128 -- "$f" 2>/dev/null | head -n1)" in
				'#!'*sh | '#!'*sh' '*) printf '%s\0' "$f" ;;
			esac
		done
	} | sort -zu
)

if [ ${#scripts[@]} -eq 0 ]; then
	echo "lint-shell: no shell scripts found — nothing to lint"
	exit 0
fi

echo "lint-shell: ${#scripts[@]} script(s)"
shellcheck -- "${scripts[@]}"
