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
"$cps" image-create --root "$root" --repo "$repo" --publisher canopa \
    --trust-root "$cache/keys/canopa.trust.json"
"$cps" plan --root "$root" --output "$root.plan.json" install "${packages[@]}"
"${as_root[@]}" "$cps" apply --root "$root" "$root.plan.json"
"${as_root[@]}" "$cps" verify --root "$root"
# --pristine also reports unmanaged paths. Declared systemd actions create
# some by design: tmpfiles state under var/ and the account databases that
# sysusers writes in etc/. Those are expected (see docs/bootstrap.md, open
# issues); any other unmanaged path is a failure.
action_state='^error: unmanaged path "(var/|etc/(passwd|group|shadow|gshadow|\.pwd\.lock)")'
if ! pristine=$("${as_root[@]}" "$cps" verify --root "$root" --pristine 2>&1); then
    unexpected=$(grep -Ev "$action_state" <<< "$pristine" || true)
    if [[ -n $unexpected ]]; then
        printf '%s\n' "$unexpected" >&2
        die 'pristine verification failed'
    fi
    note "pristine verification: only state from tmpfiles and sysusers actions is unmanaged ($(grep -Ec "$action_state" <<< "$pristine") path(s))"
fi
"$cps" list --root "$root"
note "installed and verified ${#packages[@]} package(s) in ${root#"$top"/}"
