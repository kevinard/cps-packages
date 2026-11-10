#!/usr/bin/env bash
# Install packages from the local repository into a fresh scratch image and
# verify it, as a smoke test of what tools/build.sh published.
#
# usage: tools/image.sh [--root DIR] [PACKAGE...]
#
# Without packages, every package that tools/build.sh published is
# installed. The image is created at DIR (default .cache/image), replacing
# an earlier one.
#
# Packages own their files as uid 0, so apply and verify run in a user
# namespace that maps this user to root and the subordinate IDs from
# /etc/subuid and /etc/subgid to the rest (unshare --map-root-user
# --map-auto). On the host the files belong to this user and its
# subordinate IDs. A real system installs as root instead.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
root=$cache/image
if [[ ${1:-} == --root ]]; then
    root=$(realpath -m -- "${2:?usage: tools/image.sh [--root DIR] [PACKAGE...]}")
    shift 2
fi
cps=$(cps_binary)
repo=$cache/repo
[[ -f $repo/current ]] || die 'nothing is published yet; run tools/build.sh'
packages=("$@")
if ((${#packages[@]} == 0)); then
    while IFS= read -r -d '' stamp; do
        bundle=${stamp%.published}
        while IFS= read -r -d '' manifest; do
            packages+=("$(sed -n '2s/^package "\([^"]*\)".*/\1/p' "$manifest")")
        done < <(find "$bundle/manifests" -name '*.kdl' -print0)
    done < <(find "$cache/bundles" -maxdepth 1 -name '*.published' -print0 | sort -z)
fi
((${#packages[@]})) || die 'no packages to install'
as_root=(unshare --map-root-user --map-auto)

if [[ -e $root ]]; then
    # Files of subordinate IDs can only be removed from inside the namespace.
    "${as_root[@]}" rm -rf -- "$root"
fi
# Every command runs in the namespace, so the image owner recorded at
# creation is the same root that owns the packaged usr/ directories above
# the image state in usr/lib/sysimage/cps.
"${as_root[@]}" "$cps" image-create --root "$root" --repo "$repo" --publisher canopa \
    --trust-root "$cache/keys/canopa.trust.json"
"${as_root[@]}" "$cps" plan --root "$root" --output "$root.plan.json" install "${packages[@]}"
"${as_root[@]}" "$cps" apply --root "$root" "$root.plan.json"
"${as_root[@]}" "$cps" verify --root "$root"
# --pristine also reports unmanaged paths. It expects the account databases
# and other state that the packages' systemd actions write; tmpfiles rules
# for /var run at boot, so an offline image leaves var/ empty.
"${as_root[@]}" "$cps" verify --root "$root" --pristine
"${as_root[@]}" "$cps" list --root "$root"
note "installed and verified ${#packages[@]} package(s) in ${root#"$top"/}"
