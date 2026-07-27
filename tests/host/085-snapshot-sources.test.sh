#!/usr/bin/env bash
#
# The apt source template the root filesystem is bootstrapped from.
#
# The Debian archive is pinned to a snapshot.debian.org timestamp, and a
# snapshot Release file carries a validity window of about a week. Past that,
# apt refuses the archive as expired unless the freshness check is waived — so
# without the waiver, reproducibility is only available for a commit less than
# seven days old, which is the opposite of what pinning the snapshot buys.
#
# apt spells that waiver `Check-Valid-Until: no` in a deb822 sources file, and
# silently ignores any field it does not recognise. A waiver written under the
# wrong field name therefore reads as correct and does nothing. The builder's
# own template writes it as `Options: check-valid-until=no` — the one-line
# format's inline spelling, which in a deb822 file is exactly that silent
# no-op — so the tree carries a corrected fork of it.
#
# This holds the fork to the correct spelling, to the upstream text it forked
# from, and to being what the build actually renders and bootstraps from.

set -uo pipefail

# shellcheck source=tests/lib/assert.sh
. "${BRENN_TESTS_LIB}/assert.sh"

fork="${BRENN_REPO_ROOT}/image/layer/brenn/apt/trixie-snapshot.sources"
upstream="${BRENN_REPO_ROOT}/rpi-image-gen/templates/debian/apt/trixie-snapshot.sources"
base_layer="${BRENN_REPO_ROOT}/image/layer/brenn/base.yaml"
fork_layer="${BRENN_REPO_ROOT}/image/layer/brenn/debian-snapshot.yaml"
builder_layer=debian-trixie-arm64-minbase-snapshot

# A requires list continues over indented comment lines, and ends at the next
# metadata field or at the end of the block — not merely at the first
# non-comment line, which would fuse `METAEND` onto the last entry.
layer_requires() {
	awk '
		/^# X-Env-Layer-Requires:/ {
			sub(/^# X-Env-Layer-Requires:[[:space:]]*/, "")
			collecting = 1
			printf "%s", $0
			next
		}
		collecting && /^#[[:space:]]/ && !/^#[[:space:]]*(X-Env-|METAEND)/ {
			sub(/^#[[:space:]]*/, "")
			printf "%s", $0
			next
		}
		collecting { exit }
	' "$1" | tr -d '[:space:]' | tr ',' '\n'
}

# Everything below this point holds the fork's *content* correct, and all of it
# would still pass if the build rendered the builder's template instead. The fix
# hangs on three one-line wiring entries — the base layer's requires entry, the
# forked layer's generator argument, and the mirror it then bootstraps from —
# each of which a revert or a merge-conflict resolution could undo on its own,
# with nothing red until a snapshot pin ages past its validity window and the
# original confusing expired-Release failure returns. Asserted first because
# these read only the tree and hold on any host.

# A layer selects another by naming it in a requires list; a config selects one
# by naming it in its `layer:` map. Prose that names the layer the fork replaces
# is neither, so metadata descriptions and comments are excluded — a guard that
# fired on those would report a broken build over a documented one.
selectors=""
while IFS= read -r yaml; do
	rel=${yaml#"${BRENN_REPO_ROOT}/"}
	if layer_requires "$yaml" | grep -qxF "$builder_layer"; then
		selectors+="${rel}: named in a requires list"$'\n'
	fi
	if sed 's/#.*//' "$yaml" | grep -qF "$builder_layer"; then
		selectors+="${rel}: named in the yaml body"$'\n'
	fi
done < <(find "${BRENN_REPO_ROOT}/image" -type f -name '*.yaml' | sort)

t_eq_text "nothing under image/ selects the builder's snapshot layer" \
	"${selectors%$'\n'}" ""

t_contains "the base layer requires the forked snapshot layer instead" \
	"$(layer_requires "$base_layer")" "brenn-debian-snapshot"

# The generator argument is the file the build actually renders, resolved
# against the builder's source root — which is image/ (`scripts/build-image.sh`
# passes it as -S). Pointed at the builder's own template, which carries the
# same name one directory tree over, everything else here still passes.
srcroot="\${SRCROOT}"
generator=$(sed -n 's/^#[[:space:]]*X-Env-Layer-Generator:[[:space:]]*//p' "$fork_layer" | head -n1)
generator_src=${generator#snapgen }
generator_src=${generator_src//"$srcroot"/"${BRENN_REPO_ROOT}/image"}
t_eq "the forked layer renders the forked template" \
	"$generator_src" "$fork"

# The rendered template appears in the build tree under the source file's
# own name; a mirror entry naming any other file bootstraps from something
# this test never looked at.
mirror=$(awk '
	/^[[:space:]]*mirrors:/ { collecting = 1; next }
	collecting && /^[[:space:]]*-/ {
		sub(/^[[:space:]]*-[[:space:]]*/, "")
		print
		exit
	}
' "$fork_layer")
t_eq "and bootstraps from the file the generator writes" \
	"$(basename "$mirror")" "$(basename "$fork")"

if [ ! -f "$fork" ]; then
	t_fail "the forked template is in the tree" "nothing at ${fork}"
	t_done
fi

# The fix's spelling, in terms that need no parser, so the assertion that holds
# it runs on a developer's machine and not only in CI. Close to a restatement of
# the fork, and deliberately so: this is what was red against the template the
# build consumed before it, and it stays red for any future simplification back
# to the ignored spelling.
t_eq "the fork waives the Release freshness check on both of its stanzas" \
	"$(grep -c '^Check-Valid-Until:[[:space:]]*no$' "$fork")" 2
t_eq "and never as an Options field, which deb822 ignores in silence" \
	"$(grep -c '^Options:' "$fork")" 0

t_builder_file "$upstream" \
	"the builder's snapshot template is where the fork expects it" \
	"if the bump moved or renamed it, the fork has to follow"

# The fork's own obsolescence, announced rather than left to archaeology. A
# failure and not a skip: this is precisely the state in which carrying a fork
# stops being justified. Ahead of the parser dependency too, because a submodule
# bump is something a developer does locally, and this is the signal that bump
# should produce.
if [ "$(grep -c '^Options:' "$upstream")" -gt 0 ]; then
	t_pass "the builder's template still writes the waiver as an ignored Options field, so the fork is still needed"
else
	t_fail "the builder's template still needs forking" \
		"upstream no longer writes the waiver as an Options field — the fork has done its job." \
		"Delete image/layer/brenn/apt/trixie-snapshot.sources and image/layer/brenn/debian-snapshot.yaml," \
		"point image/layer/brenn/base.yaml back at debian-trixie-arm64-minbase-snapshot, delete this" \
		"test, and close TODO(snapshot-sources-upstream)."
fi

# The parser the builder's generator itself uses, so the rest of this sees the
# fields the build sees. CI installs it for the layer lint, so the skip is never
# CI's path.
python3 -c 'import debian.deb822' >/dev/null 2>&1 ||
	t_skip "requires python3-debian, which is not installed (installed and enforced in CI)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

status=0
python3 - "$fork" "$upstream" "$tmp" >"${tmp}/counts" <<'PY' || status=$?
import sys

from debian import deb822

fork_path, upstream_path, outdir = sys.argv[1:4]


def stanzas(path):
    with open(path, encoding="utf-8") as f:
        return list(deb822.Deb822.iter_paragraphs(f.read()))


def option_to_field(name):
    """The deb822 field an inline-format option name maps to."""
    return "-".join(word.capitalize() for word in name.split("-"))


def canonical(paragraphs, fold_options):
    """Stanzas as sorted field lines, optionally with Options folded into the
    deb822 fields apt reads them as, so two spellings of one source compare
    equal and anything else shows up as a diff."""
    out = []
    for stanza in paragraphs:
        fields = {k: " ".join(v.split()) for k, v in stanza.items()}
        if fold_options:
            for option in fields.pop("Options", "").split():
                key, _, value = option.partition("=")
                fields[option_to_field(key)] = value
        out.append("\n".join("%s: %s" % (k, fields[k]) for k in sorted(fields)))
    return "\n\n".join(out) + "\n"


ours = stanzas(fork_path)
theirs = stanzas(upstream_path)

snapshot = [s for s in ours if "snapshot.debian.org" in s.get("URIs", "")]
waived = [s for s in snapshot if s.get("Check-Valid-Until", "").strip().lower() == "no"]

with open(outdir + "/fork.canonical", "w", encoding="utf-8") as f:
    f.write(canonical(ours, fold_options=False))
with open(outdir + "/upstream.canonical", "w", encoding="utf-8") as f:
    f.write(canonical(theirs, fold_options=True))

print(len(snapshot), len(waived))
PY

if [ "$status" -ne 0 ]; then
	t_fail "both templates parse as deb822" \
		"python3 exited ${status} — see the traceback above"
	t_done
fi
read -r n_snapshot n_waived <"${tmp}/counts"

# Which stanzas those waiver lines belong to, which a line count cannot say.
t_eq "the fork draws the archive and the security archive from the snapshot service" \
	"$n_snapshot" 2
t_eq "and every stanza that does carries the waiver" \
	"$n_waived" "$n_snapshot"

# A fork that drifts from what it forked from is a base system quietly
# diverging from the one the builder intends. A bump that changes suites,
# components, keyring or URIs lands here, naming both files, rather than in the
# image.
t_eq_text "the fork differs from the builder's template only in how the waiver is spelled" \
	"$(cat "${tmp}/fork.canonical")" "$(cat "${tmp}/upstream.canonical")"

t_done
