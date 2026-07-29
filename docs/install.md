# Installing on a device

Getting an image onto a device over a cable happens once in that device's life
if nothing goes wrong. Every operating-system change after it ships as a signed
update bundle to the running device (`image/layer/brenn/rauc.yaml`), and every
configuration change is a transaction on the running device
(`docs/provisioning.md`). So this is not a routine procedure and is not written
as one: it opens the robot, it overwrites the medium it shipped with, and the
copy of what was there is whatever was taken beforehand.

The hardware steps below are specific to the Reachy Mini — a Raspberry Pi CM4
on the robot's head PCB, whose eMMC is reachable only through the CM4 boot
ROM's mass-storage gadget. The parts that are not hardware — build, backup,
write, provision, verify — are the same on any profile.

## Scope

First install and disaster recovery, and nothing else. Reaching for this
document to change something on a device that already runs this image is a sign
of taking the wrong path: an OS change is `make bundle` and an install onto the
idle slot pair, and a configuration change is `brenn-config-apply`. Both leave
the robot assembled.

Entering flashing mode costs a teardown, and the recovery route it provides is
the only one this hardware has, so it is used sparingly and deliberately.

> **Status.** `TODO(first-flash-observations)` — this procedure has not yet
> been performed end to end. The flashing-mode mechanics are observed on the
> unit: the boot ROM enumerates and the gadget runs entirely from RAM
> regardless of what the eMMC holds, the gadget exposes exactly one disk, and
> it identifies itself to Linux as described in step 2. What is still an
> expectation rather than an observation is the part only the first flash can
> settle — the first boot of *this* image on the unit. Anything read off the
> device that does not match what is written here gets human review before
> either the device or the document is adjusted; that is the bring-up
> discipline in `CLAUDE.md`, and it applies to a runbook exactly as it applies
> to a test.

## Before you start

Assemble all of this before the robot is opened. Every item missing at the
bench either costs a second teardown or tempts a shortcut around a guard.

- **A built image.** `make image PROFILE=reachy` writes
  `work/image-brenn-os-reachy/brenn-os-reachy.img` — the whole-device raw
  image, partition table included, around 14 GiB. The `.img.sparse` beside it
  is an Android sparse container for tooling that understands the format; it is
  not what gets written here, and the write refuses it.
- **An assembled provisioning generation.** A directory conforming to
  `docs/provisioning.md`, built by `scripts/assemble-generation.sh` from the
  unit's configuration and the operator's store of secrets, neither of which is
  in this repository:

  ```
  scripts/assemble-generation.sh path/to/units/<unit>
  ```

  That already runs the contract check on what it produced. **Run it again
  against the generation you are about to install, before the robot is opened:**

  ```
  scripts/provision.sh -n /some/mounted/persistent path/to/generation
  ```

  A device with no usable generation boots healthy and completely unreachable —
  no network credentials, no host keys, no listener worth reaching — and with
  no console on this hardware, finding that out costs another teardown. The
  check is seconds; the mistake is an hour.
- **`rpiboot`**, built from a release tag of
  [raspberrypi/usbboot](https://github.com/raspberrypi/usbboot). It is a
  workstation-side recovery tool that never touches the image build, so it is
  not vendored or pinned here. Tag `20250908-162618` is known to work, built on
  Fedora 43 with `libusb1-devel`; the gadget images ship prebuilt in that repo,
  so only the host tool compiles.
- **`zstd`**, and a Linux workstation with a free USB port and enough free disk
  for the backup — a few gigabytes compressed, but plan for the uncompressed
  size of the medium if a restore is ever needed.
- **The vendor's own flashing guide** open in a tab:
  [reflash_the_rpi_ISO.md](https://github.com/pollen-robotics/reachy_mini/blob/main/docs/source/platforms/reachy_mini/reflash_the_rpi_ISO.md).
  The teardown to reach the head PCB, the location of switch SW1, and the
  photo that identifies the USB port
  ([pcb_usb_and_switch.png](https://github.com/pollen-robotics/reachy_mini/blob/main/docs/assets/pcb_usb_and_switch.png))
  are theirs to maintain and are not transcribed here. Their flashing steps put
  a vendor image on the device; ours are below. Do not follow both.

Commands below are run from the root of a checkout of this repository.

## 1. Enter flashing mode

**First, turn off desktop automount.** The moment the gadget appears, a desktop
automounter mounts the vendor root filesystem read-write — mutating the source
before it has been backed up. On GNOME:

```
gsettings set org.gnome.desktop.media-handling automount false
gsettings set org.gnome.desktop.media-handling automount-open false
```

Both settings are workstation-wide and persist across sessions; step 5 turns
them back on once the cable is out for the last time.

The flash tool refuses a target with anything mounted off it, so an
automounter that gets there first stops the run rather than corrupting the
backup. That is the second line of defence, not the first.

Then, in this order:

1. Shut the robot down completely.
2. Start `rpiboot`, and leave it running in its own terminal — it waits for the
   device and then uploads every boot stage over USB:

   ```
   sudo rpiboot -d mass-storage-gadget64
   ```

3. Set SW1 on the head PCB to **DOWNLOAD**.
4. Connect the USB cable to the head PCB's **USB2** port.
5. Power the robot on.

`rpiboot` reports its upload as it happens, and the eMMC then appears as a USB
disk. None of it involves the eMMC's contents: the boot ROM enumerates on
power, the gadget Linux runs from RAM, and the medium is passive throughout.
That is what makes this the recovery route for every failure further down — a
half-written image on the device cannot take the way back out with it.

**The head PCB has two USB ports and only one of them works for this.** The
wrong port gives total USB silence — no boot-ROM device, no kernel events,
nothing at all, which looks exactly like a dead cable or a dead robot. If
nothing enumerates, move the cable to the other port before suspecting
hardware. The vendor's photo above is the authority for which port is USB2.

## 2. Back up what is there — before anything writes

The medium holds a state that cannot be downloaded again. The vendor publishes
its *release* images, but not this unit's in-place package updates or tuning,
and once the user area is overwritten whatever was there is gone permanently.
Take the backup. It is not optional and it is not last.

List what the gadget exposed:

```
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
```

The target is a whole disk on USB whose model reads `Raspberry Pi
multi-function USB device`. That is what Linux reports; the `RPi-MSD- 0001`
name in vendor documentation is what Raspberry Pi Imager displays on Windows
and matches nothing here.

Back up every disk it exposed:

```
sudo scripts/flash.sh backup /dev/sdX /path/to/backups
```

On this hardware that is a one-iteration loop: the gadget exposes a single
disk, the eMMC user area. The two 4 MiB eMMC boot partitions are not exposed —
they cannot be backed up over this path, and cannot be damaged by a write to
the exposed disk either. The loop stays because firmware that exposed more
would otherwise be silently under-backed-up.

Each run identifies the device, streams it out compressed, and then verifies by
reading the device a *second* time and comparing that against the decompressed
archive on disk. The second pass costs minutes and covers both an unstable USB
link and workstation-side damage to the only copy that will ever exist. A
mismatch deletes the artefacts and fails the run: a backup that cannot be
trusted must not look like one. It takes roughly half an hour.

The output is a directory holding the compressed dump, `SHA256SUMS`, and a
`PROVENANCE.txt` that records what was read and the commands to check and
restore it. **Store it outside any repository** — it is this unit's data, it is
gigabyte-scale, and it has no business in version control.

**The restore path is the factory-reset escape hatch.** Decompress the dump and
write it back with the same tool:

```
zstd -d <dump>.img.zst
sudo scripts/flash.sh write /dev/sdX <dump>.img
```

A restored dump boots the vendor OS in the state it was captured in — already
configured, joining the network it was told about. That is not the same as a
freshly flashed vendor *release*, which comes up broadcasting the vendor's
`reachy-mini-ap` setup hotspot and expecting to be set up from scratch. Our
image broadcasts nothing, by design.

If the vendor OS is changed after a backup is taken — an update, a tuning
change — the backup is stale and the answer is to take it again.

## 3. Write the image

```
sudo scripts/flash.sh write /dev/sdX work/image-brenn-os-reachy/brenn-os-reachy.img
```

The tool refuses before it writes anything: the target must be a whole disk, on
USB, reporting the gadget's model, with nothing mounted off it, and large
enough for the image — and it declines to run at all if it cannot read the
device's identity, rather than guessing. A workstation's own disk fails at
least two of those checks. It then writes, reads back exactly as many bytes as
the image holds, and compares digests.

A verify mismatch is a failure, not a warning: nothing reports success, and the
remedy is to run the write again. So is a cable drop or a power loss part way
through. The device is not stranded by a torn image — flashing mode does not
depend on what the eMMC holds — so re-entering it and re-running the write is
always available, which is why "run it again" is a complete answer here.

On success the tool re-reads the partition table, waits for the new partitions'
labels to become readable, and prints the exact provisioning command for the
partition labelled `persistent` on the device it just wrote. Use what it
printed. If it reports that the labels were not readable yet, it prints the
command that finds the path instead — run that and use what it shows.

## 4. Provision

```
sudo scripts/provision.sh /dev/sdX6 path/to/generation
```

Address the partition by its device path — the one the previous step printed —
rather than through `/dev/disk/by-partlabel/persistent`, which on a workstation
holding more than one such medium is ambiguous. `provision.sh` verifies the
label of whatever it is given, so naming the path directly loses no safety.

The first generation is installed committed, with no trial: a first generation
has nothing to fall back to and no boot to be tried on. See "Installing the
first one" in `docs/provisioning.md`.

The device is now assembled-and-ready as far as the workstation is concerned.
There is nothing else to write.

## 5. First boot

In this order:

1. Power the robot off.
2. Set SW1 back to **DEBUG**.
3. **Disconnect the USB cable.**
4. Reassemble.
5. Power on.

Step 3 is load-bearing. A USB cable connected at a normal power-on was observed
to prevent the unit from booting at all — no network, no USB enumeration, no
sign of life — which is indistinguishable from a bricked device. A forgotten
cable is the single most likely way this procedure appears to have destroyed
the robot while having done nothing of the kind.

Expected: the unit joins the network its generation names and answers SSH as
`root` on the host key its generation carries. If its address is not known
ahead of time, the CM4's MAC sits in a Raspberry Pi Trading OUI, so an ARP scan
of the LAN filtered by OUI finds it.

The workstation is finished with the robot here. Turn its automounter back on,
so this procedure does not leave a desktop that quietly ignores USB media weeks
later:

```
gsettings reset org.gnome.desktop.media-handling automount
gsettings reset org.gnome.desktop.media-handling automount-open
```

If there is another pass to come — a re-write, a restore — leave it off until
after the last one.

## 6. Verify

The device test lane is the acceptance test for this whole procedure. Point it
at the unit — `BRENN_DEVICE_HOST` and friends, in the environment or in the
gitignored `.local/device.conf` (see `README.md`) — and run it:

```
make test-device
```

It asserts what a correct boot looks like down to the peripherals, the watchdog
counting in hardware, an idle minute writing nothing to the flash, and the
update mechanism agreeing with the firmware about which slot is running. Two of
its tests take their time on purpose.

These assertions were written before any hardware ran them, so the first run is
a measurement. An unexpected reading gets reviewed before anything is changed
to accept it — not the test, and not this document. Do not let a green run
launder a value nobody looked at.

## If it goes wrong

**There is no console on this unit.** No serial headers are exposed on the head
PCB, and a USB console is structurally impossible: the CM4's single USB
controller runs in host mode during normal operation, owned by the internal hub
and the robot's own peripherals, so there is nothing there to be a gadget. The
kernel command line does carry `console=serial0,115200`
(`image/layer/profile/reachy/boot/cmdline.txt`) because it costs nothing and
the software side of it is proven — but nothing in this procedure depends on
being able to attach to it, and no step here will ever tell you to.

The consequence is worth stating plainly: distinguishing "it did not boot" from
"it booted and the network is wrong" itself costs a teardown back into flashing
mode. That is precisely why the generation is validated before the robot is
opened.

**The unit never appears on the network.** In order:

1. Check that no USB cable was left connected at power-on. This reproduces the
   symptom exactly and is the cheapest thing to rule out.
2. Check the address by an OUI-filtered ARP scan rather than by name — a host
   name that does not resolve says nothing about whether the device is up.
3. Failing those, back into flashing mode (step 1) and inspect from the
   workstation.

**Every remedy routes through flashing mode**, which works regardless of what
is on the eMMC. From there:

- *A torn or wrong image*: re-run the write (step 3).
- *Back to where the unit started*: restore the backup (step 2).
- *A bad or missing provisioning generation*: repair the payload on the
  `persistent` partition from the workstation. `provision.sh` refuses a device
  that already holds a generation, by design — after the first, a change is a
  transaction on the running device — so workstation recovery means clearing
  the bad state first and then provisioning clean.

There is little forensic state to find, by design: the journal is volatile and
upload-only, so a boot that never reached the network left nothing behind.
Reflashing and reprovisioning is usually cheaper than an investigation, and the
backup means it is never the destructive option.
