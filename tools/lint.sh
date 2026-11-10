#!/usr/bin/env bash
# Policy checks for the recipe tree that cps itself does not make. See
# CONTRIBUTING.md for the rules.
#
#   - recipes live at recipes/CATEGORY/NAME/build.kdl (or build.kdl.in for a
#     recipe that still waits for a pin), and one of their manifests
#     produces the package CATEGORY/NAME
#   - every manifest is published by "canopa"
#   - no manifest ships or collects anything under /var
#   - every numeric uid and gid in a manifest is in docs/uids.md
#   - a concrete recipe or manifest has no @PLACEHOLDER@ left
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
cd -- "$top"

categories='apps build devel library system'
status=0
fail() { printf 'lint: %s\n' "$*" >&2; status=1; }

# The allocated IDs: table rows of docs/uids.md as "| name | uid | gid | ...".
uids=$(awk -F'|' 'NF > 4 && $3 ~ /^ *[0-9]+ *$/ { gsub(/ /, "", $3); print $3 }' docs/uids.md)
gids=$(awk -F'|' 'NF > 4 && $4 ~ /^ *[0-9]+ *$/ { gsub(/ /, "", $4); print $4 }' docs/uids.md)

while IFS= read -r -d '' file; do
    kind=$(sed -n '1s/^schema-version 1 kind="\([^"]*\)".*/\1/p' "$file")
    rel=${file#recipes/}
    case $kind in
        build-recipe)
            dir=${rel%/*}
            category=${dir%%/*}
            base=${rel##*/}
            [[ $base == build.kdl || $base == build.kdl.in ]] \
                || fail "$file: name a recipe build.kdl, one per directory"
            [[ $dir == */* && $dir != */*/* ]] || fail "$file: recipes live at recipes/CATEGORY/NAME/"
            [[ " $categories " == *" $category "* ]] || fail "$file: unknown category $category ($categories)"
            produced=$(sed -n 's/^    manifest "\([^"]*\)".*/\1/p' "$file" | while read -r manifest; do
                for candidate in "recipes/$dir/$manifest" "recipes/$dir/$manifest.in"; do
                    [[ -f $candidate ]] && sed -n 's/^package "\([^"]*\)".*/\1/p' "$candidate"
                done
            done || true)
            grep -Fxq "$dir" <<< "$produced" || fail "$file: no manifest produces package $dir"
            ;;
        package-manifest)
            grep -q '^package "[^"]*" publisher="canopa"' "$file" || fail "$file: publisher must be canopa"
            if grep -nE '^ *(file|dir|symlink|hardlink|collect) "var(/|")' "$file"; then
                fail "$file: packages never ship files under /var; use tmpfiles.d"
            fi
            for id in $(grep -oE ' uid=[0-9]+' "$file" | cut -d= -f2 | sort -u); do
                grep -Fxq "$id" <<< "$uids" || fail "$file: uid $id is not allocated in docs/uids.md"
            done
            for id in $(grep -oE ' gid=[0-9]+' "$file" | cut -d= -f2 | sort -u); do
                grep -Fxq "$id" <<< "$gids" || fail "$file: gid $id is not allocated in docs/uids.md"
            done
            ;;
        *) continue ;;
    esac
    if [[ $file != *.in ]] && grep -nE '="?@[A-Z][A-Z0-9_]*@|^ *@[A-Z][A-Z0-9_]*@ *$' "$file"; then
        fail "$file: a concrete file has a template placeholder"
    fi
done < <(find recipes -type f \( -name '*.kdl' -o -name '*.kdl.in' \) -print0 | sort -z)
exit "$status"
