#!/usr/bin/env bash
# Refresh the pins of recipes after editing them, like updpkgsums: manifest
# digests, and the size and digest of every source, from the files next to
# each recipe and from downloads of its source URLs.
#
# usage: tools/update-pins.sh [PATH...]    (default: recipes)
#
# Downloads go to .cache/distfiles/NAME and are reused. A recipe directory
# with an executable sources.sh generates its sources there instead (see
# recipes/system/cps). Toolchain pins are not touched: they name a seed
# catalog, see docs/bootstrap.md.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
cps=$(cps_binary)
(($#)) || set -- "$top/recipes"
distfiles=$cache/distfiles
mkdir -p -- "$distfiles"

mapfile -t recipes < <("$cps" recipe order "$@" 2>/dev/null)
for recipe in "${recipes[@]}"; do
    [[ $recipe == *.in ]] && continue
    dir=$(dirname -- "$recipe")
    if [[ -x $dir/sources.sh ]]; then
        "$dir/sources.sh" "$distfiles"
    fi
    # source "NAME" ... url="URL"
    sed -n 's/^    source "\([^"]*\)".* url="\([^"]*\)".*/\1 \2/p' "$recipe" |
    while read -r name url; do
        [[ -f $dir/$name || -f $distfiles/$name ]] && continue
        note "downloading $url"
        curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
            -o "$distfiles/$name.part" -- "$url"
        mv -- "$distfiles/$name.part" "$distfiles/$name"
    done
done
"$cps" recipe repin --manifests --local-sources --sources "$distfiles" "$@"
