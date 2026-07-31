# Updating a device

An operating-system change ships to a running device as a signed bundle: it is
built on a workstation, copied over the network, written to the slot pair the
device is *not* running, and tried for one boot. If that boot proves itself the
pair is committed; if it does not, the device returns to the pair it had. The
robot stays assembled and nothing is opened.

This is the routine procedure. `docs/install.md` is the other one — first flash
and disaster recovery — and reaching for it to change a running device is a sign
of taking the wrong path. Configuration changes are a different transaction
again (`docs/provisioning.md`), and only one transaction runs at a time.

## Before you start

**Tools, on the build host.** `rauc` packs and signs the bundle, `mksquashfs`
(`squashfs-tools`) builds the verity image inside it, and `openssl` is what
generated the signing pair.

```
sudo apt install rauc squashfs-tools openssl     # Debian/Ubuntu
sudo dnf install rauc squashfs-tools openssl     # Fedora
```

Without them `make bundle` dies naming the missing one, and the host lane's
signing test (`tests/host/075-bundle-signing.test.sh`) skips with the same
message rather than passing on a check it never ran. CI installs `rauc` and
`squashfs-tools` and takes `openssl` from the runner image, so the skip is never
CI's path — a green gate here means the signing path really was exercised.

**Signing material.** Three paths, none of them in this tree:

| knob | what it names |
|---|---|
| `BRENN_BUNDLE_CERT` | the signing certificate |
| `BRENN_BUNDLE_KEY` | its private key |
| `BRENN_BUNDLE_KEYRING` | the anchor the finished bundle is verified against |

How the pair is created, and why it is a self-signed certificate with thirty
years of validity rather than anything from a public authority, is "The
update-signing keypair" in `docs/provisioning.md`. The one thing worth stating
here, because its absence sends people hunting for a third artifact: **in the
single-pair bring-up configuration the certificate and the keyring are the same
file.** `rauc-keyring.pem` in the operator's store, the certificate every
generation carries, and `BRENN_BUNDLE_KEYRING` all name that one certificate.
Leave `BRENN_BUNDLE_KEYRING` unset and the build says so and uses the
certificate:

```
make-bundle: BRENN_BUNDLE_KEYRING unset; verifying against the signing cert (single-pair bring-up)
```

That is a round trip, not an independent check: it catches a packing failure, a
corrupted result and a wrong compatible string, but not a bundle signed with a
key the fleet does not trust. The device is what checks that, below.

Write the paths once into `.local/bundle.conf`, which is gitignored:

```sh
# .local/bundle.conf — paths to this build host's signing material.
# Paths only. Key material never lives under this repo root, ignored or not.
BRENN_BUNDLE_CERT=$HOME/keys/brenn-os-signing.crt
BRENN_BUNDLE_KEY=$HOME/keys/brenn-os-signing.key
BRENN_BUNDLE_KEYRING=$HOME/keys/brenn-os-signing.crt
```

An exported value outranks the file and a command-line flag outranks both, so
one release lane can pass real keys past a workstation's everyday overlay
without editing anything. Exporting a knob *empty* is not a value — it reads as
one nobody set, and the file answers — so the way past an anchor the file names
is `--keyring`, which the success line then reports.

**A device you can reach**, by name or address, answering SSH as `root` on the
key its generation carries. An update is installed over that connection and
verified over it afterwards; there is no console on this hardware to fall back
to (`docs/install.md`, "If it goes wrong").

Commands below are run from the root of a checkout, except where they are
plainly on the device.

## 1. Build the bundle

```
make image PROFILE=reachy
make bundle PROFILE=reachy
```

`make image` builds; `make bundle` only packs what the build left, so a bundle
always names a version that came out of a real build. On success:

```
make-bundle: verified against /home/you/keys/brenn-os-signing.crt
make-bundle: wrote work/image-brenn-os-reachy/brenn-os-reachy-<version>.raucb
```

Two lines with a verb, because a bare path says nothing about whether it was
checked. The first is the finished artifact read back through `rauc info` — the
same read the device makes — and it is the one the success line vouches for. The
version is `git describe` of the tree that built it, so a dirty checkout is
visible in the bundle's name.

## 2. Copy it to the device

The device stages bundles in `/data/updates`, which is root-only:

```
ssh root@unit df -h /data
scp work/image-brenn-os-reachy/brenn-os-reachy-<version>.raucb root@unit:/data/updates/
```

The bundle carries a whole boot filesystem and a whole root filesystem, so the
copy is not quick over wireless and the writable partition holds a few of them,
not many. Check the free space first, and delete the ones already installed:
nothing on the device prunes that directory.

## 3. Install it

```
ssh root@unit rauc install /data/updates/brenn-os-reachy-<version>.raucb
```

What that does, in order, because every step of it shows up in the state you
will read afterwards:

1. **The pre-install check.** An update is refused in three states, each with
   one line naming what to do:

   - `a configuration change is on trial; let it commit or revert before
     updating` — a configuration candidate and a slot pair are judged by the
     same health gate, so a failed boot with both in flight would say nothing
     about which one was wrong. Wait out the configuration trial's boot and
     install again.
   - `this boot is an unanswered operating-system trial; commit it (rauc status
     mark-good) or refuse it (rauc status mark-bad) and reboot before updating`
     — RAUC writes the pair this system is *not* running, which on a trial boot
     is the committed pair the trial falls back to. The wait is usually short:
     the health gate is an address and sshd, so a boot you can SSH into to type
     `rauc install` has generally committed already. If ten minutes pass with no
     commit, the deadman reboots to the committed pair and the install proceeds
     from there. Refusing the trial instead is `mark-bad` **and then a reboot** —
     the refused pair keeps running until the reboot, which is the next state.
     If that `mark-bad` exits nonzero, read the backend's own line before doing
     anything else: rauc prints only that the backend call failed, and which
     failure it was is in `journalctl -u rauc.service`. `no committed
     boot_partition` — or a committed one that `belongs to no slot` — means the
     refusal is recorded (the pair reads `bad` and this gate holds) but the
     selector file no longer names a pair this system can place. What the
     firmware boots from a file in that state is not established, so the reboot,
     which counts on it still naming the committed pair, waits until the file is
     repaired ("Repairing the selector file"). **Any other line means the
     refusal may not have been recorded at all** — the state directory and the
     partition labels are read before it is written — so `rauc status` and `ls
     /data/rauc` are what say whether it was, and that failure is the one to fix
     first.
   - `this boot's operating-system pair has been refused; reboot to the
     committed pair before updating` — between a `mark-bad` and the reboot the
     device is still running the pair it just refused, and the only pair left
     proven is the one an install would overwrite. Reboot (the selector still
     names the committed pair, so any orderly verb lands there) and install.

   The gate keys on the pair that is *running*, not on whether a trial is owed
   anywhere, so the two installs an operator legitimately types are both
   allowed: the next update after a commit, and the reinstall after a fallback
   (§"When it does not come back", step 4).

   A device that cannot answer the check's own questions is refused as well, in
   two shapes. `the running slot could not be determined; refusing to update` —
   the boot backend cannot say which pair is running; RAUC needs that same
   answer to choose which pair to write, so there is nothing safe to install
   either way, and the reading to check is the firmware's, under `ls
   /proc/device-tree/chosen/bootloader`. `the running pair's state could not be
   determined; refusing to update` — it named the running pair and then could
   not say whether that pair has been refused; the reading to check is `ls
   /data/rauc`, and a backend that answers one question and not the other is
   itself the thing to fix before installing anything.
2. **Verification against the device's own anchor.** The device checks the
   bundle against the keyring its *provisioning generation* carries, published
   at `/run/brenn/provisioning/rauc/keyring.pem` — not against anything in the
   bundle and not against `BRENN_BUNDLE_KEYRING`. A bundle signed with a key
   that unit was not provisioned to trust fails here, and that is the check the
   build-side verification cannot make for you. A device that was never
   provisioned can verify nothing and therefore installs nothing.
3. **The target slot is marked bad**, before a byte is written — a `bad-<slot>`
   file under `/data/rauc`. An install that dies before it finishes leaves that
   file behind, which is what it is for; an install that reaches step 5 clears
   it.
4. **Both partitions of the idle pair are written and verified.** This takes
   minutes.
5. **The pair is staged.** `autoboot.txt` on the selector partition gains the
   candidate in its `[tryboot]` section — the committed pair is untouched — the
   `bad-<slot>` file from step 3 is removed, a `staged-<slot>` file is written
   beside it, and the one-shot tryboot flag is armed for the next reboot.

Nothing has changed about what the device boots by default. At this point a
power cut loses the arming and the device comes up exactly as before, which is
the safe direction and is deliberate — the `staged-<slot>` file survives it, and
is what makes the next orderly reboot the trial anyway.

## 4. Reboot

```
ssh root@unit systemctl start reboot.target
```

Any orderly reboot works. The staged trial is on flash, not in the reboot
command: `brenn-trial-rearm.service` re-writes the armed reboot parameter from
the shutdown itself whenever a `staged-<slot>` file exists, so bare `reboot`,
`halt` and `poweroff` reach the trial too.

The verb above is still the one named here, because the trap it steps around is
real and only half of it is closed. `reboot`, `halt` and `poweroff` are
compatibility symlinks: with no trailing argument they *delete* the armed reboot
parameter while parsing their own arguments, before any shutdown work begins.
That is what turned the first OTA update on this hardware into an investigation
— the device took an ordinary reboot, came back on the pair it was already
running, and left behind state that looked exactly like a trial that failed when
no trial had been attempted. The re-arm puts the parameter back afterwards; a
device running an older image, or any future path that stages a trial without
the marker, has nothing that would.

Verbs that deliver the trial with no help from the image at all:

- `systemctl start reboot.target` — a plain unit start; it touches nothing.
- `systemctl reboot --reboot-argument="0 tryboot"` — writes the parameter
  itself, so it works even if the arming was lost.
- `reboot "0 tryboot"` — the compat path *with* an argument writes the
  parameter instead of deleting it.

**A device flashed or updated before the re-arm shipped does not have it.** Read
its `rauc status` by the pre-marker rules below, and use one of the three verbs
above for its next trial; the update that carries the re-arm is the last one that
needs them.

## 5. What the trial boot does

The firmware clears the one-shot flag before it hands over, so this boot is a
single attempt with nothing to undo: a panic, a hang the watchdog turns into a
reset, or a power cut all land back on the committed pair.

On the device, the trial boot then has to prove itself:

- **The health gate** (`brenn-healthy.target`) is reached when the device has an
  address and sshd accepts connections. That is deliberately not a judgement
  about whether the new image is *right* — only about whether it can still be
  reached to change again, which is the failure that strands hardware.
- **Reaching it commits.** `rauc-mark-good.service` runs `rauc status
  mark-good`, which swaps the two `autoboot.txt` sections so the new pair is what
  boots by default, removes the `staged-<slot>` file — the trial has now been
  answered — and disarms the flag. Both that unit and the deadman below are
  skipped outright on an ordinary boot, so a healthy device writes nothing to
  flash for the update machinery.
- **Not reaching it, within ten minutes, reboots the device**
  (`brenn-trial-deadman.timer`). That covers the boot that comes up, stays up
  and is useless — no address, no way in — which the firmware's flag cannot
  catch because nothing crashed. Nothing was committed, so the reboot lands on
  the pair that was running before: the re-arm stands down on a trial boot, so
  *that* reboot is a fallback and not another attempt at the same candidate.
  What it is not is the end of the trial. Nothing answered it, so the
  `staged-<slot>` file is still there, and every later orderly reboot re-arms
  and re-enters the same candidate — another deadman cycle, up to ten minutes,
  before the device is reachable again. Answering it by hand is in the last
  section.

So an update either commits within about ten minutes of the reboot, or the
device is back where it started.

One more thing happens, before any of that. The trial boot's initramfs writes a
short record on the selector partition — that it ran, which pair the firmware
handed over to, and what it found where the root filesystem should be — and the
next boot that comes up far enough reports that record into the journal
(`brenn-trial-report.service`). It is the only thing this hardware can say about
a boot that died before the network existed, and its *absence* is the reading
that matters: see the last section.

## 6. Verify

```
ssh root@unit rauc status
make test-device
```

`rauc status` should show `Booted from` naming the new slot, the same slot as
`Primary`, and no slot with `boot status: bad`. `ls /data/rauc` should show no
`staged-*` file: the commit is what removes it, so one still sitting there is an
update that has not finished.

Which build the device is running it will tell you itself:

```
ssh root@unit 'grep IMAGE_VERSION /etc/os-release'
```

That is the version the build stamped in — the same string the bundle file is
named after — so "did the update take?" is a comparison of two strings rather
than a hunt through content.

`make test-device` is the full assertion — what a correct boot looks like down
to the peripherals, the watchdog counting in hardware, an idle minute writing
nothing to flash, and the update mechanism agreeing with the firmware about
which slot is running. It needs to be told which unit: export
`BRENN_DEVICE_HOST` (with `BRENN_DEVICE_USER` and `BRENN_DEVICE_SSH_OPTS` if the
connection needs them), or put the same assignments in `.local/device.conf`,
which is gitignored and is where site information belongs. Told nothing, every
test skips and the lane fails rather than reporting success against a device
that was never there.

Its first test (`015-committed-pair`) is about exactly this procedure, and it
runs before anything looks at content so that an update that did not finish
reads as one line rather than as a screenful of mismatches against the image you
replaced. It asserts the four facts this section just described: the running pair
is the committed one, neither pair has been refused, no staged trial is still
unanswered, and the device's `IMAGE_VERSION` is the version this tree describes
for itself.

That last one is why a build from a tree with uncommitted changes will not match
a device: `git describe --dirty` says so on purpose. Run
`BRENN_TEST_IMAGE_VERSION=any make test-device` to check the rest against a
device you know is on a different build.

## What `rauc status` shows

| field | means |
|---|---|
| `Booted from` | the slot the firmware actually handed over to, as the firmware reported it |
| `Primary` | the pair `autoboot.txt` boots by default — the committed one |
| `boot status: good` | no `bad-<slot>` file exists; nothing refused that pair |
| `boot status: bad` | a `bad-<slot>` file exists: an install started on it and did not finish, or something refused it |

`Booted from` equal to `Primary` is the definition of a committed device.
Different means a trial is in progress this very boot, and if the device has
been up for more than ten minutes without committing, something is wrong with
the deadman rather than with the trial.

What `rauc status` does *not* report is the other file the backend keeps beside
those, and it is the one that answers "did an update get tried?":

```
ssh root@unit ls /data/rauc
```

A `staged-<slot>` file means an update was staged onto that pair and its trial
has not been answered — neither committed nor refused. Between `rauc install`
and the reboot, that is exactly right. On a device that has been up for a while
on its committed pair, it means a staged trial never happened or never
committed, and the device suite says so in those words (`make test-device`).

**A device flashed before the marker shipped reads differently, and this is the
single most expensive misreading of the whole path:**

> **`boot status: bad` on a freshly installed slot, on an older image, is not a
> verdict.** It is the marker RAUC writes *before* it starts writing the slot,
> and on that backend nothing clears it until the trial commits.

Such a device reads `bad` while the install is still copying, `bad` while the
bundle sits staged and waiting for a reboot, and goes on reading `bad` after a
trial that never happened. Nothing in that sequence judged the new slot. Read it
as "not committed", never as "refused". The current backend clears the marker at
staging, so the reading survives only until that device takes this update.

## Repairing the selector file

`autoboot.txt` on the selector partition is the whole of what the firmware
consults to find a bootable system, and rewriting it is one FAT write with no
atomicity guarantee behind it — so a power cut during a commit or a refusal can
leave it naming no committed pair, or naming a partition that belongs to neither
pair. The backend refuses to guess from a file in that state, and that refusal
is what a verb failing with `no committed boot_partition`, or with a committed
one that `belongs to no slot`, is reporting. Until the file is repaired what the
next boot does is the firmware's guess, so this is done before rebooting rather
than after.

**An unanswered trial repairs it by committing.** If `ls /data/rauc` shows a
`staged-<slot>` file for the pair this boot is running and nothing has refused
that pair, `rauc status mark-good` writes a whole well-formed file naming the
pair that has just proved itself. That is the ordinary repair and it needs
nothing below; the backend says so in its own words, in `journalctl -u
rauc.service`:

```
rpi-tryboot-backend: the selector named no committed pair; rewriting it
```

By hand, for every other case. The two partition numbers come from this unit's
labels rather than from a table, so read them first:

```
ssh root@unit ls -l /dev/disk/by-partlabel/boot_a /dev/disk/by-partlabel/boot_b
```

The trailing number of each target (`mmcblk0p2`, `mmcblk0p3`) is that pair's
boot partition. Then, on the device:

```
mkdir -p /run/selector
mount -t vfat -o rw /dev/disk/by-partlabel/bootconfig /run/selector
cat /run/selector/autoboot.txt
```

A healthy file is exactly five lines:

```
[all]
tryboot_a_b=1
boot_partition=<committed>
[tryboot]
boot_partition=<other>
```

Which pair goes on the committed line is the one decision here, and `rauc
status` with `ls /data/rauc` answers it:

- **The running pair has been refused** — a `bad-<running slot>` file exists.
  This is the state §3's second refusal message sends you here from. Name the
  *other* pair committed: it is the pair the device ran before the trial, and
  the one it has to get back to.
- **The running pair owes an unanswered trial** — a `staged-<running slot>` file
  exists and nothing refused it. Commit it instead, above; a hand-written file
  would answer nothing and the trial would still be owed.
- **Neither** — the device is running the pair it has been running and nothing
  refused it. Name it committed, and the other pair in the `[tryboot]` section.

Write it, flush it, and let the partition go again:

```
printf '[all]\ntryboot_a_b=1\nboot_partition=<committed>\n[tryboot]\nboot_partition=<other>\n' \
  >/run/selector/autoboot.txt
sync
umount /run/selector
rmdir /run/selector
```

`rauc status` reporting a `Primary` again is the check that the write landed —
the failure that sent you here was a write to this same file. Add nothing else
to it: the firmware reads at most 512 bytes, and the device's own rewrites are
survivable only while the file stays inside one sector.

## When it does not come back on the new pair

The device is safe — it is running the pair it ran before, which is the whole
point of the trial. What it is not is talkative:

1. **Check whether a trial was attempted at all.** On a device that predates the
   re-arm, a bare `reboot`, `halt` or `poweroff` means no trial happened and the
   evidence looks identical to a failed one — reinstall the bundle (`rauc
   install` again) and reboot with `systemctl start reboot.target`. On a current
   image the shutdown re-arms whatever verb was used, and says so in the journal
   of the boot it is ending — which is volatile, so that line is only readable
   afterwards if the unit's generation names a log collector.
2. **Read `rauc status` and `ls /data/rauc`.** `Booted from` names the old slot
   and the `staged-*` file is still there: the trial was owed and was not
   answered. On an older image the new slot also still shows `boot status: bad`
   from install start, which — see above — distinguishes nothing by itself.
3. **Read what the trial boot's initramfs left.** This is the one thing a boot
   that died before the network can say. The record is reported into the journal
   of the boot you are now on, so:

   ```
   ssh root@unit journalctl -b -u brenn-trial-report.service
   ```

   Three readings, and they are different investigations:

   | what it says | what happened |
   |---|---|
   | `initramfs reached local-premount` and the root slot resolved | the initramfs ran and found its root filesystem; whatever failed, failed later than that — in the kernel's handover, in early userspace, or in the network |
   | `initramfs reached local-premount` and the root slot `absent` | the A/B slot links were not created for the candidate pair; the boot rebooted itself on purpose |
   | `no trial breadcrumb` | either no trial boot has happened since the last install, or the one that happened died before its initramfs ran — firmware, kernel, or the initramfs's own start |

   The last row is only readable as evidence about the boot because the writer's
   presence in the shipped initramfs is asserted by the image suite
   (`165-trial-breadcrumb`). On a device flashed before that shipped, `no trial
   breadcrumb` says nothing at all.

4. **Decide what the next reboot does.** The trial has not been answered — the
   `staged-<slot>` file is still there — so every orderly reboot from here
   re-enters the candidate and costs another deadman cycle before the device
   comes back. Either retry deliberately (reinstall and reboot), or answer the
   trial no:

   ```
   ssh root@unit rauc status mark-bad other
   ```

   That refuses the pair the device is not running, removes its `staged-<slot>`
   file, and leaves ordinary reboots ordinary again. It leaves a `bad-<slot>`
   file behind on purpose, so `make test-device` reports the refusal
   (`015-committed-pair`: "neither pair has been refused") until the next install
   onto that pair withdraws it. Nothing has to be undone before retrying.

   A nonzero exit here is worth one look at `journalctl -u rauc.service` before
   anything is concluded from it. If the line is `no committed boot_partition`,
   or a committed one that `belongs to no slot`, everything this step needed has
   happened regardless: the refusal is recorded, the `staged-<slot>` file is
   gone, ordinary reboots are ordinary again, and the device is running its
   committed pair rather than the refused one — not stuck, but repair the
   selector before the next install ("Repairing the selector file"). Any other
   line failed earlier than the refusal itself, and none of that can be assumed:
   `ls /data/rauc` will still show the `staged-<slot>` file, the next orderly
   reboot re-enters the candidate exactly as this step opened, and the failure
   to fix is the one the line names — a `/data` that cannot be written and a
   partition label that does not resolve are the two that reach here.

   The reinstall is permitted by design rather than by luck: the pre-install gate
   keys on the *running* pair's trial, and on this boot the unanswered trial
   belongs to the other pair — the one being reinstalled.

5. **There is little else to find.** The journal is volatile and upload-only, so
   a trial boot that died before the network came up left nothing behind on the
   device beyond that record; a trial that got as far as uploading is in the
   collector its generation names. This carrier has no serial header and no
   persistent journal, so the breadcrumb is the whole of the pre-network story.

Reinstalling the same bundle rewrites the idle pair from scratch and re-stages
it in one step, so a retry costs one `rauc install` and one correct reboot.
Nothing about a failed trial has to be cleaned up by hand.
