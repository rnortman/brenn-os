# Changelog

All notable changes to brenn-os are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

Nothing has been released. Everything below describes what the repo can do
today; none of it has yet run on hardware.

### Added

- **The payload fetch presents a per-unit client certificate.**
  `app/client.crt` and `app/client.key` join the generation, required with
  `app/fetch.conf` and refused without it; `brenn-app-fetch` presents them, so
  a payload server may require client authentication and a payload may carry
  the unit's secrets. `inputs/client.{crt,key}` are demanded by the assembler
  exactly when `APP_URL` is set.
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
  What a site has not stood up yet, it does not have to name: a local time
  server, a log collector, an application payload and the HTTPS trust anchor
  they are verified against are optional, and a device provisioned without one
  boots, joins the network, answers SSH and takes updates without that piece.
  Configuring an endpoint without an anchor to verify it is refused, since this
  image carries no certificate store of its own.
  `scripts/assemble-generation.sh` builds a generation from a unit's plain-text
  configuration and an operator store of secrets that never enters this public
  tree: it generates the unit's identity once and reuses it on every later
  assembly, derives the wireless key without the passphrase ever reaching a
  command line, refuses every input a device could not use rather than one at a
  time, and hands the result to the contract check before calling it assembled.
  `docs/provisioning.md` is the whole of it: the schema, the unit
  configuration's keys, the operator store's layout and what in it is generated
  once, where that store may live and what each choice costs, and the single
  `openssl` command that creates the update-signing keypair.
- **More than one wireless network per unit.** A generation may carry the
  network a unit lives on plus every other one it has to be able to join — a
  phone hotspot, the wifi wherever it is being taken. One file per network in
  the operator store's `inputs/wifi.d/`, each with its own key derivation, its
  own hidden-network flag and its own priority, and the supplicant chooses
  among them. Nothing on the device changed: it already accepted several
  networks in a generation.
- **A unit is findable on a network nobody here runs.** The device answers its
  provisioned name over multicast DNS on both links, so a laptop on the same
  phone hotspot or the same visited wifi reaches it as
  `ssh root@<hostname>.local` with nothing configured on either side. It answers
  only for itself and advertises no service; the charter's listener invariant is
  amended to admit exactly that, and the device lane now censuses UDP sockets as
  well as TCP so the exception cannot quietly grow. `docs/provisioning.md`
  covers the pre-trip check, the one network layout that defeats this and every
  alternative to it, and the IPv6 link-local fallback.
- **Signed A/B OS updates.** `make bundle` packs a build into a RAUC bundle.
  Installing one writes the slot pair that is not running, which then gets
  exactly one boot to prove itself and rolls back on its own if it does not.
- **Application delivery that costs the flash nothing.** The payload named by
  the provisioning generation is fetched over TLS from a provisioned server into
  RAM and run unprivileged, with a live resync and a development push loop that
  never touch flash. Contract: `docs/app-contract.md`.
- **Appliance behaviour.** Key-only SSH with no listener beside it but the
  name responder, no passwords anywhere, logs shipped off the device, wired or wireless networking with a
  network-set clock, an armed hardware watchdog, and no steady-state writes to
  the internal flash.
- **Four test lanes**, in order of what they need: `make check` (no hardware),
  `make image`, `make test-image` against the built image, and `make test-device`
  against a running unit. The device lane is written ahead of the first flash and
  holds a unit to what it does, down to the peripherals, the watchdog counting in
  hardware, an idle minute writing nothing to flash, and the update mechanism
  agreeing with the firmware about which slot is running.
- **A way to get an image onto a device, and a copy of what was there first.**
  `docs/install.md` is the first-install and disaster-recovery runbook —
  flashing mode, backup, write, provision, first boot, and what to do when a
  unit does not come back — and `scripts/flash.sh` is the tool for the two steps
  that destroy something. It identifies the target before it touches it and
  refuses rather than warns: a whole disk, on USB, reporting the mass-storage
  gadget's model, with nothing mounted off it and room for the image. A backup
  is verified by reading the device a second time and comparing that against the
  stored archive, and a write is verified by reading it back off the medium;
  either mismatch fails the run rather than reporting success. The procedure
  itself has not yet been performed on hardware.
- **Repository scaffolding.** Apache-2.0 license, charter, and TODO ledger;
  secret-scanning commit and push gates wired by `make setup-hooks`; and CI that
  independently scans the tree, runs the gate, builds the image, asserts against
  it, and round-trips an update bundle with a throwaway key.
- **Baked mode: an application that runs with no network.**
  `ssh root@<unit> brenn-app-bake < payload.tar.zst` checks a payload in RAM,
  and only once it has passed writes the archive and its digest to the
  persistent partition. Every boot after that verifies the stored archive and
  runs it from RAM with no network and no operator, ahead of any payload the
  provisioning names. Development pushes and resyncs still replace the running
  payload in RAM only; `brenn-app-stage` goes back to the baked one without a
  reboot, and `brenn-app-unbake` leaves baked mode.

### Changed

- **The application fetch pins a URL and a trust anchor, not a digest.**
  `app/fetch.conf` is `URL=` alone; a `SHA256=` line is refused by the
  validator and by the fetch, and `APP_SHA256` is no longer a `unit.conf`
  key. A release is a publish to the served address and a
  `brenn-app-resync` (or the next boot), not a provisioning transaction.
  The baked digest is unchanged: it is computed on the device and answers
  for flash, not for a generation.
- **The pinned Raspberry Pi kernel, 6.18.39 to 6.18.50** (`1:6.18.50-1+rpt1`),
  **and the boot firmware, `1:1.20260521-3` to `1:1.20260915-1`.** The same
  drift as the last bump: the archive superseded the kernel metapackage and
  `raspi-firmware` in place, the pins matched nothing the index still offers,
  the current versions installed at default priority, and the image suite
  caught it (`080-package-pins`, `140-package-set`). The versioned 6.18.39
  packages are still published, but holding them would mean installing the
  kernel by versioned name instead of through the metapackage — the route the
  last bump refused, for the same reason. The package set is otherwise
  unchanged: the only manifest lines that move are the two that spell the
  kernel version.
- **The pinned Raspberry Pi kernel, 6.18.34 to 6.18.39** (`1:6.18.39-1+rpt1`).
  That archive supersedes its kernel metapackage in place and publishes no
  snapshot service, so the pinned version stopped being offered under the name
  the build installs. An apt pin can only prioritise a version the index still
  carries: with nothing to match, the archive's current kernel installed at its
  default priority and the build succeeded without saying anything. The image
  suite caught the drift, which is what it is for, and the bump is the
  deliberate act the pin file asks for rather than a silent fall-forward.
  Holding 6.18.34 was considered and refused — it needs the kernel metapackage
  abandoned for versioned package names, a second fork of builder content, to
  buy the same failure again whenever the archive drops those names too.
  The pin and the package manifest are now held to the same kernel by `make
  check`, so a bump that edits one and not the other fails at the commit hook
  instead of after a build.

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
- **The provisioning command `scripts/flash.sh` prints after a write.** It
  re-reads the partition table and looks for the partition labelled
  `persistent`, but that label reaches `lsblk` out of the udev database, which
  udev workers fill in asynchronously as each new partition node appears — so a
  query issued the instant the table was read saw every path with an empty
  label and matched none of them. On any host running udev the tool therefore
  took its fallback branch, which recommended
  `/dev/disk/by-partlabel/persistent`: the one name `docs/install.md` tells the
  operator not to use, because on a workstation holding more than one such
  medium it names an arbitrary one of them. The lookup now waits for udev,
  bounded, before it asks, and neither branch names that path — without a label
  the tool prints the command that finds the partition on the device it just
  wrote. Which branch prints, and what each says, are now asserted.
- **The on-device listener check's UDP half, on first hardware run.** The
  device test that confirms which network ports a unit has open was written
  before any unit had run it, and its expected UDP sockets were predictions
  that turned out wrong: the device was behaving correctly, the test failed.
  The expected set is now the four sockets actually measured for the local
  name resolver. The DHCP client's sockets are
  handled separately, because their address depends on the lease, the unit's
  hardware address and how many links are up. They are accepted by owner, port
  and kind of address rather than by exact address, so a stray service on
  those ports still fails. New host tests cover the matching rules.
