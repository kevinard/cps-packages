# Using CPS on another distribution

CPS is developed for Canopa OS, and other distributions are not a design
target: there is no compatibility layer and no packaging of CPS for them.
To run CPS elsewhere, provide its dependencies yourself. This list is taken
from the CPS sources and manual at the commit in `../cps.pin`; check it
again after a bump.

## Building CPS

- Rust with the 2024 edition and `cargo build --locked` (see CPS's
  `ci/rust-dist.sha256` for the pinned version), a C compiler and linker,
  and `pkg-config`.
- The **system** SQLite and libseccomp libraries with their headers:
  `rusqlite` and `libseccomp` link the shared `libsqlite3.so.0` and
  `libseccomp.so.2`; nothing is bundled.
- Linux with `/proc` and `openat2(2)` (Linux 5.6 or newer).

## Running CPS

| Needed for | Dependency |
| --- | --- |
| Everything | Linux 5.6 or newer for `openat2(2)`, mounted `/proc`; `libsqlite3.so.0`, `libseccomp.so.2`, glibc |
| `cps build`, `cps develop` | Linux 5.11 or newer, seccomp, unprivileged user namespaces, and a current Bubblewrap at exactly `/usr/bin/bwrap`. Builds refuse to run as root. Optional: a delegated cgroup v2 subtree for worker limits. |
| Triggers (`cps apply` of packages that declare them) | `/usr/bin/bwrap` with unprivileged user namespaces and overlay support (`--overlay-src`). Hosts that restrict unprivileged namespaces (Ubuntu's `kernel.apparmor_restrict_unprivileged_userns`) need that lifted or a `bwrap` AppArmor profile. |
| `sysusers`, `tmpfiles`, and `preset` actions | The host's `systemd-sysusers`, `systemd-tmpfiles`, and `systemctl` |
| Kernel packages and boot entries | `kernel-install` and systemd-boot 262 or newer; a Btrfs root (`btrfs` filesystem), a VFAT ESP written with mtools (`mcopy`, `mmd`), and `blkid` |
| Signed UKIs | `ukify` (systemd-ukify) and a configured `sbctl` whose db certificate the firmware trusts |
| Git installs | `git`; `gpg` or `ssh-keygen` to verify signed commits and tags |
| Publishing a TUF mirror | [`tuftool`](https://github.com/awslabs/tough/tree/develop/tuftool) on the machine that signs mirror metadata |

Boot environments, trial boots, and rollback assume what Canopa assumes: a
Btrfs root with `/var` on its own subvolume, UEFI, and systemd-boot. CPS can
manage a plain image directory (`cps image-create --root DIR`) on any
filesystem, which is how `tools/image.sh` tests packages here.

## Running CPS as an unprivileged user

Images whose files belong to root need root, or a user namespace that maps
the caller to root and has enough IDs for every owner in the manifests:

```sh
unshare --map-root-user --map-auto cps apply --root image plan.json
```

`--map-auto` uses the ranges in `/etc/subuid` and `/etc/subgid`; with only
`--map-root-user`, changing a file to any owner other than root fails.
