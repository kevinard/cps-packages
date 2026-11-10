# Shared helpers for the tools/ scripts. Source it; do not run it.
# shellcheck shell=bash

# The repository root, whatever the caller's working directory.
top=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache=${CANOPA_CACHE:-$top/.cache}
arch=$(uname -m)

# The all-zero digest stands for "not pinned yet" in committed recipes: it
# is a valid digest, so every recipe parses, and no real catalog has it.
unpinned=0000000000000000000000000000000000000000000000000000000000000000

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*" >&2; }
sha() { sha256sum -- "$1" | cut -d' ' -f1; }

# The pinned cps binary, built by tools/cps.sh. CPS=PATH overrides it, for
# example to try a cps checkout before bumping cps.pin.
cps_binary() {
    if [[ -n ${CPS:-} ]]; then
        printf '%s\n' "$CPS"
    else
        "$top/tools/cps.sh"
    fi
}

# NAME creates an Ed25519 key pair under .cache/keys on first use and
# prints nothing. The keys are local and throwaway: they sign only this
# machine's repositories.
keypair() {
    local name=$1 keys=$cache/keys
    mkdir -p -m 700 -- "$keys"
    if [[ ! -f $keys/$name.der ]]; then
        openssl genpkey -algorithm ED25519 -outform DER -out "$keys/$name.der.tmp"
        mv -- "$keys/$name.der.tmp" "$keys/$name.der"
    fi
    if [[ ! -f $keys/$name-public.der ]]; then
        openssl pkey -inform DER -in "$keys/$name.der" -pubout -outform DER -out "$keys/$name-public.der"
    fi
}

# REPO PUBLISHER KEY creates a repository with a 1-of-1 trust root on first
# use and copies the trust root to .cache/keys/PUBLISHER.trust.json.
repository() {
    local repo=$1 publisher=$2 key=$3
    if [[ ! -d $repo/trust ]]; then
        "$cps" repo trust init --repo "$repo" --publisher "$publisher" --key "$cache/keys/$key.der" >/dev/null
    fi
    cp -- "$repo/trust/1.json" "$cache/keys/$publisher.trust.json"
}

# The quoted KDL string for a value.
kdl_string() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}
