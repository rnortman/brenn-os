# brenn-os

The Linux operating-system image for Brenn nodes — appliance-class devices and
the hosts that serve them, built from source as one declarative image family.

## What this is

Brenn is a self-hosted AI assistant and smart-home ecosystem. The smart-home
side of that includes a family of devices, in-house firmware, and a homelab
backend. Its MCU-class devices run bare-metal Rust firmware (`brenn-pod`). Its
Linux-class devices need something else — a real operating system, built the
same way the firmware is: from source, in CI, reproducibly, with nothing
installed that nobody chose.

This repo is that image. It replaces the vendor OS on each supported device
entirely rather than layering onto it.

The immediate driver is a robot base — a Raspberry Pi CM4 carrier whose shipped
image is a general-purpose desktop Linux with a vendor Python stack. What it
needs is an appliance: a read-only root filesystem, a handful of services,
atomic updates, and no interactive users.

## Design invariants

Every image this repo builds, on every device and every storage medium, holds
these. They are what makes an image an appliance rather than a small server:

- **Read-only root, A/B slots.** Two root partitions; an update writes the idle
  one and the bootloader flips to it atomically, rolling back by itself if the
  new slot fails to come up. Updates are signed.
- **Writes confined to a declared data volume.** The root filesystem is
  mounted read-only; the mutable parts of the system tree are memory-backed. A
  profile declares exactly one writable partition and what may live there.
  Steady-state writes to the internal flash are meant to be zero — flash on
  these devices is soldered down and has a finite write budget.
- **Remote-first logging.** Logs stream off the device and are volatile locally,
  which is both a flash-wear measure and the only practical way to debug a
  fleet.
- **Key-only SSH, no default credentials.** No listener other than sshd.
  Nothing ships with a password.
- **Per-unit provisioning stays outside this repo.** Credentials, keys,
  endpoints, and unit identity are injected when a device is provisioned. They
  are never baked into an image and never live here.

## One image family

Profiles differ in their payload — packages, services, hardware configuration,
data-volume size and policy — and in nothing else. The invariants above are not
per-profile. This is a deliberate constraint: an appliance fleet stays
maintainable only while every member is the same kind of thing.

## Relationship to the rest of Brenn

- `brenn-pod` — firmware for the ESP32-class devices, and the host-side
  pipeline they talk to. Release images consume its release binaries and their
  service units; that is the only dependency between the two repos.
- Provisioning, deployment, and the homelab side of the fleet are not in this
  repo.

## Status

Early. The invariants and the image architecture are decided, and one profile
builds. Nothing here has yet run on hardware: what follows is asserted against
the built image and against temporary trees, not against a device.

- **The image.** `make image PROFILE=reachy` produces an A/B image for a
  Raspberry Pi CM4 carrier — read-only root, memory-backed system state, a
  volatile journal, one unprivileged application account, and the carrier's
  hardware reachable by that account through group ownership rather than by
  opening the devices to everyone.
- **Configuration.** The image knows no network and no identity. Per-device
  configuration — wireless credentials, host name, SSH host key and access list,
  log collector, an optional local time server — is a versioned generation on
  the writable partition, selected at boot (`docs/provisioning.md`). What a
  generation has to contain is enforced by one program that both the workstation
  and the device run. `scripts/provision.sh` puts the first one on at flash
  time; every change after that is a transaction on the running device, tried
  for one boot and reverted automatically if the device does not come back.
- **Updates.** A signed bundle onto the inactive slot pair, one trial boot,
  commit or roll back. The mechanism ships in the image, and `make bundle` packs
  a build into the bundle it installs.
- **Applications.** The payload is fetched over HTTPS into a memory-backed
  filesystem at boot, verified, and exec'd unprivileged, with a live resync and
  a development push loop that never touch flash (`docs/app-contract.md`).
- **CI** builds the image, asserts against it, and round-trips a bundle with a
  key it generates and throws away.

The device lane is written and waiting for the first flash. It states what a
correct boot looks like, down to the peripherals, the watchdog counting in
hardware, an idle minute writing nothing to the flash, and the update mechanism
agreeing with the firmware about which slot is running.

How that flash is done — back up the medium first, write the image, provision
it, and what to do when a unit does not come back — is `docs/install.md`, with
`scripts/flash.sh` as the guarded tool for the two destructive steps. It is a
first-install and disaster-recovery procedure only; everything after it reaches
a device over the network.

## Test lanes

Four, in order of how much they need:

| lane | needs | what it asserts |
|---|---|---|
| `make check` | nothing | shell lint, layer metadata, and `tests/host` — the parts of the system that are ordinary programs, run against a temporary tree |
| `make image` | an arm64 Debian host | builds the image |
| `make test-image` | a built image | `tests/image` — what the build produced, read out of the image file directly |
| `make test-device` | a provisioned unit | `tests/device` — what a running unit actually does |

Everything a build produces — the image, the per-version chroot and deploy
directories, the build scratch, the apt package cache — lands under `work/`,
which is gitignored and gigabyte-scale. `make clean` reclaims it. A plain
`rm -rf work` generally will not: builds run inside a user namespace, so files
the build creates as anything other than root come out owned by sub-uids of the
invoking user, in directories that user cannot traverse, and the removal fails
partway on files that look like his own. `make clean` removes them from inside
such a namespace. A scratch directory or apt cache pointed outside `work/` by
its knob is named and left alone, so an out-of-repo cache survives a reset
without re-downloading the archive. Do not clean, by `make clean` or by hand,
while a build is running. `make test-clean` asserts what `make clean` would
resolve and which removal it would start with, and removes nothing; it is a lane
of its own rather than part of `make check`, because the gate should not be
calling the script that empties the build area.

The device lane talks to a real device over SSH, so it needs to be told which
one. That is site information and never enters the tree: export
`BRENN_DEVICE_HOST` (with `BRENN_DEVICE_USER`, default `root`, and
`BRENN_DEVICE_SSH_OPTS` if the connection needs options), or put the same
assignments in `.local/device.conf`, which is gitignored. An exported value
wins over the file. Told nothing, every test skips and the lane fails rather
than reporting success against a device that was never there.

The lane's assertions share one SSH connection for the length of a run, because
individually they are cheap and collectively they are a hundred handshakes over
a radio. `BRENN_DEVICE_SSH_MULTIPLEX=0` gives each its own connection instead.

Device assertions are written before the hardware runs them, and are expected
to fail until it does: the failure is the measurement. An unexpected reading
gets reviewed before the test is changed to accept it — see the bring-up
discipline in `CLAUDE.md`.

Two of them take their time on purpose: the flash-budget test watches an idle
minute pass before reading the write counters, and the log test waits for the
collector to accept records it wrote. Both are measurements of behaviour over
time, and neither has a shortcut.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
