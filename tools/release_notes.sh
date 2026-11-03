#!/bin/sh
# The notes of a release: the section of CHANGELOG.md for a version, plus a
# pointer to the upgrade notes. Usage: tools/release_notes.sh 0.2.1 > /tmp/notes.md
set -e
v=${1:?usage: release_notes.sh X.Y.Z}
cd "$(dirname "$0")/.."
awk -v v="$v" '/^## /{p=($2==v); if(p) next} p' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > /tmp/release_notes.$$
[ -s /tmp/release_notes.$$ ] || { echo "no section for $v in CHANGELOG.md" >&2; rm -f /tmp/release_notes.$$; exit 1; }
cat /tmp/release_notes.$$
printf '\nUpgrade notes: docs/upgrading.md (section %s).\n' "$v"
rm -f /tmp/release_notes.$$
