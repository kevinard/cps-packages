# Static user and group IDs

CPS writes a package's files before it runs that package's `sysusers`
declarations, and a manifest records file owners as numbers. So a service
user or group that owns a *packaged* file must have a fixed ID that every
image agrees on, allocated here before a manifest uses it. `tools/lint.sh`
rejects a manifest whose `uid` or `gid` is not in this table.

Everything else gets its ID from `systemd-sysusers` at install time and
never appears in a manifest:

- accounts that own only state under `/var`, `/run`, or `/etc`, created by
  `tmpfiles.d` rules after the account exists (the common case for daemons);
- groups that udev rules name for device nodes, such as `disk` or `video`.

## Ranges

| Range | Use |
| --- | --- |
| 0 | `root` |
| 1–99 | Static IDs from the table below. Allocate the next free one. |
| 100 | `users` (group only) |
| 101–999 | Dynamic system accounts, allocated by `systemd-sysusers` |
| 1000–60000 | Regular users |
| 65534 | `nobody` / `nogroup` |

The systemd recipe passes these boundaries to Meson (`-Dsystem-uid-max=999`,
`-Dsystem-gid-max=999`, `-Dtty-gid=5`, `-Dusers-gid=100`,
`-Dnobody-user=nobody`, `-Dnobody-group=nobody`), so `sysusers` and the
table cannot drift apart.

## Allocated IDs

Each row is `| name | uid | gid | owner of packaged files | notes |`. Use
`-` for an ID that is not allocated. The table is parsed by
`tools/lint.sh`, so keep the column order.

| Name | UID | GID | Owns packaged files in | Notes |
| --- | --- | --- | --- | --- |
| root | 0 | 0 | every package | |
| tty | - | 5 | `system/util-linux` (`wall`, `write` are setgid `tty`) | systemd's `basic.conf` uses the same fixed GID |
| users | - | 100 | none | Primary group of regular users |
| nobody | 65534 | 65534 | none | Overflow ID; never owns files |

## Adding an ID

1. Pick the next free ID in 1–99, for both columns if the account needs a
   user and a group.
2. Add the row here in the same commit as the manifest that uses it.
3. Ship a `usr/lib/sysusers.d/NAME.conf` that creates the account with
   exactly that ID (`u NAME 42:42 "Description" /var/lib/NAME`) and declare
   it with `sysusers "NAME.conf"` in the manifest. The numeric owner in the
   manifest and the ID in the sysusers file must match.

An ID is never reused for another account, even after the package that
needed it is gone: old images may still have files owned by it.
