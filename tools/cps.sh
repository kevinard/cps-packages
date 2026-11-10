#!/usr/bin/env bash
# Build the cps commit pinned in cps.pin and print the path of the binary.
#
# usage: tools/cps.sh [--sources DIR]
#
# The source is CPS_SOURCE when set, either a local checkout or a Git URL,
# and otherwise CPS_URL from cps.pin. The commit must exist there. The
# binary is built once per commit into .cache/cps/COMMIT/ with
# `cargo build --release --locked` and reused afterwards.
#
# --sources DIR also writes the two source archives that the system/cps
# recipe pins for this commit: DIR/cps.tar.gz, `git archive` of the commit,
# and DIR/cps-vendor.tar.gz, its vendored crates. Both are deterministic for
# a given git, gzip, tar, and cargo; see recipes/system/cps/README.md.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"

sources=
case $# in
    0) ;;
    2) [[ $1 == --sources ]] || die 'usage: tools/cps.sh [--sources DIR]'; sources=$2 ;;
    *) die 'usage: tools/cps.sh [--sources DIR]' ;;
esac

# shellcheck source=../cps.pin
CPS_COMMIT=$(sed -n 's/^CPS_COMMIT=//p' "$top/cps.pin")
CPS_URL=$(sed -n 's/^CPS_URL=//p' "$top/cps.pin")
[[ $CPS_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "cps.pin has no full commit ID: $CPS_COMMIT"
source=${CPS_SOURCE:-$CPS_URL}
out=$cache/cps/$CPS_COMMIT
binary=$out/bin/cps

# A Git directory that has the commit: the local checkout itself, or a
# blobless clone of the URL under .cache/cps/git.
git_dir() {
    if [[ -d $source ]]; then
        git -C "$source" rev-parse --git-dir >/dev/null 2>&1 || die "$source is not a Git checkout"
        printf '%s\n' "$source"
        return
    fi
    local clone=$cache/cps/git
    if [[ ! -d $clone ]]; then
        git clone --quiet --bare --filter=blob:none -- "$source" "$clone" >&2
    fi
    if ! git -C "$clone" cat-file -e "$CPS_COMMIT^{commit}" 2>/dev/null; then
        git -C "$clone" fetch --quiet origin "$CPS_COMMIT" >&2
    fi
    printf '%s\n' "$clone"
}

if [[ ! -x $binary || -n $sources ]]; then
    repo=$(git_dir)
    git -C "$repo" cat-file -e "$CPS_COMMIT^{commit}" 2>/dev/null \
        || die "commit $CPS_COMMIT is not in $source; fetch it or set CPS_SOURCE"
fi

if [[ ! -x $binary ]]; then
    note "building cps $CPS_COMMIT from $source"
    rm -rf -- "$out.tmp"
    mkdir -p -- "$out.tmp/src"
    git -C "$repo" archive --format=tar "$CPS_COMMIT" | tar -x -C "$out.tmp/src"
    (
        cd -- "$out.tmp/src"
        CARGO_TARGET_DIR=$cache/cps/target cargo build --release --locked --bin cps >&2
    )
    install -Dm755 "$cache/cps/target/release/cps" "$out.tmp/bin/cps"
    rm -rf -- "$out.tmp/src"
    rm -rf -- "$out"
    mv -- "$out.tmp" "$out"
fi

if [[ -n $sources ]]; then
    mkdir -p -- "$sources"
    epoch=$(git -C "$repo" show -s --format=%ct "$CPS_COMMIT")
    work=$(mktemp -d "$cache/cps/.sources.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    git -C "$repo" archive --format=tar --prefix=cps/ "$CPS_COMMIT" | gzip -n > "$work/cps.tar.gz"
    tar -xzf "$work/cps.tar.gz" -C "$work"
    (
        cd -- "$work/cps"
        cargo vendor --quiet --locked --versioned-dirs "$work/vendor" >/dev/null
    )
    tar --sort=name --format=gnu --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -C "$work" -cf - vendor | gzip -n > "$work/cps-vendor.tar.gz"
    mv -- "$work/cps.tar.gz" "$work/cps-vendor.tar.gz" "$sources/"
    note "wrote $sources/cps.tar.gz and $sources/cps-vendor.tar.gz (epoch $epoch)"
fi
printf '%s\n' "$binary"
