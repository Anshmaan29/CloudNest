# Hibernate Project and AI Memory Card

The workflow connects a real source snapshot to a verified Drive archive and a reviewed, private Brain card. It does not delete the original repository.

1. Close project editors, terminals and development processes. Select the inactive Git root and a local snapshot destination outside the repository.
2. Create a Project Time Capsule. CloudNest captures source, important assets, Git commit/branch/dirty/untracked metadata, dependency manifests and lockfiles, and restoration instructions. Inspect the complete included-file and exclusion inventory.
3. Explicitly approve archiving. The parent application uses the existing restart-safe folder queue and waits for actual remote integrity verification.
4. CloudNest checks that the verified folder manifest covers the exact capsule metadata and every included source file's size and SHA-256. Only then can it generate a Memory Card containing archive references, detected stack, dependency filenames, Git state, user-supplied decisions and next steps.
5. Edit the card and explicitly save it privately to Brain, or copy it as a manual context pack. Source contents, original absolute paths and credentials are not automatically copied into the card. Private cards require deliberate context sharing with AI clients.

Restore the linked archive through Archive Library into a new empty destination, verify it, read `RESTORE.md`, review source/dependency scripts, recover secrets separately, reconnect Git manually and recreate dependencies using trusted tools. No source script, package installation, hook or container is executed by this workflow.

## Safety and scope

The existing capsule engine excludes `.git`, credentials and suspicious secret content, regenerable dependencies/caches, symbolic links, databases/virtual disks and unsupported metadata. Exclusions are explicit. Secret detection is conservative rather than exhaustive; review before upload. The wrapper adds bounded, fail-closed open-file/tree checks before and after snapshot creation and before archive. Known running model runtimes also conservatively block this shared inactivity check. Checks are point-in-time; keep development processes closed until completion.

Git commit, branch and dirty/untracked inventories are preserved. Git object history and remote URLs are deliberately omitted: either may retain credentials excluded from the working tree. This is not a complete Git recovery backup. The original remains necessary for history, excluded assets and metadata. Full original-project reclamation is a separate release gate requiring independently verified coverage; this feature never authorizes it.

The optional Brain can be offline without affecting Storage. A completed local snapshot and persisted folder transfer remain recoverable if card saving fails. Use “Resume from existing local snapshot” after restart. The application should reuse the matching verified folder job when present; the core will re-bind its exact capsule metadata before regenerating a card. Unsaved edits and owner notes must be re-entered after closing the view. No automatic inferred decisions are added.

## Integration and verification

`ProjectHibernation.create` returns `ProjectCapsuleResult`. `loadCapsule(at:safety:)` recovers local metadata as untrusted input. `memoryCard(capsule:verifiedArchive:decisions:nextAction:)` requires the full verified `FolderArchiveJob`, validates archive/capsule binding and returns an editable `ProjectMemoryCard` with fixed private visibility.

The native view's `onArchive` callback must persist the queue job before transferring, reuse a matching existing job when available, await actual verification and return its full record. `onSaveCard` receives the owner's edited card and must use the authenticated private-memory API. Neither callback may report success merely because an operation was queued.

Generated-project integration tests exercise source snapshot, exclusions, resumable archive engine, verified Memory Card binding, restored matching source, original retention, changed metadata rejection and actual open-file refusal. Live Google Drive/Brain acceptance and native visual QA remain separate checks.
