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

## `snapshot-sources-upstream`

The apt sources template the root filesystem is bootstrapped from is a fork of
the image builder's own (`image/layer/brenn/apt/trixie-snapshot.sources`, with
`image/layer/brenn/debian-snapshot.yaml` rendering it). The two differ in one
field: upstream waives the snapshot Release freshness check with `Options:
check-valid-until=no`, which is the one-line sources format's spelling of the
option and is silently ignored in a deb822 file, so the waiver never takes
effect and no commit older than about a week rebuilds. The correct deb822
spelling is `Check-Valid-Until: no`.

Deferred as a fork rather than fixed in place because the builder is a pinned
submodule of an upstream project, and waiting on upstream review leaves the
build broken meanwhile. `tests/host/085-snapshot-sources.test.sh` holds the
fork to upstream's text apart from that field, so a submodule bump cannot drift
it quietly.

Done when the builder's own template carries the correct field — at which point
that test fails on purpose, saying so — and the fork, its layer, and the
`Requires` entry that selects it are removed.

## `local-image-lane`

`make image` needs an arm64 Debian host, so on a host that is not one the
builder runs in a pinned container (`containers/builder/Containerfile`) with the
repo bind-mounted and arm64 execution riding the host's binfmt_misc
registration. That much is built, and a workstation that is neither arm64 nor
Debian-family builds an image with it.

What is not yet shown is the half this entry exists for: that the local build
and CI's native arm64 build produce the same image. Until they are compared, a
green local build is evidence about the local lane only, and the posture the
rest of the repo is built on — the local gate is the authority, CI is the
backstop — still does not hold for the image.

Deferred because what remains is a cross-lane comparison in CI, at manifest
level first and hardening to full-image equality once the two lanes are observed
to agree, rather than a change to the build. That comparison is now built — the
`image-container` and `image-identity` jobs, over what
`scripts/image-manifest.sh` records — and what it reports on its first runs is
the measurement this entry is waiting on.

Done when `make image` runs on a developer workstation that is not an arm64
Debian host and produces the same image CI does.

## `ci-container-toolchain`

CI's native image job installs the builder's host dependencies with the
submodule's own `install_deps.sh`, which takes whatever version the runner's
archive serves on the day. It is the last unpinned toolchain in the image lane:
the container lane pins its base by digest, its packages by snapshot timestamp,
and its SBOM scanner by version and digest, and the same build run through it
would close the gap for CI too.

Deferred because moving the release-shaped lane onto the container is only worth
doing once the container lane has a record of producing the same image the
native one does, which is what the `image-identity` job is there to establish.

Done when no CI job invokes `install_deps.sh` and the native image build runs in
the pinned container.

## `vendor-enabled-units`

`tests/image/190-enabled-units.test.sh` reads the enablement links under
`/etc/systemd/system` whole and holds them to a reviewed set, which is what
catches an installed package's preset putting a service on every boot. Packages
can also ship static `.wants` links of their own under
`/usr/lib/systemd/system`, and that tree is not read: a package that enables
itself that way starts on the device with nothing in the suite saying so.

Deferred because closing it means recording a second reviewed set — the image
carries over fifty such links from the Debian base — and this repo's bring-up
discipline puts that review in front of a person rather than letting a first run
bake in whatever it happened to find.

Done when the vendor tree's enablement links are reviewed and asserted as a
whole set, the way the `/etc` ones are.

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
