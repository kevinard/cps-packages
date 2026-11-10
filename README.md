# Canopa OS packages

The build recipes of Canopa OS, in one repository, the way Alpine keeps
`aports` and OpenIndiana keeps `oi-userland`. Every package in the Canopa
repositories is built from a recipe here with
[CPS](https://github.com/kevinard/cps), the Canopa Package System. CPS
builds each recipe offline in a sandbox from pinned inputs, signs build
evidence, and publishes signed packages.

Canopa OS is a Btrfs-root, UEFI, systemd-boot system with a merged `/usr`.
Packages never ship files under `/var`.

## Layout

| Path | What it holds |
| --- | --- |
| `recipes/CATEGORY/NAME/` | One recipe: `build.kdl`, its manifest templates, and checked-in sources such as patches and config fragments. The directory is the name of the package it produces. |
| `stage0/` | The bootstrap seed: a script that copies this host's toolchain into a local repository. **Untrusted**; see [stage0/README.md](stage0/README.md). |
| `tools/` | The build, pin, and check scripts. |
| `docs/` | [Bootstrap roadmap](docs/bootstrap.md), [static user and group IDs](docs/uids.md), and [CPS on other distributions](docs/foreign-distros.md). |
| `cps.pin` | The exact CPS commit this tree is written for. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Recipe conventions and policy. |
| `.cache/` | Everything a build produces. Git-ignored. |

Categories: `system/` (the base OS), `library/` (shared libraries),
`devel/` (compilers and build tools), `build/` (toolchain bundles that only
recipes request), and `apps/` (everything else). Recipes are found by
`cps build-order`, so the layout needs no index file.

Why one directory per recipe: a recipe and the files it pins by digest
(templates, patches, config fragments) change together, and one directory
makes the review and the `git log` of a package one path. Why a separate
`stage0/`: the seed is not a recipe. It is the one input that is not built
from pinned sources, and keeping it out of `recipes/` makes it obvious that
nothing published may depend on it once stage 1 exists.

## Quickstart

On an x86_64 Arch Linux host, as an ordinary user, with Rust, `git`,
`openssl`, `curl`, and Bubblewrap with unprivileged user namespaces:

```sh
tools/build.sh --keep-going        # cps, seed, then every recipe in build order
tools/image.sh                     # install what was published into a scratch image and verify it
tools/check.sh                     # what CI checks: pins, build order, lint
```

`tools/build.sh` does the whole flow:

1. `tools/cps.sh` builds the CPS commit from `cps.pin` into `.cache/cps/`
   (from `CPS_SOURCE`, a checkout or URL, or the URL in `cps.pin`).
2. `stage0/seed.sh` copies the host's gcc, binutils, glibc, and tools into
   seed packages and publishes them under publisher `seed`.
3. It creates throwaway keys in `.cache/keys/` on first run: the seed key,
   the `canopa` release key, and a builder key.
4. It stages `recipes/` in `.cache/work/recipes`, and for each recipe in
   `cps build-order` order sets the toolchain pins to the local seed and
   canopa catalogs with `cps recipe repin`, fetches sources, runs
   `cps build --check-reproducible` with a signed attestation, approves the
   recipe digest in the local publish policy, and runs `cps publish-bundle`.

Rerunning it skips recipes whose staged digest was already published. Name
recipes to build only those, as in `tools/build.sh library/sqlite`.

Committed recipes pin the seed by the all-zero digest: the seed is built on
each machine and signed with that machine's key, so its catalog digest is
not knowable in advance. Everything else (manifests, sources) is pinned for
real, and `tools/check.sh` fails when a pin is stale.

## Day-to-day

```sh
$EDITOR recipes/library/sqlite/build.kdl    # new version, URL, source name
tools/update-pins.sh recipes/library/sqlite # download, then repin like updpkgsums
tools/build.sh library/sqlite
tools/check.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the rules every recipe follows.
