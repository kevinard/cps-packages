#!/usr/bin/env bash
# Build the recipe tree end to end into a local, signed repository:
#
#   stage0 seed -> cps build-order -> repin -> cps build -> cps publish-bundle
#
# usage: tools/build.sh [--reseed] [--keep-going] [CATEGORY/NAME...]
#
# With no names every recipe is built, in build order. With names, only
# those recipes are built, still in build order; their build dependencies
# must already be published. Recipes that are templates (*.in) are skipped.
#
#   --reseed      rebuild the stage0 seed. Its catalog changes, so the local
#                 repository and bundles are discarded and rebuilt.
#   --keep-going  build the remaining recipes after a failure
#
# Outputs, all under the git-ignored .cache/:
#   keys/        throwaway seed, release, and builder keys, made on first run
#   stage0/repo  the seed repository (publisher "seed")
#   repo/        the local Canopa repository (publisher "canopa")
#   work/        the staged recipe tree that builds read; only its toolchain
#                pins differ from recipes/, because they name local catalogs
#   sources/     the content-addressed source cache
#   bundles/     one build bundle per recipe, and logs/ one log per build
#
# Environment: CPS (cps binary), CANOPA_DISTFILES (colon-separated
# directories of already downloaded sources to use before the recipe URLs),
# and STAGE0_EXTRA_ROOTS (see stage0/seed.sh).
set -euo pipefail
umask 022
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"

reseed=false
keep_going=false
selected=()
for arg; do
    case $arg in
        --reseed) reseed=true ;;
        --keep-going) keep_going=true ;;
        -*) die "unknown option $arg" ;;
        *) selected+=("${arg%/}") ;;
    esac
done
[[ $(id -u) != 0 ]] || die 'cps build refuses to run as root; run this as an ordinary user'

cps=$(cps_binary)
export CPS=$cps
repo=$cache/repo
keys=$cache/keys
if $reseed; then
    "$top/stage0/seed.sh" --force
    rm -rf -- "$repo" "$cache/bundles" "$cache/work"
else
    "$top/stage0/seed.sh"
fi
seed_catalog=$(cat "$cache/stage0/repo/current")

keypair canopa
keypair builder
repository "$repo" canopa canopa
cp -- "$keys/builder-public.der" "$repo/builder-public.der"
policy=$repo/publish-policy.kdl
if [[ ! -f $policy ]]; then
    # The local repository approves what this machine just built. A real
    # publisher reviews each recipe digest independently; see
    # docs/bootstrap.md.
    cat > "$policy" <<'POLICY'
schema-version 1 kind="publish-policy"
publisher "canopa" archive-build-inputs=#true require-source-archives=#true {
    builder-key "builder-public.der"
}
POLICY
fi
# RECIPE writes the worker's toolchain configuration for exactly the
# publishers the recipe pins, which cps build requires, and prints its path.
toolchain_config() {
    local recipe=$1 config publisher location
    config=$cache/work/toolchain-$(sha "$recipe").kdl
    {
        printf 'schema-version 1 kind="toolchain-config"\n'
        sed -n 's/^        publisher "\([^"]*\)" catalog=.*/\1/p' "$recipe" | while read -r publisher; do
            case $publisher in
                seed) location=$cache/stage0/repo ;;
                canopa) location=$repo ;;
                *) die "$recipe pins unknown toolchain publisher $publisher" ;;
            esac
            printf 'publisher "%s" {\n    repository %s\n    trust-root %s\n}\n' "$publisher" \
                "$(kdl_string "$location")" "$(kdl_string "$keys/$publisher.trust.json")"
        done
    } > "$config"
    printf '%s\n' "$config"
}

work=$cache/work/recipes
rm -rf -- "$work"
mkdir -p -- "$cache/work" "$cache/bundles" "$cache/logs" "$cache/sources"
cp -a -- "$top/recipes" "$work"
mapfile -t order < <("$cps" build-order "$work")

# The pinned source names of a recipe.
source_names() {
    sed -n 's/^    source "\([^"]*\)".*/\1/p' "$1"
}

# NAME VERSION SHA256 approves the recipe digest for one package version in
# the publish policy, replacing an earlier approval of the same version.
approve() {
    local name=$1 version=$2 recipe_sha=$3
    sed -i "\\|^    approve \"$name\" version=\"$version\" |d" "$policy"
    sed -i "\$i\\    approve \"$name\" version=\"$version\" sha256=\"$recipe_sha\"" "$policy"
}

built=() published=() up_to_date=() failed=() skipped=()
build_one() {
    local recipe=$1 rel=$2 dir=${2%/*} bundle log staging sha manifest name version
    bundle=$cache/bundles/${dir//\//-}
    log=$cache/logs/${dir//\//-}.log
    # Toolchain pins name this machine's catalogs, so they are set here, in
    # the staged copy, and never in recipes/.
    local pins=(--toolchain-catalog "seed=$seed_catalog" --trust-root "$keys/seed.trust.json")
    if [[ -f $repo/current ]]; then
        pins+=(--toolchain-catalog "canopa=$(cat "$repo/current")" --trust-root "$keys/canopa.trust.json")
    fi
    "$cps" recipe repin "${pins[@]}" "$recipe" >/dev/null
    sha=$(sha "$recipe")
    if [[ -f $bundle.published && $(cat "$bundle.published") == "$sha" ]]; then
        up_to_date+=("$dir")
        return 0
    fi
    note "building $dir (log: ${log#"$top"/})"
    : > "$log"
    # Sources: files next to the recipe, then CANOPA_DISTFILES, then files a
    # recipe's sources.sh generates, then the recipe URLs.
    staging=$(mktemp -d "$cache/work/.sources.XXXXXXXX")
    local name_ source_dir
    while IFS= read -r name_; do
        if [[ -f $top/recipes/$dir/$name_ ]]; then
            cp -- "$top/recipes/$dir/$name_" "$staging/"
            continue
        fi
        IFS=: read -r -a dist <<< "${CANOPA_DISTFILES:-}"
        for source_dir in "${dist[@]}"; do
            if [[ -n $source_dir && -f $source_dir/$name_ ]]; then
                cp --reflink=auto -- "$source_dir/$name_" "$staging/"
                break
            fi
        done
    done < <(source_names "$recipe")
    if [[ -x $top/recipes/$dir/sources.sh ]]; then
        "$top/recipes/$dir/sources.sh" "$staging" >> "$log" 2>&1
    fi
    if ! "$cps" source fetch --from "$staging" --cache "$cache/sources" "$recipe" >> "$log" 2>&1; then
        rm -rf -- "$staging"
        note "source fetch failed for $dir; see $log"
        return 1
    fi
    rm -rf -- "$staging"
    rm -rf -- "$bundle" "$bundle.published"
    if ! "$cps" build --toolchain-config "$(toolchain_config "$recipe")" --source-cache "$cache/sources" \
        --output "$bundle" --check-reproducible --builder-signing-key "$keys/builder.der" \
        "$recipe" >> "$log" 2>&1; then
        note "build failed for $dir; last lines of $log:"
        tail -n 25 -- "$log" >&2
        return 1
    fi
    built+=("$dir")
    # Packages never ship files under /var; see CONTRIBUTING.md.
    if grep -rqE '^ *(file|dir|symlink|hardlink) "var(/|")' "$bundle/manifests"; then
        grep -rnE '^ *(file|dir|symlink|hardlink) "var(/|")' "$bundle/manifests" >&2
        note "$dir ships paths under /var"
        return 1
    fi
    while IFS= read -r -d '' manifest; do
        name=$(sed -n '2s/^package "\([^"]*\)".*/\1/p' "$manifest")
        version=$(sed -n '2s/^package .* version="\([^"]*\)".*/\1/p' "$manifest")
        [[ -n $name && -n $version ]] || die "cannot read the package of $manifest"
        approve "$name" "$version" "$sha"
    done < <(find "$bundle/manifests" -name '*.kdl' -print0)
    if ! "$cps" publish-bundle --repo "$repo" --signing-key "$keys/canopa.der" \
        --builder-key "$keys/builder-public.der" --recipe-sha256 "$sha" \
        --source-cache "$cache/sources" "$bundle" >> "$log" 2>&1; then
        note "publication failed for $dir; last lines of $log:"
        tail -n 15 -- "$log" >&2
        return 1
    fi
    printf '%s\n' "$sha" > "$bundle.published"
    published+=("$dir")
}

for recipe in "${order[@]}"; do
    rel=${recipe#"$work"/}
    dir=${rel%/*}
    if [[ $recipe == *.in ]]; then
        skipped+=("$dir (template)")
        continue
    fi
    if ((${#selected[@]})) && [[ " ${selected[*]} " != *" $dir "* ]]; then
        continue
    fi
    if ! build_one "$recipe" "$rel"; then
        failed+=("$dir")
        $keep_going || break
    fi
done

summary() {
    local label=$1
    shift
    (($#)) && printf '%-11s %s\n' "$label" "$*"
    return 0
}
printf '\n'
summary published: "${published[@]}"
summary up-to-date: "${up_to_date[@]}"
summary skipped: "${skipped[@]}"
summary failed: "${failed[@]}"
if [[ -f $repo/current ]]; then
    printf 'repository  %s (canopa catalog %s)\n' "${repo#"$top"/}" "$(cat "$repo/current")"
fi
((${#failed[@]} == 0))
