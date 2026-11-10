# system/cps

CPS itself, built from the commit in `../../../cps.pin`, the same commit
that `tools/cps.sh` builds the tools from. Its two sources are generated,
not downloaded:

- `cps.tar.gz`: `git archive --prefix=cps/ COMMIT | gzip -n`
- `cps-vendor.tar.gz`: `cargo vendor --locked --versioned-dirs` of that
  tree, as a reproducible tar (sorted, owner 0, mtime of the commit), gzip -n

`sources.sh` writes both. Their pins in `build.kdl` are for the pinned
commit with this repository's tools; a different `git`, `gzip`, or `cargo`
version can produce different bytes, which `cps source fetch` then refuses.
Once CPS publishes release archives, pin those URLs instead.

`tools/bump-cps.sh COMMIT` moves `cps.pin`, this recipe's `version`
upstream string and `epoch`, and the source pins together.

Runtime needs that the manifest cannot express yet: `bwrap` for builds and
triggers. Add `require "system/bubblewrap"` once that recipe exists
(docs/bootstrap.md).
