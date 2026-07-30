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
	@echo "  make check         the gate (shell lint, layer metadata, host tests), same contents CI runs"
	@echo "  make image         build an image        (PROFILE=$(PROFILE))"
	@echo "  make bundle        pack the last build into a signed update bundle (PROFILE=$(PROFILE))"
	@echo "                     signing material: see docs/provisioning.md; paths via .local/bundle.conf"
	@echo "  make clean         remove work/ — the build output, its scratch and its caches"
	@echo "  make test-host     assert against the tree — no image, no device"
	@echo "  make test-image    assert against the built image"
	@echo "  make test-device   assert against a live unit over SSH (needs a target)"
	@echo "  make test-clean    assert how 'make clean' would route — reports, removes nothing"
	@echo "  make setup-hooks   wire git at .githooks, check tooling (once per clone)"
	@echo "  make scrub-tree    whole-tree secret sweep — the sweep a clean tree is declared on"

# Everything profile-varying lives in the profile's config and layer, so this
# is the only knob the image targets need.
PROFILE ?= reachy

# Each lane is a script of its own so that it is runnable by itself and reads
# the same way in CI as it does here. Each enumerates its own work from the
# index, so nothing joins the tree unchecked.
.PHONY: check
check:
	@scripts/lint-shell.sh
	@scripts/lint-layers.sh
	@$(MAKE) --no-print-directory test-host

# Building an image is slow and pulls the network, so it is not part of `check`.
.PHONY: image
image:
	scripts/build-image.sh $(PROFILE)

# Packs what `image` produced; does not build. The signing material comes from
# the environment — BRENN_BUNDLE_CERT and BRENN_BUNDLE_KEY, plus an optional
# BRENN_BUNDLE_KEYRING to verify the result against, which defaults to the
# certificate — because no key of any kind is ever in this tree. The same knobs
# can be written once into .local/bundle.conf, which is gitignored and holds
# paths to material kept outside the repo.
.PHONY: bundle
bundle:
	scripts/make-bundle.sh --profile $(PROFILE)

# Reclaims the build area. A build runs inside a user namespace and leaves files
# owned by sub-uids of the invoking user, which a plain `rm -rf work` cannot
# remove, so the removal happens from inside such a namespace. Scratch or an apt
# cache a knob points outside work/ are named and left alone.
.PHONY: clean
clean:
	scripts/clean-work.sh

# The parts of the system that are ordinary programs — the boot-time decisions
# above all — exercised against a temporary tree. No image, no hardware, and
# fast enough to be part of the gate, which is the point: a decision that only
# runs on a device is a decision that only fails on a device.
.PHONY: test-host
test-host:
	tests/run.sh host

# Reads the build output; does not build. Fails rather than passes when there
# is nothing to read.
.PHONY: test-image
test-image:
	BRENN_PROFILE=$(PROFILE) tests/run.sh image

# The bring-up lane: assertions against a real unit, over SSH. Inherently
# local — it needs a provisioned device on the same network — so it is not part
# of `check` and CI never runs it.
#
# Where that device is is site information and never enters the tree: set
# BRENN_DEVICE_HOST (and BRENN_DEVICE_USER, BRENN_DEVICE_SSH_OPTS) or write
# them into .local/device.conf, which is gitignored. Unconfigured, every test
# skips and the runner fails the lane rather than reporting a green run against
# nothing.
.PHONY: test-device
test-device:
	BRENN_PROFILE=$(PROFILE) tests/run.sh device

# What `make clean` resolves and which removal it would start with, asserted
# against the real repo root in dry-run mode — nothing is removed. A lane of its
# own, and deliberately not part of `check`: the gate runs on every commit, and
# the script under assertion is the one that removes the build area, so the gate
# does not call it even to ask what it would do.
#
# TODO(clean-lane-ci): no automated gate runs this lane, here or in CI.
.PHONY: test-clean
test-clean:
	tests/run.sh clean

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
