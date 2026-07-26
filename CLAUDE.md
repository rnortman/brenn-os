# brenn-os

The Linux OS image for Brenn nodes — read-only-root, A/B-updated appliance
images built from source. Charter, invariants, and scope: `README.md`. Read it
first; the invariants there are binding on every change in this repo.

Product-grade work — write every line as if it ships to a device you cannot
easily get back.

## What must never enter this tree

The images built here run on real devices on a real network, so the repo has a
sharper version of the usual rule:

- **No credentials, keys, certificates, or endpoints.** Not for testing, not
  temporarily, not in an example. Anything unit- or site-specific is injected at
  provisioning time from outside this repo. A file that would need scrubbing
  back out should never have been written.
- **No build output.** Images, root filesystem tarballs, and update bundles are
  gigabyte-scale artifacts of a reproducible build; the build is the source of
  truth, not its output.
- **Nothing that weakens an invariant to make a task easier.** A writable root,
  a password login, or a service that logs to local flash is not a shortcut, it
  is a different product. If an invariant genuinely blocks the work, surface
  that as a decision to make rather than an exception to take.
- **Everything hermetic, repeatable, general.** "General" in this context means
  nothing specific to a particular deployment environment. All configurable
  knobs can have in-repo defaults (or no default if not reasonable default
  exists), but all knobs need to be changable with an out-of-tree or .gitignored
  local overlay. Hermetic/repreatable means versions and hashes are pinned,
  including the toolchain, so that OS builds are repeatable.

## Gates

A commit runs a secret scan over the staged change and then `make check`; a push
scans the range being pushed. Both hooks are wired by `make setup-hooks`, once
per clone. CI independently scans the tree and runs `make check` on every push
and pull request.

Treat the local hooks as the gate and CI as a backstop, not the other way round.
A CI run says nothing about the commit sitting in your working tree.

If a gate blocks a write or a commit, **surface it** — never route around it.
The gate being wrong is a thing that happens and is worth reporting; a bypassed
gate is not recoverable once it has been pushed.

The first package manifest to land here — `Cargo.toml`, `pyproject.toml`,
whatever it is — must carry `license = "Apache-2.0"`. Without it the published
code is technically all-rights-reserved, and it is the single most-repeated
mistake in this ecosystem's release history.

## Bring-up discipline

We bring up hardware and untried OS features by writing a test that **asserts
the behavior we expect and letting it fail**, not by running throwaway probe
commands over SSH. The failure output is the discovery, and once an observed
value is confirmed correct it gets baked into the test, which then stays as a
permanent regression guard.

Guardrail: an unexpected reading gets human review *before* the test is made to
pass. Do not let make-it-green launder an unexpected value into accepted truth.

There is no test runner in this repo yet, so there is nowhere to put such a test
and nothing that would execute one. Whoever brings the first testable thing —
the image builder, most likely — brings the runner and a `check` lane that runs
it, in the same change. Until then this section describes how the work will be
done, not a mechanism you can use today; a test committed with no lane to run it
is worse than no test, because it reads as coverage.

## TODO system

Two pieces that stay in sync:

- `TODO.md` at the repo root — the master list. Each entry has a slug, a
  description, and the deferral context.
- `TODO(slug)` comments in code, marking the spot where the work happens.

Slugs are the join key; adding a TODO requires both halves. Don't use TODOs for
vague aspirations — every TODO describes a concrete thing, in a place where
"done" is obvious.

`TODO.md` is part of a public repository. An entry is public writing: it may
describe the work, but not internal topology, host names, or anything else that
would not otherwise be published.
