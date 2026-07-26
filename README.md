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

Early. The invariants and the image architecture are decided; the builder and
the profiles are not yet here. What this repository currently holds is its gates
and its paperwork — the secret-scanning and lint machinery that everything else
has to pass through, in place before there was anything to scan.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
