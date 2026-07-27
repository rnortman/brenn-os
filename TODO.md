# TODOs

Entries are slugs joined to `TODO(slug)` comments in the tree. See `CLAUDE.md`
for the convention — including that this file ships publicly.

## `example-placeholder` (DO NOT TRIAGE — this is a fake entry)

This is a placeholder entry. Leave it here so the file is never empty. It is not
a real TODO. You would reference it in code with a `TODO(example-placeholder)`
comment. That is the whole design: an entry here with a slug, joined to code
comments by that slug. Add real TODOs below this one, in this format.

## `rpi-archive-mirror`

The Raspberry Pi package archive publishes no snapshot service, so the kernel
and boot firmware are pinned by exact version in an apt preferences file
(`image/layer/brenn/apt/preferences.rpi-pin`). That pin is only as durable as
the archive's retention: once a pinned version is dropped from the archive, an
old commit no longer rebuilds, which is the one hermeticity hole left in the
image build.

Deferred because the fix is infrastructure — a mirror of the archive pool we
control, plus a way for the build to point at it — and the pin is enough to
make today's builds reproducible against today's archive.

Done when a build of an old commit resolves its pinned kernel without depending
on upstream retention.

## `erofs-root`

The root filesystem is read-only ext4. The image layout supports erofs behind a
single knob (`image.rootfs_type` in `image/config/brenn-common.yaml`), and erofs
is the starting point for a verified root: a compressed read-only image with a
dm-verity hash tree, so that tampering with a root slot is detectable rather
than merely inconvenient.

Deferred because ext4 is the layout's better-trodden path and the update
mechanism has to be proven on hardware before the root filesystem format is
also in flight. It is sequenced with the rest of the hardening work, not on its
own.

Done when the profile builds an erofs root, the update path installs it, and
the device suite asserts the root is verified.

## `unprivileged-admin`

Administration is done as `root` over SSH, key-only
(`image/layer/brenn/ssh.rootfs-overlay/etc/ssh/sshd_config.d/00-brenn.conf`).
The hardening step is an unprivileged administrator account with an explicit
policy for what it may escalate to, so that routine access is not also total
authority over the device.

Deferred because with no password on any account, no other account with a
shell, and public-key authentication as the only accepted method, this is
hygiene rather than a boundary — and bring-up is when the friction of getting
it wrong is highest. It belongs with the rest of the hardening work.

Done when routine access is an unprivileged account, escalation is explicit and
audited, and the device suite asserts that direct root login is refused.

## `native-tryboot-backend`

Boot-slot selection is driven by our own script
(`image/layer/brenn/rauc.rootfs-overlay/usr/lib/rauc/rpi-tryboot-backend`),
because no released RAUC speaks the Raspberry Pi firmware's tryboot mechanism
natively. Upstream support is in progress; when it ships, the script and the
`bootloader=custom` handler in `etc/rauc/system.conf` are replaced by the
built-in backend.

Deferred because the upstream work is not released and the mechanism is needed
now. The script is deliberately small and its whole decision table is asserted
off the device, so the swap is a contained one.

Done when the update path runs on the upstream backend and the script is gone.

## `rauc-ca-hierarchy`

Update bundles are signed with a single certificate and key pair, passed to
`scripts/make-bundle.sh` from outside the tree, and a device verifies a bundle
against that same certificate as its trust anchor. One pair for both roles
means the signing key cannot be replaced without reprovisioning every device,
and cannot be revoked at all.

Deferred because the alternative — a root certificate authority whose anchor is
what devices are provisioned with, issuing intermediates that sign releases —
is key-management infrastructure, and bring-up needs a signature that works
before it needs one that can be rotated. Bundles can be re-signed without
being rebuilt, so today's bundles are not a dead end.

Done when devices are provisioned with a root anchor, releases are signed by an
issued certificate rather than by the anchor itself, and revoking a signing key
does not require touching a device.

## `app-payload-signing`

An application payload is trusted because it arrived over TLS from a server the
device trusts and matched the digest the device was provisioned with
(`image/layer/brenn/app.rootfs-overlay/usr/lib/brenn/brenn-app-fetch`). A digest
answers for exactly one payload, so every release is also a configuration
change; a detached signature over the payload would answer for every release a
publisher ever issues.

Deferred because the trust model it would replace is sound for the deployment
this is being brought up on, and because the signing side of it belongs with the
same key hierarchy the update bundles will use rather than being invented
separately.

Done when a payload carries a signature, the device verifies it against a
provisioned public key before unpacking, and an unsigned payload is refused.
