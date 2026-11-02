# Hibernate Project and Git recovery

Hibernate Project connects a reviewed portable source snapshot, a verified Drive
folder archive and an editable private Brain Memory Card. The original repository
is retained: excluded private working files and custom configuration are not a
complete byte-for-byte backup and never authorize original cleanup.

## Create and archive

1. Close the project's editors, terminals and development processes. Select its
   standalone Git root and a local snapshot destination outside the repository.
2. Leave **Include portable Git recovery** enabled to preserve Git state. Explicitly
   acknowledge that history, staged objects and reflogs may contain old credentials
   or personal data, even when the current working source excludes those files.
   Keep the Drive archive private. CloudNest does not publish Git history to Brain.
3. Create the local snapshot. All source bytes are streamed and hashed. Git
   metadata is inspected before/after export and source hashes/inventory are checked
   again before the recovery manifest is committed. Source changes stop completion.
4. Review every included file and exclusion in `CLOUDNEST_PROJECT.json`; review
   `GIT_RECOVERY.json` and the private-history warning. Explicitly approve upload.
   Resuming an existing capsule requires the history acknowledgment again.
5. The existing resumable folder queue uploads every file, verifies remote size
   and SHA-256 and commits its portable manifest. Only then can the Memory Card be
   generated. Its archive ID/Drive manifest and recovery-file hashes must bind to
   that actual verified archive.
6. Edit the card and explicitly save it private, or copy it for a manual handoff.
   Source contents, history, remote addresses and local paths are not automatically
   copied into the card. An AI needs separately approved access or reviewed context.

Git recovery contains a self-contained `git bundle` with all valid refs, HEAD and
reflog-reachable history, a separate pack of staged-only objects, the exact index,
local ignore rules and bounded reflog data. The extra staged pack matters: a bundle
of branch history alone does not preserve a newly staged blob. Reflogs preserve
older stash entries, not only the current `refs/stash` tip.

Git commands use fixed `/usr/bin/git`, a scrubbed environment, disabled hooks,
fsmonitor, external protocols and optional writes. Subprocess working directories
are descriptor-anchored. Git packing is single-threaded with bounded delta caches;
metadata is bounded, file I/O is streamed and each Git command has a two-minute
cancellable deadline. No source script, checkout, smudge/clean filter, dependency
installation or remote connection runs.

## Restore and resume

1. Find the verified archive in Archive Library and download the complete capsule
   into a new location. The normal storage engine verifies it without overwriting
   existing files.
2. Open **Hibernate Project → Restore Git project from a reviewed capsule**. Choose
   the verified local capsule and a destination parent with sufficient free space.
   A new project directory is required; an existing name is refused.
3. Review the private-history confirmation. CloudNest hashes recovery payloads and
   included source, creates a new private repository with an empty template,
   imports Git objects/refs/stashes, restores the index and copies working bytes.
   It does not use checkout or activate archived configuration/hooks/remotes.
4. Git object integrity, HEAD, all recorded refs and the exact staged index are
   verified before an exclusive atomic publication. Included source files retain
   their recorded timestamp and executable status. No original project is changed.
5. Read `RESTORE.md`. Inspect `git status` and `git stash list`; source files,
   staged-only content, unstaged edits, included untracked files, tracked working
   deletions, branches/tags and older stashes are recoverable. Detached HEAD and
   committed empty trees are supported.
6. Reconnect trusted Git remotes and credentials manually. Custom filters, Git
   text-conversion settings and global ignore rules need explicit owner review;
   they are not silently activated. Source bytes are copied raw, without filters.
7. Review dependency manifests/scripts before rebuilding. The generated checklist
   suggests appropriate trusted tool/lockfile workflows, including initial
   `npm ci --ignore-scripts`, fresh Python environments and recorded Swift/Rust/Go
   toolchains where their manifests are present. CloudNest executes none of them.

Cancelled or failed recovery preserves its private staging rather than recursively
removing unexpected data. Errors identify the `.cloudnest-project-restore-*` folder
under the selected parent for inspection. Retry into a new destination after
reviewing available space; do not treat an incomplete stage as a verified project.
The operation is local and can run with Brain offline. Restore a capsule from Drive
first; the local Git recovery step does not contact Google or any Git remote.

## Supported boundaries

An initialized, complete standalone repository is required. Linked worktrees,
submodules, sparse/split indexes, partial/shallow clones, external object stores,
reftable storage, active Git operations, unresolved index conflicts, tracked links
and missing/corrupt objects are refused. Convert or back up those cases using
trusted Git tools before using this workflow; CloudNest does not rewrite them.
An existing tracked working file excluded by the source privacy/metadata policy
also blocks Git recovery, rather than claiming that omitted content was restored.
Excluded ignored/private untracked files must be recovered separately.

This restores the recorded supported Git state and included working bytes, not
arbitrary filesystem metadata, live database state, every unreachable garbage
object or all user/system configuration. Recovered objects may contain private
history; neither local preview nor successful integrity checking proves they were
free of secrets. A user-selected local capsule must be trusted; hashes detect
changes against its recorded manifest, not a third-party author's authenticity.

Original-repository cleanup is never authorized. Complete source/Git restoration
must not be confused with verification that every excluded original byte can be
safely discarded.

## Verification

Generated repository tests cover two older stashes, branch/tag/history refs,
detached HEAD, index-only staged blobs, differing staged/working contents,
untracked files, tracked deletions, executable status, an empty committed tree,
ordinary folder archive/download/restore and private Memory Card binding.
Adversarial tests reject changed source/payloads, traversal refs, missing history
consent, excluded tracked private content and external object stores, and prove
that original hooks, filters, fsmonitor and remote configuration are not activated.
No real user repository or personal Git history is used by these tests. Actual
owner-project/device/Drive acceptance remains separate from generated fixtures.

The implementation follows the primary [Git bundle](https://git-scm.com/docs/git-bundle),
[pack-objects](https://git-scm.com/docs/git-pack-objects) and
[index-pack](https://git-scm.com/docs/git-index-pack) command contracts.
