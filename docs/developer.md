# Project Time Capsule

Project Time Capsule creates a verified local working-tree snapshot that can
then use the normal CloudNest folder archive/restore workflow. It does not
remove, offload or modify the original repository. It is not a claim that an
active development environment can safely be moved away from a running process.

Select the root of a trusted, initialized Git working tree and a local snapshot
destination outside Git, cloud folders and protected paths. The builder records
the commit, branch, staged changes, raw working-content/mode differences from the index, copied files outside the index,
source hashes, original modes/timestamps, dependency-manifest references and
explicit exclusions. The current working-tree contents are copied, including
uncommitted included source changes. No remote URL is captured, preventing
credentials in repository URLs from entering the manifest.

## Safety and resource limits

- The original tree and Git state are checked before and after the snapshot.
  Every included source and copied file is hashed again before publication.
- Files stream in 1 MiB blocks with per-block autorelease pools. The user
  chooses a byte budget; the default is 2 GB. Limits are 9,900 entries and
  48 directory levels, with at least 512 MB destination space retained.
- Private staging uses the reserved `.cloudnest-recovery` folder and is
  ineligible for ordinary archiving until a verified capsule is atomically
  published. Partial failure removes only known generated objects. Unexpected
  staging data remains private for review rather than being recursively erased.
- Git is invoked through fixed argument arrays with hooks, fsmonitor, external
  user/system configuration and optional index writes disabled. Metadata has
  time/output budgets. Missing promisor objects are not lazily fetched, and
  Git transport protocols are denied for these inspection commands.
  Cached index/object queries avoid `git status` and its
  possible clean-filter execution; raw file-to-index comparisons may report
  differences caused by line-ending/clean filters instead of running them.
  No source code, dependency script, build, container,
  remote fetch or model inference is executed.
- Symbolic links, repository internals, caches, regenerable dependencies,
  private `.env` files, keys, account configuration, database/VM storage and
  protected paths are excluded explicitly. Environment examples/templates must
  contain safe placeholder values for sensitive keys.
- Known credential signatures and sensitive literal assignments trigger file
  exclusion. This is a conservative detector, not a guarantee that arbitrary
  source code contains no secret. Review both included files and exclusions
  before any cloud upload. The snapshot has no automatic upload action.

The capsule contains `source/`, `CLOUDNEST_PROJECT.json` and `RESTORE.md`.
Original executable status is retained with owner-only staged permissions.
Original POSIX modes and timestamps are recorded for review. Resource forks,
ACLs, arbitrary extended attributes and hard-link topology are not preserved as
a full macOS backup. The source repository remains the recovery authority for
excluded information, and `permitsOriginalCleanup` is always false.

## Restore

1. Restore the CloudNest folder archive into a new location; verify its manifest.
2. Inspect the capsule manifest and exclusion list before executing anything.
3. Review dependency manifests and scripts, then rebuild dependencies using
   trusted tools appropriate to the project.
4. Restore private configuration from an independent secret store.
5. Reconnect Git remotes manually. The original `.git` directory is not copied.
6. Review original permissions and environment requirements in the manifest.

Docker image export/import and consistent database/volume backups are separate
procedures, not ordinary directory snapshots. No unsupported volume-copy or
live-database backup control is exposed by this feature. Project Time Capsule
does not authorize deleting original projects or claim dependency restoration
has been executed automatically.

Git command contracts were checked against the official manuals:
https://git-scm.com/docs/git-ls-files
https://git-scm.com/docs/git-diff-index
https://git-scm.com/docs/git-hash-object
