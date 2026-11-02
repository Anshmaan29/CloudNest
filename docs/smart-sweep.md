# Smart Sweep

Smart Sweep is a local, explicitly initiated cleanup workflow. It does not upload
data, use macOS Trash, run package-manager scripts, or scan continuously.

1. Select one supported generated folder and run a dry-run preview.
2. Review its full inventory, estimated allocated blocks, and regeneration note.
3. Approve moving the folder to a private sibling `.cloudnest-sweep-recovery` job.
   This same-volume move does **not** reclaim the payload's disk space.
4. Either put it back without overwriting another folder, or separately approve
   permanent cleanup of the reviewed staged entries.

Supported selections are SwiftPM debug/release product folders with a parent
`Package.swift`, Xcode DerivedData build products with their project marker,
compiler module caches, npm `_cacache` with its cache markers, pip `http-v2` or
`wheels`, and `node_modules` beside a package manifest and lockfile. Dependency
cleanup also requires acknowledgment that local edits may be lost. None of
these markers prove that arbitrary user files were never placed in a cache:
the selected location and regeneration guidance still require user review.

The default preview is bounded to 20,000 entries, 10 GB of unique logical file
data, depth 48, and 30 seconds. Files are SHA-256 hashed in 1 MiB chunks.
Preview, staging and cleanup check active file use; project build/install
processes also block project cleanup. Uncertain process checks fail closed.
Protected folders, cloud placeholders, repositories inside selections, database
files and headers, virtual disks, unsupported ownership/permissions, and special
files are refused. Ordinary archive `FileSafety` rules remain unchanged.

Only acknowledged `node_modules` may contain symbolic links. Links themselves
are inventoried and removed; their targets are never traversed. Hard-linked
files are counted once, excluded from estimated allocated savings, and block
permanent cleanup. APFS clones and snapshots can prevent estimated allocated
blocks from becoming newly available space. Cleanup reports the separate,
volume-wide observed free-space delta, which concurrent activity can affect.

Recovery jobs use private directories, durable journals, and per-job leases.
Changing content invalidates cleanup approval. New names are never recursively
deleted. A regenerated original destination blocks put-back. Cancellation or a
failure during permanent cleanup can leave a partially cleaned job marked
`purgeStarted`; automatic cleanup resumption and one-click put-back are disabled
for that state. Retain its payload and journal for manual recovery. Unknown
catalog members are retained and reported rather than deleted.

The SwiftUI view accepts protected roots and an operation-busy callback so the
application can serialize it with storage operations. The core functions also
work offline. Integration into the application's navigation is a separate
checkpoint from these core and view changes.

Run generated-fixture safety tests with:

```sh
bash scripts/swift.sh test --filter sweep
```
