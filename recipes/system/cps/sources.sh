#!/bin/sh
# Write the two sources this recipe pins, cps.tar.gz and cps-vendor.tar.gz,
# for the commit in cps.pin into DIR. Run by tools/build.sh and
# tools/update-pins.sh; see README.md.
set -eu
exec "$(dirname -- "$0")/../../../tools/cps.sh" --sources "${1:?usage: sources.sh DIR}" >/dev/null
