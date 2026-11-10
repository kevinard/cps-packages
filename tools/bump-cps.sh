#!/usr/bin/env bash
# Move the tree to another CPS commit: cps.pin, and the version, epoch, and
# source pins of recipes/system/cps/build.kdl. See CONTRIBUTING.md.
#
# usage: [CPS_SOURCE=PATH-or-URL] tools/bump-cps.sh COMMIT
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
commit=${1:?usage: tools/bump-cps.sh COMMIT}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die 'give the full 40-character commit ID'
source=${CPS_SOURCE:-$(sed -n 's/^CPS_URL=//p' "$top/cps.pin")}
sed -i "s/^CPS_COMMIT=.*/CPS_COMMIT=$commit/" "$top/cps.pin"
cps=$("$top/tools/cps.sh")
distfiles=$cache/distfiles
"$top/tools/cps.sh" --sources "$distfiles" >/dev/null
if [[ -d $source ]]; then
    epoch=$(git -C "$source" show -s --format=%ct "$commit")
else
    epoch=$(git -C "$cache/cps/git" show -s --format=%ct "$commit")
fi
recipe=$top/recipes/system/cps/build.kdl
sed -i -E "s/^(build architecture=\"[^\"]*\" epoch=)[0-9]+/\\1$epoch/" "$recipe"
# Each snapshot is a new package version: the upstream string names the
# commit, and the revision goes up so the published package ID changes too.
version=$(sed -n -E 's/^    version "([^"]*)" upstream=.*/\1/p' "$recipe")
[[ $version =~ ^(.*)-([0-9]+)$ ]] || die "cannot read the system/cps version from $recipe"
version="${BASH_REMATCH[1]}-$((BASH_REMATCH[2] + 1))"
sed -i -E "s/^(    version \")[^\"]*(\" upstream=\"0\\.1\\.0\\+git\\.)[0-9a-f]+\"/\\1$version\\2${commit:0:10}\"/" "$recipe"
"$cps" recipe repin --sources "$distfiles" "$recipe"
note "pinned CPS $commit as system/cps $version"
