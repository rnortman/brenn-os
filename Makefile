# Repo-root Makefile — the check gate, the tree sweep, and hook wiring.
#
# `check` holds the contents of the gate CI's check job runs, defined here
# rather than inline in the workflow so it is reproducible on a fresh clone. The
# tree sweep is a separate target, and separate in CI too: it scans content, not
# correctness, and answers a different question.

# Recipes run under bash with -e and pipefail, so a failing command anywhere in
# a chain or a pipeline fails the target. Without this a broken enumeration —
# git unavailable, index unreadable — degrades into an empty worklist and a
# green result, which is the worst thing a gate can do.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Repo-root targets:"
	@echo "  make check         the lint gate (shell), same contents CI runs"
	@echo "  make setup-hooks   wire git at .githooks, check tooling (once per clone)"
	@echo "  make scrub-tree    whole-tree secret sweep — the sweep a clean tree is declared on"

# Scripts are enumerated from the index, not from a fixed glob, so a new one
# cannot join the tree unlinted, and the pre-commit run lints exactly what is
# staged. -z plus xargs -0 so a path with whitespace stays one path.
#
# The linter is optional here — a machine without it is not blocked from
# committing — but the skip is loud, and CI pins the linter so the check
# cannot skip its way to merge.
.PHONY: check
check:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
	    echo "check: shellcheck not installed — SHELL LINT SKIPPED (pinned and enforced in CI)"; \
	    exit 0; \
	fi; \
	echo "check: shellcheck on $$(git ls-files '*.sh' .githooks | wc -l) tracked script(s)"; \
	git ls-files -z '*.sh' .githooks | xargs -0 --no-run-if-empty shellcheck

# Wire git at the tracked hooks dir and report any missing tooling. Idempotent;
# run once per clone.
#
# Both scanners are external tools this tree cannot build, so this reports what
# is missing and where to get it rather than installing anything.
.PHONY: setup-hooks
setup-hooks:
	git config core.hooksPath .githooks
	@rm -f .git/hooks/pre-commit
	@command -v brenn-scrub >/dev/null 2>&1 || \
	    echo "brenn-scrub not on PATH — the commit and push gates will not run. Install it from the brenn repo: cargo install --path scrub"
	@command -v gitleaks >/dev/null 2>&1 || \
	    echo "gitleaks not on PATH — install the release brenn-scrub pins (PINNED_VERSION in the brenn repo's scrub crate); it refuses to run against any other."
	@command -v shellcheck >/dev/null 2>&1 || \
	    echo "shellcheck not on PATH — 'make check' will skip the shell lint."
	@echo "setup-hooks: done."

.PHONY: scrub-tree
scrub-tree:
	brenn-scrub tree
