# Changelog

All notable changes to brenn-os are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

Nothing has been released. Everything below describes what the repo can do
today; none of it has yet run on hardware.

### Added

- **An image builder, and one profile that builds.**
  `make image PROFILE=reachy` produces an appliance image for a Raspberry Pi CM4
  on the robot-base carrier: read-only root on A/B slots, memory-backed system
  state, a volatile journal, one unprivileged application account with hardware
  access by group, and one writable partition. The build is reproducible — the
  builder, the Debian snapshot, the kernel and the boot firmware are all pinned.
- **Per-device configuration, kept out of the image.** Credentials, keys,
  endpoints, host name and unit identity are a versioned generation on the
  writable partition, selected at boot; the image itself knows no network and no
  identity. One program states what a generation must be, and both the
  workstation and the device run it. `scripts/provision.sh` installs the first
  generation at flash time, and every change after that is a transaction: tried
  for one boot, reverted automatically if the device does not come back.
  Schema: `docs/provisioning.md`.
- **Signed A/B OS updates.** `make bundle` packs a build into a RAUC bundle.
  Installing one writes the slot pair that is not running, which then gets
  exactly one boot to prove itself and rolls back on its own if it does not.
- **Application delivery that costs the flash nothing.** The payload named by
  the provisioning generation is fetched over TLS into RAM, verified against its
  digest and run unprivileged, with a live resync and a development push loop
  that never touch flash. Contract: `docs/app-contract.md`.
- **Appliance behaviour.** Key-only SSH and no other listener, no passwords
  anywhere, logs shipped off the device, wired or wireless networking with a
  network-set clock, an armed hardware watchdog, and no steady-state writes to
  the internal flash.
- **Four test lanes**, in order of what they need: `make check` (no hardware),
  `make image`, `make test-image` against the built image, and `make test-device`
  against a running unit. The device lane is written ahead of the first flash and
  holds a unit to what it does, down to the peripherals, the watchdog counting in
  hardware, an idle minute writing nothing to flash, and the update mechanism
  agreeing with the firmware about which slot is running.
- **Repository scaffolding.** Apache-2.0 license, charter, and TODO ledger;
  secret-scanning commit and push gates wired by `make setup-hooks`; and CI that
  independently scans the tree, runs the gate, builds the image, asserts against
  it, and round-trips an update bundle with a throwaway key.

### Fixed

- **Builds of a commit more than a week old.** The Debian snapshot the root
  filesystem is bootstrapped from is pinned to a timestamp, and a snapshot
  Release file expires about a week after it is made. The waiver for that
  expiry was written in the sources template as an `Options:` field, which a
  deb822 sources file ignores in silence — so the waiver never applied and no
  build of an aged pin succeeded, which is precisely the reproducibility that
  pinning the snapshot exists to buy. The tree now carries a corrected fork of
  the template, held to the builder's own by a host assertion.
- **The `check` lane's privileged cases, in CI.** Its runner restricts
  unprivileged user namespaces through an AppArmor profile, which the lane's
  own assertion caught as a red job rather than letting the cases that need a
  namespace skip quietly. The lane relaxes that restriction for its own job;
  the assertion is unchanged and remains the authority.
