# The provisioning contract, as data, and the operations every program that
# touches a generation shares. Sourced, not executed.
#
# A generation is written by two programs — one at flash time on a workstation,
# one on the running device — checked by a third, and applied by a fourth at
# boot. What a generation must contain, which of its files are secret, and what
# a host name or a machine id looks like are one contract between the four. A
# second copy of any of it is a device that accepts what the bench refuses, or
# applies nothing where the bench saw a valid value.

# shellcheck shell=sh disable=SC2034  # the tables are read by what sources this

# Every file a generation carries, as `path:class`. `secret` means readable by
# nobody but root: the installer sets the mode from this list and the check
# refuses anything looser. `public` means readable by the services that are not
# root, and writable by nobody else.
BRENN_CONTRACT_REQUIRED="hostname:public
machine-id:public
net/wpa_supplicant-wlan0.conf:secret
ssh/ssh_host_ed25519_key:secret
ssh/ssh_host_ed25519_key.pub:public
ssh/authorized_keys:public
rauc/keyring.pem:public"

# What a site may leave unsaid. Absent means the feature is not configured — not
# that something stands in for it — and each consumer is conditioned on its own
# file being there, so a device provisioned without one starts without that
# piece:
#
#   net/ntp.conf         the distribution's public pool sets the clock.
#   journal/upload.conf  nothing collects the logs, and the journal is in RAM,
#                        so they end at the next reboot.
#   app/fetch.conf       the base system runs and no application does.
#   app/client.crt       the unit's TLS client certificate and its key, which
#   app/client.key       the fetch presents: the payload server admits only a
#                        unit holding one that its authority issued. Present exactly
#                        when app/fetch.conf is, which the check enforces in
#                        both directions.
#   ca/brenn-ca.pem      no HTTPS trust is staged. Required as soon as
#                        journal/upload.conf or app/fetch.conf is present, which
#                        the check cross-checks: the image carries no
#                        distribution certificate store, so an endpoint with no
#                        anchor in the generation has nothing to verify against.
#
# The update keyring is not on this list. A/B slots exist from the first boot,
# and a device that can verify no bundle can only be changed by being taken
# apart.
BRENN_CONTRACT_OPTIONAL="net/ntp.conf:public
ca/brenn-ca.pem:public
journal/upload.conf:public
app/fetch.conf:public
app/client.crt:public
app/client.key:secret"

BRENN_CONTRACT_DIRECTORIES="net ssh ca rauc journal app"

# A single DNS label, and 32 hex digits. The boot-time selector applies these
# values and the check refuses them, so the two have to agree exactly: a name
# the check accepts and the selector then rejects is a device that comes up
# under the image's default identity and says so only in its log.
BRENN_RE_HOSTNAME='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
BRENN_RE_MACHINE_ID='^[0-9a-f]{32}$'

# Read the first line of a file with surrounding space removed. Every value a
# generation carries is a single token on a line of its own.
brenn_first_line() {
	head -n1 "$1" | tr -d '[:space:]'
}

# The value of `KEY=` in one of the generation's own `key=value` files, empty if
# the file does not name it. The first assignment wins and space around the
# value is not part of it: one key on one line is the whole grammar, and a file
# with two of them is one somebody edited without deciding — taking the first is
# at least the same answer every time.
#
# The check reads a candidate through this and the device reads the selected
# generation through it too, so a spelling the bench accepts is a spelling the
# device understands identically. Files that some other program parses — the
# systemd drop-ins a generation carries — are read the way that program reads
# them, not with this.
brenn_conf_value() {
	sed -n "s/^[[:space:]]*${2}=[[:space:]]*//p" "$1" | head -n1 | tr -d '[:space:]'
}

# Flush paths to the medium. The attempt record is the whole one-shot
# mechanism: if it is still in page cache when the power goes, a failed trial
# gets a second boot instead of reverting. A file that has just been created is
# flushed together with the directory it was created in, because the entry
# naming it is the directory's data and not the file's.
#
# Never fatal. Every caller flushes after a rename that has already taken
# effect, so a failure here would report a transaction that did not happen —
# and the caller would skip the reboot that was to try it.
brenn_flush() {
	sync "$@" 2>/dev/null || sync || true
}
