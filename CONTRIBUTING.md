# Recipe conventions and policy

Every recipe follows these rules. `tools/check.sh` enforces the ones a
script can check; reviewers enforce the rest. The CPS manual explains the
formats: [build recipes](https://github.com/kevinard/cps/blob/main/docs/maintainer/builds.md),
[manifests](https://github.com/kevinard/cps/blob/main/docs/maintainer/manifests.md),
and [concepts](https://github.com/kevinard/cps/blob/main/docs/concepts.md).

## Layout and naming

- One recipe per directory: `recipes/CATEGORY/NAME/build.kdl`. Its
  manifest templates, patches, and config fragments live next to it and
  are pinned by digest.
- The directory names the package the recipe produces: `recipes/library/sqlite`
  builds `library/sqlite`. A recipe that publishes several packages is
  named after its primary one.
- Categories:

  | Category | Holds | Examples |
  | --- | --- | --- |
  | `system/` | The base OS: layout, runtime, init, kernel, core tools, CPS | `system/filesystem`, `system/systemd`, `system/cps` |
  | `library/` | Shared libraries other packages link against | `library/sqlite`, `library/libseccomp` |
  | `devel/` | Compilers, build systems, and other development tools | `devel/gcc`, `devel/meson` (stage 1) |
  | `build/` | Toolchain bundles that recipes request and no image installs | `build/seed-c` (stage 0), `build/base` (stage 1) |
  | `apps/` | Everything else that users install | |

- Every package is published by `canopa`. Only stage 0 uses `seed`.
- A recipe carries the package version in its `version` node, with the
  upstream version in `upstream`, and its templates omit `version`. The
  revision after the `-` starts at 1 and increases with every published
  change that does not change the upstream version, including a rebuild
  for a new toolchain.
- `epoch` is the upstream release time (`SOURCE_DATE_EPOCH`), not the time
  you wrote the recipe.

## Pins

A recipe pins everything it reads: the toolchain catalog and trust root of
each toolchain publisher, each manifest template, and each source by size
and SHA-256. Do not edit digests by hand:

- After editing a template, a patch, or a source URL, run
  `tools/update-pins.sh recipes/CATEGORY/NAME`. It downloads missing
  sources to `.cache/distfiles` and runs `cps recipe repin --manifests
  --local-sources --sources .cache/distfiles`, the equivalent of
  `updpkgsums`.
- Toolchain pins in committed recipes are the all-zero digest until an
  official seed or stage-1 toolchain catalog is published; `tools/build.sh`
  sets them in its staged copy for local builds. Never commit pins of a
  catalog signed with a local throwaway key.
- `tools/check.sh` runs `cps recipe repin --check`, which fails when a
  pin no longer matches the file it pins.
- Every source has an HTTPS `url` that answers without a redirect (CPS
  refuses redirects), unless it is checked in next to the recipe. Prefer
  the upstream release URL; when upstream only redirects, as GitHub release
  assets do, use a byte-identical mirror and say so in a comment, as
  `library/libseccomp` does with Debian's copy.

## Manifests, facets, and packages

Follow CPS's rule of one mechanism per problem (`docs/concepts.md` in CPS):

| Use | When |
| --- | --- |
| **Facet** | Optional content inside one package that adds no dependencies: headers, `.so` links and `pkg-config` files (`devel`), manual pages (`doc.man`), info pages (`doc.info`), other docs (`doc`), translations (`locale.LANG`), debug files (`debug.symbols`). |
| **Separate package** | Content installed on its own, or with its own dependencies: a library that other programs link against and the tools that come with it, a plugin that needs another service. Publish it from the same recipe with a second `manifest`. |
| **Variant** | A mutually exclusive property of the image, such as `arch`. |

- Use `collect` patterns and let CPS assign the built-in facets; write an
  explicit `facet=` only for content the built-in rules miss. Never make a
  `-dev`, `-doc`, or `-dbg` package.
- Every installed file belongs to exactly one package or matches a
  `discard` pattern with a reason. Discard only what no image should get,
  such as libtool `.la` files.
- Libraries ship in `/usr/lib` with a `DT_SONAME`, so CPS generates their
  `cap/elf/...` dependencies; never write those by hand. Declare
  `require "system/elf-runtime"` in a package with dynamically linked
  executables, because the program interpreter is not a library
  dependency. Add a versioned `require` only for a real minimum version.
- Competing implementations of one command, such as `/usr/bin/sh`, use a
  mediated link (`mediate "usr/bin/sh" group="sh" priority=N`).
- Owners are numeric. `uid=0 gid=0` unless the file needs a static ID from
  [docs/uids.md](docs/uids.md); add the ID there first. Setuid and setgid
  bits go in an explicit `file` action, never through `make install`.

## No files under /var

`/var` is a shared Btrfs subvolume that outlives boot environments, so no
package ships anything beneath it: no `file`, `dir`, `symlink`, `hardlink`,
or `collect` under `var/`. `tools/lint.sh` checks the templates and
`tools/build.sh` checks every built manifest; CPS itself is gaining the
same check at publication.

- State directories, logs, caches, and spools are created by a
  `usr/lib/tmpfiles.d/NAME.conf` the package ships and declares with
  `tmpfiles "NAME.conf"`. Declared files may contain only `d`, `f`, and `L`
  rules; anything else runs at boot from `systemd-tmpfiles-setup.service`.
- Service accounts come from `usr/lib/sysusers.d/NAME.conf`, declared with
  `sysusers "NAME.conf"`. sysusers runs after the files are written, so an
  account that owns a packaged file needs a static ID in
  [docs/uids.md](docs/uids.md).
- Configure builds so they do not install into `/var` at all (for example
  `-Dcreate-log-dirs=false` for systemd, `--disable-uuidd` for util-linux)
  instead of discarding what they install there.
- Defaults belong in `/usr` (`/usr/lib/NAME/`, `/usr/share/factory/`). Ship
  files in `/etc` only when the program cannot read a vendor default from
  `/usr`; they become preserved configuration.

## Patches and CVEs

- A patch is a checked-in source next to the recipe, applied in the script
  with `patch --batch --forward --fuzz=0 -p1`, so a patch that no longer
  applies exactly fails the build.
- Name a security fix after its identifier, `CVE-YYYY-NNNNN.patch`, one CVE
  per file. Name other patches `NNNN-short-description.patch`, numbered in
  application order.
- Every patch starts with a header: what it fixes, the upstream commit or
  bug it comes from, and whether it is upstream. Drop it when the upstream
  release includes it.
- A patch bumps the package revision.
- `.gitattributes` in the recipe directory keeps `git` from rewriting
  whitespace in unified diffs (see `recipes/system/busybox`).

## The CPS pin

CPS formats are unreleased and change in place, so this tree is written for
exactly one CPS commit, recorded in `cps.pin`. `tools/cps.sh` builds that
commit, and the `system/cps` package is built from it too.

To move to another commit:

1. Check what changed in the formats (`git log OLD..NEW -- docs/`) and
   update recipes and tools in the same change.
2. Run `tools/bump-cps.sh COMMIT` with `CPS_SOURCE` pointing at a checkout
   or URL that has the commit. It rewrites `cps.pin`, the version and epoch
   of `recipes/system/cps/build.kdl`, and its source pins.
3. Run `tools/build.sh` and `tools/check.sh`. Commit the bump with every
   change it needed, and say in the message which CPS changes motivated it.

Pin only commits that are on CPS's `main` branch, so the pin stays
fetchable; a branch commit is acceptable only while that branch is being
landed, and must be re-bumped to the merged commit.

## Reviews

A recipe change is reviewed as a whole: script, templates, patches, pins.
The recipe digest that `tools/build.sh` and `cps recipe repin` print is
what a publisher approves in the publish policy of a real repository.
