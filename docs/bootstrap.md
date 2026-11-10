# Bootstrap roadmap

Canopa is bootstrapped in three stages. Each stage builds with CPS, from
pinned recipes, and the output of each stage is the toolchain of the next.
Only stage 0 copies binaries from a host.

```
stage 0  host toolchain ──copy──▶ seed repository (publisher "seed", untrusted)
stage 1  seed ──cps build──▶ devel/gcc, devel/binutils, system/glibc, … (publisher "canopa")
stage 2  stage-1 toolchain ──cps build──▶ the whole tree, repeated until it reproduces itself
```

## Stage 0: the host seed (works today)

`stage0/seed.sh` copies the C compiler, binutils, glibc, and the utilities
recipes run from an Arch Linux host and publishes them as layered seed
packages:

| Package | Contents |
| --- | --- |
| `system/elf-runtime` | The loader, `libc.so.6`, `libm.so.6`, `libgcc_s.so.1` |
| `build/seed-c` | gcc, binutils, make, bash as `/bin/sh`, coreutils, sed, grep, awk, tar and compressors, patch, pkg-config, glibc headers and static archives |
| `build/seed-rust` | rustc, cargo, and the host's Rust standard library (for `system/cps`) |
| `build/seed-meson` | Python, Meson, Ninja, gperf, Jinja2, pyelftools (for `system/systemd`) |
| `build/seed-kernel` | bison, flex, bc, perl, cpio, kmod, and the libelf and OpenSSL headers (for `system/kernel`) |

Each layer ships only the paths `build/seed-c` and `system/elf-runtime` do
not, and requires `build/seed-c`, so a recipe asks for exactly the tools it
uses and no path has two owners.

The seed is **untrusted**: it is only as good as the host. Its catalog is
signed with a key generated on that host, so every machine has a different
seed catalog digest. That is why committed recipes pin the seed with the
all-zero digest and `tools/build.sh` repins a staged copy of the tree to
the local seed with `cps recipe repin --toolchain-catalog --trust-root`.

A recipe whose toolchain mixes seed packages with canopa packages (today
`system/cps` and `system/systemd`) works only while no path is in both: a
toolchain is one installed tree. Seed layers therefore drop optional
Python and Perl extension modules that would bring their own copy of a
library (`_sqlite3`, `_uuid`, `dbm`, `pyexpat`, …), and `seed.sh` fails if
two layers share a path. `build/seed-c` still ships host copies of
libraries such as zlib, zstd, and OpenSSL that its programs load; the day
Canopa packages one of them, a mixed toolchain that needs both conflicts.
That is the practical deadline for stage 1.

`system/elf-runtime` (the canopa package) repackages the seed's runtime
byte for byte, so that images can run what the seed compiled. It is the
only recipe that ships host binaries, and it is the first one stage 1
replaces.

## Stage 1: a CPS-built toolchain

Goal: no published package depends on `seed` at run time, and the
toolchain itself is built by CPS from pinned sources.

1. **`system/bubblewrap`** (with `library/libcap`) first. CPS needs
   `/usr/bin/bwrap` for every build and every trigger, so a Canopa image
   cannot build or run triggers without it. Then `system/cps` requires it.
2. `devel/binutils`, then `devel/gcc` (with gmp, mpfr, mpc, isl, zstd,
   zlib as `library/` recipes), then `system/glibc` and `system/gcc-libs`
   (the `libgcc_s`/`libstdc++` runtime as its own package, because images
   install it without the compiler). Linux UAPI headers come from the
   kernel recipe as `devel/linux-headers`.
3. `build/base`: a toolchain bundle (a package with only `require`
   dependencies) on the stage-1 compiler, glibc, make, and the utilities
   above, built by CPS.
4. Replace `system/elf-runtime` with `system/glibc` + `system/gcc-libs`
   (an `obsolete` of the old package and `provides` of what it offered).
5. Rebuild every recipe against `build/base` instead of `build/seed-*`.

Cycles appear at this point (gcc needs glibc headers, glibc needs gcc;
util-linux can use libsystemd, systemd needs libmount). `cps build-order`
reports them; break each by building the first side against the previous
stage's catalog, which is what the seed is for.

## Stage 2: the fixed point

Rebuild the whole tree, including the toolchain, with the stage-1
toolchain, then again with the result. When a round produces byte-identical
packages (`cps build --check-reproducible` within a round, `cps repo
verify-rebuild` across rounds), the tree is self-hosting and the seed can be
deleted. From then on, recipes pin the published `canopa` toolchain catalog
for real, and bumping it is an ordinary reviewed `cps recipe repin`
change.

## What is not decided yet

- Official keys and a published seed: today every builder seeds locally.
  Once a project-signed stage-1 catalog exists, commit its digest and trust
  root pins and drop the all-zero convention.
- Multiple architectures: recipes say `architecture="x86_64"`. An aarch64
  port needs either per-architecture recipes or a way to instantiate one
  recipe per architecture.
- `system/canopa-trust` waits for the mirror's TUF root ceremony.
