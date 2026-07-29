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
| `ca/brenn-ca.pem` | 0644 | Conditional. PEM certificate: the trust anchor for every HTTPS connection the device makes, including ones the application payload makes. Required as soon as either of the two files below is present, and pointless without them. |
| `rauc/keyring.pem` | 0644 | PEM certificate. Verifies operating-system update bundles; an update that does not verify against it is not installed. |
| `journal/upload.conf` | 0644 | Optional. `systemd-journal-upload.conf(5)`, with an `[Upload]` section. `URL=` is the collector, and it is `https://` — there is no plaintext option. `TrustedCertificateFile=` names the trust anchor above *through the published path*, `/run/brenn/provisioning/ca/brenn-ca.pem`, since this image carries no distribution certificate store. **Absent means nothing collects this device's logs**, and the journal is in RAM, so they end at the next reboot — an operator's choice to make deliberately, not a file to leave out by accident. |
| `app/fetch.conf` | 0644 | Optional. Where the application payload comes from: `URL=`, which is `https://`, and `SHA256=`, 64 hex digits, the digest expected of what it returns. Both are required together — the transport says who served the payload, the digest is what says what was served, and a payload that does not match it is discarded rather than run. Absent means the base system runs and no application does. |

The trust anchor is whatever the device's endpoints chain to. A public root —
the one a certificate issued by a public authority chains to — is as legitimate
an anchor as a private one, and needs no machinery beyond putting it in this
file. What not to put there is a *leaf* certificate: a short-lived server
certificate pinned as the anchor works until it is renewed and then stops
verifying, silently, at whichever endpoint it belonged to. The image ships no
distribution certificate store at all, so this file is the whole of the device's
HTTPS trust — narrower than a bundle of every public root when a site runs its
own authority, and exactly the one public root when it does not.

On the device, every file is owned by `root`, and so is every directory on the
path to it — none of them group- or world-writable. sshd refuses to read an
access list reachable through a directory somebody else could replace, and it is
right to. A working copy on a workstation has no such requirement: it may be
owned by whoever assembles it, the modes in the table are what matters there,
and ownership is set by the tool that installs it. The two files at mode 0600
are secrets; the rest are readable because services that are not root read them.

A generation is complete or it is not installed. The entries marked optional are
features a site may not have — no local time server, no log collector, no
application payload yet — and leaving one out configures the device without that
piece rather than with a default in its place. Everything else has no fallback
worth having: a device that cannot be told which network to join has nothing to
fall back on, and an image carrying a default would be an image carrying site
configuration.

## What is checked before one is installed

Everything above is enforced, by one program — `brenn-config-validate` — which
runs both on the workstation assembling a generation and on the device
accepting a change, so a generation that installs in one place is one the other
will take. It reports every problem it finds rather than the first.

Installing one is shared the same way: both tools write a generation through
the same program, so its ownership, its modes, and the check made against the
installed copy do not depend on which of them put it there.

- Every file in the table is present, except the ones marked optional.
- An endpoint that is configured has an anchor to verify it against: a
  generation carrying `journal/upload.conf` or `app/fetch.conf` and no
  `ca/brenn-ca.pem` is refused, because the connection it describes could never
  succeed. An anchor with no consumer is accepted — trust staged for a later
  change does nothing until something names it.
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

How the image gets onto the medium in the first place, and where this step sits
in that procedure, is `docs/install.md`.

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

## Where the values live, and how a generation is assembled

Not here. The generation for a device is assembled from inputs outside this
repository, and the result is copied onto the writable partition: at flash time
for the first one, over SSH for every one after. Where this repository has to
write an address down — in a document, an example or a test — it is a
placeholder such as `journal.example.internal`.

What *is* here is the machinery. `scripts/assemble-generation.sh` composes a
generation from a unit's plain-text configuration and the operator's secret
material, and hands the result to `scripts/provision.sh -n` before calling it
assembled — so an assembly that succeeds is a generation the device will take.
It lives beside the contract on purpose: it reads the file list, the
secret/public classification and the patterns out of the same program the device
runs, so a change to the contract cannot leave the assembler producing
generations the device then refuses.

```
scripts/assemble-generation.sh <unit-dir>            # build it
scripts/assemble-generation.sh -f <unit-dir>         # rebuild, replacing
scripts/assemble-generation.sh -o <dir> <unit-dir>   # write it somewhere else
```

`<unit-dir>` is the directory holding one unit's `unit.conf` — the file itself
may be named instead — and the directory's *name* is the unit's name, which is
what the store below files that unit's identity and secrets under. Where those
directories live is the operator's business: this repository carries no unit
configuration and points at none.

A run refuses until every input is present and well formed, and reports
everything wrong in one pass rather than one problem per run — gathering the
material is one trip. Nothing is written while anything is outstanding.

### The unit's configuration

`<unit-dir>/unit.conf` is the non-secret half: host name, regulatory domain,
endpoints. It is worth keeping a history of and is not a credential, so it can
live in version control. Sourced as shell, `KEY=value`, one to a line.

| Key | Content |
|---|---|
| `UNIT_HOSTNAME` | Required. The `hostname` above: one DNS label. |
| `WIFI_COUNTRY` | Required. The two-letter regulatory domain the radio operates under. No image carries a default, because a radio's legal channels are a property of where it is. |
| `WIFI_SCAN_SSID` | `1` if the network does not broadcast its name, `0` otherwise (the default). Nothing else is accepted: a spelling of *yes* would read as "the network is broadcast" and produce a unit that never finds a hidden one. |
| `NTP_SERVER` | A local time server, or empty for the public pool. Empty leaves `net/ntp.conf` out. |
| `JOURNAL_URL` | The collector, `https://`, or empty. Empty leaves `journal/upload.conf` out — **and then nothing collects this device's logs**. |
| `APP_URL`, `APP_SHA256` | The payload address and the digest expected of it, or both empty. Both together leave `app/fetch.conf` out; one without the other is refused, because an address with no digest fetches whatever is served and a digest with no address is a decision half made. |

A key this table does not name is refused, by name. The file is read in a shell
of its own holding nothing but these seven, so nothing it sets reaches the
assembler's own state — and a misspelled key stops the run instead of reading as
a feature deliberately left out, which for the optional ones is a legal
configuration nothing further along would question.

The three values interpolated raw into drop-ins — the two addresses and the time
server — are refused if they hold whitespace or a control character. A space in
one of them assembles cleanly, passes the contract check, and produces a unit
that boots, associates and quietly uploads nothing.

### The operator's store

Everything secret, and the unit's generated identity. `~/.brenn-provisioning` by
default, `BRENN_PROVISIONING_STORE` to put it elsewhere. The store and everything
in it is created private.

```
<store>/<unit>/
  inputs/wifi.conf              SSID= and PSK= (a passphrase, or 64 hex digits)
  inputs/authorized_keys        the public keys admitted to the device as root
  inputs/brenn-ca.pem           the HTTPS trust anchor, when an endpoint is configured
  inputs/rauc-keyring.pem       the certificate update bundles are verified against
  identity/machine-id           generated once, then reused
  identity/ssh_host_ed25519_key generated once, then reused
  generation/                   the assembled output
```

The split is the point: **the unit's configuration is plain text and the store is
not.** One is reviewable, diffable and worth reading in a pull request; the other
is a device's host key, its wireless credentials and its access list.

Where the store lives is the operator's decision, and the default is the
conservative one: a directory in the operator's home, tracked by nothing. The
alternative is legitimate and worth naming, because the store holds the one thing
here that cannot be regenerated — a store tracked in a **private** repository is
backed up by `git push`, which is more backup than an untracked home directory
usually gets. What that choice costs:

- History is permanent and every clone carries it. A secret that lands in the
  wrong repository cannot be withdrawn from one, only rotated.
- Git records no file modes beyond the executable bit, so a fresh clone's store
  is only as private as the directories above it. The next assembly run
  re-tightens the store path to `0700` — it does that on every invocation — but
  until then the modes are whatever the clone's umask gave them.
- The store reaches whatever clones the repository, and that is rarely only the
  operator. Build and deploy automation that checks the repository out gets the
  material too, at the checkout's modes, in a workspace that may outlive the
  job and may build other people's code — and no assembly ever runs there, so
  the re-tightening above never fires. Before tracking a store, know what
  clones the repository; if that set includes machines the device's secrets
  should not reach, filter the checkout or keep the store somewhere else.

Generation file modes are unaffected either way: the assembler takes them from
the contract, never from the source file it copied.

A repository holding a store ignores the derived half of it and nothing else:
`generation/`, plus the `generation.new.*` and `generation.old.*` scratch
siblings an interrupted or killed assembly can leave beside it. Under a store
laid out as `store/<unit>/`, that is three patterns:

```
store/*/generation/
store/*/generation.new.*
store/*/generation.old.*
```

Nothing else, and in particular no pattern that also matches `inputs/` or
`identity/`: those are the irreproducible half, and an ignore rule over them
lets `git add`, commit and push all succeed while backing up none of it, saying
so nowhere. A left-behind `generation.old.*` is a whole previous generation,
secrets included, which is why the scratch patterns are here rather than left to
a `git status` that would offer them for commit.

What is *not* an operator choice: the store never goes inside this repository.
This tree is public, and its gates would refuse the material.

`inputs/wifi.conf` is the operator's own file rather than one of the
generation's, and its two values are read as the whole rest of their line, byte
for byte. A network name or a passphrase may legally contain spaces, and a
reader that trimmed them would hash the right words against the wrong network
and produce something that looks perfectly valid. What the rendered
`ssid="…"` cannot carry is refused instead: a name over 32 bytes or holding a
double quote or a control character, a passphrase outside 8 to 63
printable-ASCII bytes. The escape hatch for anything else is to supply the
pre-shared key itself, as 64 hex digits.

`inputs/brenn-ca.pem` is demanded exactly when the unit configures something
that would read it, and the refusal names which value did. An anchor in the
store with nothing to consume it is still carried into the generation — trust
staged ahead of the endpoint that will use it is harmless, and it is one fewer
reassembly later. `inputs/rauc-keyring.pem` is demanded unconditionally: A/B
slots exist from the first boot, and a device that can verify no update bundle
can only be changed by being taken apart.

### Identity is generated once

The machine id and the SSH host key are made on the unit's first assembly and
then reused forever. They are what say a device is *the same device* — the name
its logs are filed under, and the key an administrator's client remembers — so a
reflash restores them rather than minting new ones. That is the whole reason
they are provisioned instead of generated on the device.

Losing `identity/` means every consumer upstream sees a new machine and every
client warns about a changed host key. **The store is the thing to back up.**

### Two files the assembler composes

Neither is copied from an input, so what they mean is worth knowing:

- The supplicant configuration carries `ctrl_interface=`, because the device's
  wireless test lane drives the radio through `wpa_cli` and the supplicant opens
  that socket only if its configuration names one. Without it a unit associates
  and cannot be asked whether it did.
- A wireless passphrase is turned into the pre-shared key before it is written —
  802.11i's PBKDF2-HMAC-SHA1 over the passphrase, salted with the network name,
  4096 iterations, 256 bits. The key is what the radio needs; the words behind it
  would be one more secret sitting on a device for nothing. The derivation runs
  in-process rather than through `wpa_passphrase`, which takes the passphrase
  only as a command-line argument, and an argument list is readable through
  `/proc` by every other process on the workstation. A 64-hex `PSK=` is already
  the key and is used as it stands.

### The update-signing keypair

`rauc/keyring.pem` is the one piece of trust material an operator has to create
rather than obtain. It is not a certificate authority and there is nothing to
run: it is a single self-signed certificate, and the private half is what
`make bundle` signs with.

```
openssl req -x509 -newkey rsa:4096 -sha256 -noenc -days 10950 \
  -subj "/CN=brenn-os update signing" \
  -keyout brenn-os-signing.key -out brenn-os-signing.crt
chmod 0600 brenn-os-signing.key
```

The certificate goes into the store as `inputs/rauc-keyring.pem`, and the same
file is `BRENN_BUNDLE_KEYRING` when a bundle is built; the key is
`BRENN_BUNDLE_KEY` and the certificate `BRENN_BUNDLE_CERT`. RSA and ECDSA are
both well-trodden here; the thirty-year validity is deliberate, because RAUC
checks the signing certificate's validity at install time and a device that
outlives its keyring certificate stops accepting updates on a date nobody wrote
down.

The private key is not per-unit and the assembler never reads it, so it does not
belong in `inputs/`. Where it lives is the operator's call, at mode 0600 and
backed up: losing it means no device already carrying its certificate can ever
be updated again, and it is the only key in this system with that property.

Certificates from a public authority cannot do this job, which is why the
keyring is the one thing not covered by the trust-anchor discussion above. A
public authority issues TLS *server* certificates; it does not sign artifacts.
Signing bundles with such a leaf's key fails in ninety days, when the
certificate expires and every deployed device begins refusing every update. And
putting a public *root* in the keyring would mean any holder of any certificate
that authority ever issued could sign an operating system this device installs.
The keyring has to be material the operator alone controls.
