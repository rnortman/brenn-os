# The application contract

The operating system knows exactly one thing about the application: how to
obtain a directory and exec the program at its root. Language, dependencies,
models and configuration are the application's business. This document is that
boundary, in full.

It is a contract in both directions. What the OS promises is here; anything not
here is not promised, and a payload that relies on it will break at an update.

## A payload

A payload is a directory tree with one required file: an executable `run` at its
root. Nothing else about the tree is specified.

The device obtains one as a tar archive whose contents *are* the payload root —
`run` is at the top of the archive, not inside a directory in it. gzip, xz and
zstd compression are all understood.

## What running it means

`run` is executed as the unprivileged `app` account, with the payload directory
as its working directory, and with:

| Variable | Meaning |
|---|---|
| `BRENN_APP_ROOT` | The payload directory. Read-only. |
| `BRENN_DATA_DIR` | `/data/app` — writable, survives a reboot, on flash. |
| `BRENN_CA_FILE` | The trust anchor to use for anything the payload fetches. |
| `TMPDIR` | Scratch space, in RAM, inside the payload store's memory budget. |

`BRENN_CA_FILE` names a path that exists only when the device's provisioning
carries a trust anchor. A fetched payload always has one, since the fetch
itself needs it; a baked payload can run on a device provisioned without one,
and must not assume the file is there.

The payload runs from a memory-backed filesystem, so nothing it does costs the
device's flash a write unless it deliberately writes under `BRENN_DATA_DIR`.
That is discouraged and exists for the rare asset genuinely worth keeping
across a reboot; the flash on these devices is soldered down and has a finite
write budget.

`run` is expected to stay in the foreground. If it exits with a failure it is
restarted; if it exits cleanly it is not, and the device is left with no
application until the next resync or reboot. A payload with work that finishes
should wait rather than return.

## Privilege

`run` always executes as `app`. There is no root execution path — not as a
default, not as an opt-in, and not as a start-as-root-and-drop pattern.

A payload arrives over the network far more often than an image does, and with
none of an image's review or rollback. Making it a channel to root would make
every deployment an operating-system change. Anything that genuinely requires
privilege belongs in the image, where it is signed, reviewed and reversible.

Two consequences worth stating plainly:

- **Privileged ports.** Binding below 1024 is a per-profile capability granted
  to the application service in the image, not something a payload can arrange
  for itself. Ask for it as an image change.
- **Hardware.** Cameras, audio, the servo bus and the IMU are reachable because
  the `app` account is in the groups that own those device nodes. Another
  device class means another group, which is again an image change.

The `app` account's numeric uid and gid are fixed by the image and published
with each release, so that ownership of anything under `/data` means the same
thing after an update.

## The base system

The payload may rely on the OS package set, notably the Python interpreter. The
exact interpreter version is a property of the release and is published with it
— pin against it rather than assuming a range.

There is no dependency resolution at run time. A payload must not fetch
packages when it starts; the network may not be there, and resolving
dependencies at boot makes every boot a different system. A payload that
carries its own dependencies and materialises them offline into RAM at start is
conformant, and is the intended shape:

- **Rust, and anything else compiled.** Ship the binary. There is nothing to
  do.
- **Python.** Ship prebuilt `aarch64` wheels alongside a bundled installer and
  install them offline into `TMPDIR` at start, or ship a relocatable virtual
  environment built against the published interpreter version.

## Models

Large model files do not belong in the payload. A payload that carries them is
one that has to be transferred in full for a one-line change.

Fetch them from the model server over HTTPS using `BRENN_CA_FILE`, into memory
or under `TMPDIR`, with the URL and the expected digest pinned by the payload's
own configuration and the download skipped when the file is already present.
`/data/models` exists for parking a model too large to hold in memory alongside
everything else; it is on flash, so writing there is a deliberate act.

## Deploying one

Four ways in, all of which end at the same check and the same atomic switch:

- **At boot, and on demand.** The device fetches the payload named by its
  provisioning configuration, presenting the generation's client certificate,
  unpacks it into memory and switches to it. `brenn-app-resync` over SSH does
  the same thing again without a reboot.
- **Baked onto the device.** `ssh root@<unit> brenn-app-bake < payload.tar.zst`
  receives a compressed archive into memory, unpacks and switches to it there,
  and only once it has passed the check writes the archive and its digest to
  the persistent partition. From then on the device is baked: every boot verifies
  that archive against its stored digest, unpacks it into memory and runs it,
  with no network and no operator, and the fetch is skipped even if the
  provisioning configuration names a payload. Baking again replaces the baked
  payload; `brenn-app-unbake` leaves baked mode, and the next boot fetches
  again. A bake is a flash write, and meant to be a rare one. It refuses an
  uncompressed archive: a compressed one carries its own end, which is how an
  upload cut short is told from a complete one.
- **From a workstation, during development.** Copy a tree into the payload
  store and run `brenn-app-activate` on it over SSH. No reboot, no flash write,
  and the same contract check as a released payload.

On a baked device the last two replace the running payload in memory only; the
baked archive is untouched. `brenn-app-stage` switches back to the baked
payload without a reboot, and a reboot does the same.

Switching is a symlink rename, so the previous payload keeps running until the
replacement is complete and has been checked. The payload that was replaced is
then removed: the store is a capped memory filesystem, and it is empty again
after a reboot in any case.

A boot that cannot obtain a payload is not a boot worth keeping. An operating
system update or a configuration change being trialled on such a boot reverts
rather than commits, and the fetch keeps retrying with a growing delay until
either it succeeds or the trial gives up.

## Not promised

- Offline autonomy, except by baking. A device that is not baked has no
  application without the network, and converges on one when the network
  returns; a baked one runs its baked payload with no network at all.
- Any file, path, port, unit or user beyond those named above.
- That the payload is signed. Today a fetched payload is trusted because it
  arrived over TLS from the server the device was provisioned to trust, at the
  URL it was provisioned with, and was served to this device because it
  presented its provisioned certificate — so a payload may carry secrets meant
  for this unit, and on the device they are readable by every local account,
  since the tree is unpacked world-readable. A baked one is trusted because
  root put it there over SSH.
