# Stage 0: the untrusted host seed

`seed.sh` copies the toolchain of the machine it runs on into a local CPS
repository, `.cache/stage0/repo`, under the publisher `seed`, signed with a
key it generates in `.cache/keys/seed.der`. It is the only step of the
Canopa build that takes binaries instead of sources.

**Do not trust anything built from it more than you trust the host.** The
seed exists to build stage 1: a compiler, binutils, and glibc built by CPS
from pinned sources. Stage 2 rebuilds everything with that toolchain until
the output reproduces itself, and from then on no recipe pins `seed`. See
[../docs/bootstrap.md](../docs/bootstrap.md).

## Requirements

- An x86_64 Arch Linux host (the script reads `pacman -Ql` for glibc,
  kernel headers, and Python, and assumes Arch's paths).
- gcc, binutils, make, bash, coreutils, the usual text and archive tools,
  patch, pkg-config, xz, Rust (rustup or the Arch package), Python with
  Meson and Ninja, gperf, Jinja2, pyelftools, bison, flex, m4, bc, perl,
  cpio, kmod, and libelf.
- Tools the host lacks can come from unpacked packages: set
  `STAGE0_EXTRA_ROOTS=/path/to/root1:/path/to/root2`, each a directory
  with `usr/bin/...` and Python's `site-packages` at the host's path.

## What it publishes

Five packages, version `1.0.0-0`, each with the summary "Stage 0 seed:
untrusted host toolchain":

- `system/elf-runtime`: the loader and C/GCC runtime libraries
- `build/seed-c`: the C toolchain and base utilities
- `build/seed-rust`, `build/seed-meson`, `build/seed-kernel`: layers on top
  of `build/seed-c` that ship only their own additional paths

Each layer copies every shared library its programs and extension modules
load. An extension module whose library the host does not have (Python's
`_tkinter` without Tk, for example) cannot load and is left out, with a
note. `host.txt` records the host's package versions.

## Running it

`tools/build.sh` runs it when `.cache/stage0/repo` does not exist yet.
`tools/build.sh --reseed` rebuilds it, which gives the seed a new catalog
digest and therefore discards the local canopa repository too: every
package was built from the old seed.
