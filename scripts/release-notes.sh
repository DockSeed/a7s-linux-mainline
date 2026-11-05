#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Print the section of CHANGELOG.md for a release tag: the lines below the
# heading "## [<version>-<R|T><n>]" (optionally followed by " - <date>") up
# to the next "## " heading. Fails when the tag is not v<X.Y.Z>-R<n> or
# v<X.Y.Z>-T<n>, or when its section is missing or empty. Runs on the host.
#
# Usage: scripts/release-notes.sh <tag> [<changelog>]
set -euo pipefail

tag=${1:-}
changelog=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CHANGELOG.md}

[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+-[RT][1-9][0-9]*)$ ]] || {
  echo "release-notes: '$tag' is not a release tag (v7.3.0-R1, v7.3.0-T1)" >&2
  exit 2
}
heading="## [${BASH_REMATCH[1]}]"
[ -f "$changelog" ] || { echo "release-notes: no $changelog" >&2; exit 1; }

# The section, without blank lines at its start and end. awk exits 3 when
# there is no such heading.
section() {
  awk -v h="$heading" '
    /^## / { if (on) exit; on = ($0 == h || index($0, h " - ") == 1); found = found || on; next }
    on
    END { if (!found) exit 3 }
  ' "$changelog"
}
notes=$(section) || { echo "release-notes: $changelog has no section '$heading'" >&2; exit 1; }
notes=$(printf '%s\n' "$notes" | sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac)

[ -n "$notes" ] || { echo "release-notes: the section '$heading' is empty" >&2; exit 1; }
printf '%s\n' "$notes"
