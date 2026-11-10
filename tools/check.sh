#!/usr/bin/env bash
# The checks CI runs, offline and without building anything:
#
#   1. every manifest pin and every pin of a checked-in source is current
#      (cps recipe repin --check), and with --distfiles also the pins of
#      downloaded sources in .cache/distfiles;
#   2. the tree has a build order (cps build-order);
#   3. tools/lint.sh: no package content under /var, owners from docs/uids.md,
#      recipe layout and naming.
#
# usage: tools/check.sh [--distfiles]
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
cps=$(cps_binary)
cd -- "$top"
sources=()
if [[ ${1:-} == --distfiles ]]; then
    sources=(--sources "$cache/distfiles")
elif (($#)); then
    die 'usage: tools/check.sh [--distfiles]'
fi
note 'checking recipe pins'
"$cps" recipe repin --check --manifests --local-sources "${sources[@]}" recipes
note 'checking the build order'
"$cps" build-order --explain recipes > /dev/null
note 'linting recipes'
"$top/tools/lint.sh"
note 'all checks passed'
