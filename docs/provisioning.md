# Provisioning

Nothing unit- or site-specific is built into an image. Credentials, keys,
endpoints and identity arrive at provisioning time, live on the writable
partition, and are never in this repository.

This document is the schema: which files a unit's configuration consists of,
what each one has to contain, and how the running system chooses between them.
It names keys and formats, never values.

## Generations

Configuration is delivered as a whole, versioned directory — a *generation* —
rather than as edits to individual files. The core of it is the chain that
strands a device if it is wrong: the wireless credentials, the host name the
network registers, the address the application is fetched from. So a
configuration change is a transaction, in the same shape as an operating-system
update: a candidate is trialled for one boot and either commits or is
discarded.

```
/data/provisioning/
  active -> gen-<N>          committed configuration
  trial  -> gen-<M>          candidate, present only while a trial is in flight
  trial-attempted            marker; present once a trial boot has begun
  gen-<N>/                   a generation
```

`gen-<N>` is any name; the links are what select. Generations other than the
committed one are kept as history and cost only the space they take.

## Contents of a generation

| Path | Mode | Content |
|---|---|---|
| `hostname` | 0644 | One DNS label, no domain. Lower case, digits and hyphens. |
| `machine-id` | 0644 | 32 lower-case hex digits, as `machine-id(5)` defines them. Stable for the life of the device: it is the identity its logs are filed under. |
| `net/wpa_supplicant-wlan0.conf` | 0600 | `wpa_supplicant.conf(5)`. Carries `country=` — the regulatory domain is site configuration, not an image default — and one or more `network={…}` blocks. |
| `net/ntp.conf` | 0644 | Optional. A `systemd-timesyncd` drop-in naming a local time server as `NTP=`. Absent means the distribution's default public pool. |
| `ssh/ssh_host_ed25519_key` | 0600 | The host key. Provisioned rather than generated so a device keeps its host identity across a reflash. It is the only key sshd offers. |
| `ssh/ssh_host_ed25519_key.pub` | 0644 | Its public half. |
| `ssh/authorized_keys` | 0644 | The keys admitted to the device. There is no password authentication anywhere, so this file is the entire access-control list. Administration is done as `root`, which is the only account permitted to log in. |
| `ca/brenn-ca.pem` | 0644 | PEM certificate. The trust anchor for every HTTPS connection the device makes, including ones the application payload makes. |
| `rauc/keyring.pem` | 0644 | PEM certificate. Verifies operating-system update bundles; an update that does not verify against it is not installed. |
| `journal/upload.conf` | 0644 | `systemd-journal-upload.conf(5)`, with an `[Upload]` section. `URL=` is the collector, and it is `https://` — there is no plaintext option. `TrustedCertificateFile=` names the trust anchor above *through the published path*, `/run/brenn/provisioning/ca/brenn-ca.pem`, since a private certificate is not in any distribution's store. |
| `app/fetch.conf` | 0644 | Where the application payload comes from: `URL=`, which is `https://`, and `SHA256=`, 64 hex digits, the digest expected of what it returns. Both are required — the transport says who served the payload, the digest is what says what was served, and a payload that does not match it is discarded rather than run. |

Every file is owned by `root`, and so is every directory on the path to it —
none of them group- or world-writable. sshd refuses to read an access list
reachable through a directory somebody else could replace, and it is right to.
The two files at mode 0600 are secrets; the rest are readable because services
that are not root read them.

A generation is complete or it is not installed. There are no defaults for
missing files: a device that cannot be told which network to join has nothing
useful to fall back on, and an image carrying a default would be an image
carrying site configuration.

## What is checked before one is installed

Everything above is enforced, by one program — `brenn-config-validate` — which
runs both on the workstation assembling a generation and on the device
accepting a change, so a generation that installs in one place is one the other
will take. It reports every problem it finds rather than the first.

Installing one is shared the same way: both tools write a generation through
the same program, so its ownership, its modes, and the check made against the
installed copy do not depend on which of them put it there.

- Every file in the table is present, except the optional time server.
- Nothing else is: a stray file — a working copy of a key, an editor's backup —
  is refused rather than carried onto a device, and so is a link out of the
  generation.
- The modes in the table are what the tools install; what is *enforced* is that
  neither secret is readable by anyone but its owner, that nothing is writable
  by group or other, and that no file is executable. A stricter mode is fine.
- Each file is what it claims to be: a DNS label, 32 hex digits, an OpenSSH
  private key, PEM certificates, a supplicant configuration naming a country
  and at least one network, an access list admitting at least one key.
- No address is plaintext, and the collector's trust anchor is the one this
  generation carries.
- The files this system reads itself — `app/fetch.conf` — are read by the check
  and by the device through one function, so a spelling accepted here resolves
  to the same value there. Its grammar: `KEY=value`, one key to a line, leading
  space and space around the value ignored, the first assignment of a key
  winning. The rest of the table is read by the program that owns the format —
  sshd, `systemd-timesyncd`, `systemd-journal-upload`, `wpa_supplicant` — and
  the check reads those the way those programs do.

None of this can tell whether the credentials are the *right* ones. That is
what trialling a generation is for.

## Installing the first one

The first generation goes on at flash time, from the workstation, with the
persistent partition mounted or named directly:

```
sudo scripts/provision.sh /dev/disk/by-partlabel/persistent path/to/generation
sudo scripts/provision.sh /mnt/persistent path/to/generation
sudo scripts/provision.sh -n /mnt/persistent path/to/generation   # check only
```

It refuses a partition whose label is not `persistent`, refuses a device that
already holds a generation — after the first, a change is a transaction on the
running device — and installs the generation committed, with no trial, because
a first generation has nothing to fall back to and no boot to be tried on. What
it writes is owned by root with the modes above, whatever the working copy was,
and it checks the installed copy against the contract again before making it
the committed one.

## What the device does with it

`brenn-config-select.service` resolves one generation early in boot — before
the journal opens, before the network comes up, before sshd — and publishes it
at `/run/brenn/provisioning`. Every service reads that path and none of them
read `/data/provisioning`, so nothing has to be reconfigured when the selected
generation changes, and nothing that started earlier in a boot can be
undermined by a change made later in it.

Selection:

- No trial: the committed generation runs.
- A trial, not yet attempted: the marker is written and flushed, and the
  candidate runs. Reaching the system health gate commits it.
- A trial that has already been attempted: an earlier trial boot ended without
  committing — it crashed, lost power, or was rebooted by the deadman timer —
  so the candidate is discarded and the committed generation runs.
- A trial whose attempt cannot be recorded — a partition that is full or has
  gone read-only — is not taken up at all. A candidate that could be tried
  without leaving a record would be tried on every boot forever, so it is
  refused and left in place for a later boot.

The marker means something only while a candidate is present. Committing a
generation removes the candidate and so retires the marker with it; a marker
found with no candidate — left by a commit, or by a discard that lost power
half way — is cleared, because a marker outliving its candidate would make the
next candidate look like one that had already failed.

## Changing it, on the device

Every change after the first is a transaction on the running device:

```
scp -r generation unit:/tmp/gen
ssh unit /usr/lib/brenn/brenn-config-apply -n /tmp/gen   # check only
ssh unit /usr/lib/brenn/brenn-config-apply /tmp/gen      # install and reboot into it
```

`brenn-config-apply` checks the candidate against the contract above, installs
it as the next generation — owned by root, with the modes the device requires,
checked again once installed — marks it as the candidate, and reboots. The boot
that follows runs it. Reaching the health gate commits it: the candidate
becomes the committed generation, and the one it replaces stays as history. Not
reaching the gate within ten minutes reboots the device, and that boot runs the
generation that was committed before, because the candidate's attempt is
already on record.

The health gate is the same one an operating-system update commits on: the
device has an address and it accepts a connection. It cannot tell whether the
new configuration is *right*, only whether the device can still be reached to
change it again — which is the failure that matters, since a device that cannot
be reached is a device that has to be taken apart.

Only one such transaction runs at a time. A configuration change is refused
while an update is being installed, staged, or on trial, and an update is
refused while a configuration change is on trial: both are judged by the same
gate, so a failed boot with two changes in flight would say nothing about which
one was wrong.

Writing a slot pair takes minutes, and until the flip is staged at the end of
it there is nothing on the device that says so, which is why the update records
that it has started. The record is on the runtime filesystem, so an install
that died leaves nothing behind a reboot: if a configuration change is refused
for an install that is no longer running, reboot — nothing was staged, so the
reboot lands where the device already was.

`--no-reboot` installs the candidate and leaves the reboot to the caller, for
doing several things in one window.

The device's identity is taken from the selected generation at the same moment:
the machine id before anything has logged, and the host name before any link is
configured, so that the address lease registers the provisioned name. Both fall
back to what the image carries — a transient machine id, a placeholder host
name — if the generation does not supply them.

The wireless supplicant, the time client and every other consumer read their
configuration from the published path, and each is conditioned on the file it
needs being there. A device missing one of them starts without that piece
rather than failing to start.

A device with no usable generation boots. It has no network credentials and no
host keys, so it is reachable only over the serial console — which is the
intended outcome, rather than a device that generates its own host keys and
listens.

Logs are held in RAM and uploaded to the collector the generation names, over
TLS to the trust anchor it carries. A collector that cannot be reached is
retried, with the interval growing to a ceiling and no limit on how long that
goes on; the logs waiting to be sent are bounded by the memory the journal is
allowed and nothing else. A device with no `journal/upload.conf` does not
upload, and its logs end at the next reboot.

## Where the values live

Not here. The generation for a device is assembled outside this repository,
from whatever the operator uses for secrets, and copied onto the writable
partition: at flash time for the first one, over SSH for every one after. Where
this repository has to write an address down — in a document, an example or a
test — it is a placeholder such as `journal.example.internal`.
