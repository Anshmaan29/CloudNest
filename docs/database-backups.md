# Consistent SQLite snapshots

CloudNest snapshots one explicitly selected SQLite database with SQLite's [online backup API](https://www.sqlite.org/backup.html). It does not copy a live main database file, checkpoint or repair the source, stop its application, or remove originals. This workflow is separate from ordinary storage scanning and preserves all global exclusions for live databases, protected folders, cloud placeholders and repositories. It does not back up PostgreSQL, MySQL, Docker volumes or virtual-machine disks. Attached databases and external application resources are not included in this one-file snapshot. Encrypted or extension-specific formats that system SQLite cannot read require the owning application's export facility.

## Supported sources

Choose a local SQLite file you own, mode 600, in an owner-private mode-700 directory without additional ACLs. Source and destination must be outside system, cloud, protected and Git paths. Choose a destination outside the source directory. CloudNest refuses symlinks, hard links, foreign ownership, shared writable directories, placeholders, malformed SQLite headers and a rollback journal requiring recovery. It never changes source permissions to make a file eligible.

Closed rollback-journal databases are supported. An active WAL database is supported only when its existing, private `-wal` and `-shm` files allow read-only access and its owning external application maintains the WAL shared-memory state. Missing or stale sidecars fail safely; CloudNest does not create or reconstruct them. Use the owning application's supported export when a source is ineligible. Never copy a live database or its raw directory merely to bypass these checks.

SQLite opens the source with `SQLITE_OPEN_READONLY`, `SQLITE_OPEN_NOFOLLOW`, `mode=ro` and the Unix VFS `readonly_shm=1` option. The latter opens shared memory read-only, as implemented in SQLite's [official Unix VFS source](https://github.com/sqlite/sqlite/blob/master/src/os_unix.c). The implementation deliberately avoids `immutable=1`, because declaring an actively changing database immutable would undermine WAL correctness. SQLite documents the conditions for [read-only WAL databases](https://www.sqlite.org/wal.html#read_only_databases).

An already open source in CloudNest's own process is refused: SQLite can otherwise reuse that process's existing writable shared-memory mapping. An external application may continue writing. A read transaction pins one committed view; the backup API copies bounded page batches from that view. Writers can continue committing in WAL mode, although a long-lived reader can delay checkpoint reclamation. The operation is time bounded, with cancellation checks between batches and during verification.

## New backup format

The selected destination receives a fresh private `SQLiteSnapshot-<UUID>` folder only after backup and verification succeed. Private interrupted staging remains under `.cloudnest-recovery/sqlite-<UUID>` for inspection. CloudNest does not recursively remove failed staging or any user tree.

The published folder contains exactly:

- `database.cloudnest-snapshot`: a self-contained SQLite database in rollback/delete journal mode, containing the selected committed snapshot.
- `CLOUDNEST_DATABASE.json`: format version, ID, creation time, original filename, SQLite version, payload byte count and streamed SHA-256. `permitsOriginalCleanup` is always false.

The custom payload extension identifies a completed, inactive backup artifact so its folder may later enter the ordinary archive-review workflow. The original live database remains excluded. Snapshot creation never uploads automatically, and the optional native **Review cloud archive** callback applies only to the generated backup folder.

Destination SQLite work happens only inside a new private staging directory. A reserved, job-owned SHM scratch inode may be used during WAL conversion; cleanup removes it only if its exact identity still matches. Unknown or substituted members block publication. The closed payload must pass SQLite `quick_check`, an exact staged-identity check, a size limit and a streaming SHA-256 before an exclusive rename publishes the folder. Existing destinations are never overwritten.

Default budgets are 10 GB logical data, a 512 MB free-space margin, 64 pages per step, two seconds of backup lock contention and 30 seconds total. Core callers can configure limits within enforced bounds. Memory uses bounded buffers and SQLite page caches. These are implementation limits, not measured RAM or throughput claims.

## Restore

Choose a CloudNest SQLite snapshot folder and a destination outside that folder. Review freezes the manifest's digest. Restore rechecks the exact two-member inventory, private ownership, fixed payload name, manifest digest, payload SHA-256/size, standalone rollback header and SQLite `quick_check` before copying any payload into staging.

Only the already verified snapshot artifact is streamed during restoration; a live database is never copied this way. The copy is verified again and published under a new UUID folder, retaining the exact approved payload bytes. Existing databases and backups remain untouched. Open or import the restored artifact using its owning application; CloudNest does not install it over a running database or infer an original restore path.

## Verified locally

The tests create disposable databases only. A separate Python SQLite writer maintains real WAL sidecars while the native SQLite backup API runs. Tests verify committed WAL rows, a consistent pinned view while the external writer commits another transaction, and byte-for-byte unchanged source database/WAL/SHM during an idle-writer snapshot. Additional tests cover exact-byte restoration, tampered payloads/manifests, same-process source refusal, missing WAL sidecars without source creation, linked/protected/repository/malformed sources, conflicting output folders, disk/byte/time budgets and cancellation before and during copying.

No actual user database was opened for development. Native view compilation is verified; selecting and backing up a real user's database remains an explicit owner action.
