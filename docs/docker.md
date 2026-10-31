# Optional Docker image backups

CloudNest exports one selected local image into a portable image archive and
checks its size and SHA-256. It never removes images or claims that exporting
frees Docker's SSD usage. Containers continue running. This module does not back
up writable container layers, named volumes, databases, build caches or Docker's
live virtual disk.

## Requirements and native workflow

Use an existing Docker CLI with an already running local Unix-socket daemon.
CloudNest checks known CLI installation locations and the standard local sockets
only after an explicit action. Custom remote contexts, SSH/TCP daemons and daemon
auto-start are unsupported. CloudNest does not install Docker.

1. Open Docker image backups and press **Check Docker**. This checks the local
   server version without listing containers, volumes or images.
2. Enter one local image name, tag or SHA-256 ID and press **Resolve image ID**.
   Only that image's immutable ID is requested; full inspect output, including
   image environment values, is never collected.
3. Choose a local destination outside repositories, cloud and protected paths.
   Review the immutable ID and approve **Export selected image**. The configurable
   archive limit defaults to 20 GB and is capped at 100 GB. The destination must
   keep a 512 MB safety margin.
4. A completed `DockerImage-<UUID>/` contains `image.tar` and
   `CLOUDNEST_DOCKER.json`. The manifest records the selected reference, immutable
   image ID, ISO-8601 creation time, byte count and SHA-256. Review images for
   embedded credentials or private layers before any cloud archive. CloudNest
   does not scan arbitrary image contents for secrets.
5. To restore, choose a CloudNest image backup, review its manifest, and explicitly
   approve **Verify and import**. A private temporary copy on the Mac is checked
   against the approved manifest before it is passed to Docker over standard
   input. Allow space for that copy plus 512 MB; Docker also needs space in its own
   image store. The expected image ID is inspected after a successful load.

The optional native archive callback can open CloudNest's ordinary folder archive
review for a completed backup. It must not automatically upload it. The source
image remains in Docker throughout this workflow.

## Trust and safety boundaries

The app invokes only fixed Docker arguments: `version --format`, `image inspect
--format`, `image save <immutable ID>`, and `image load --quiet`. It does not use a
shell or accept arbitrary Docker commands. A private owner-only empty `--config`
and explicit local `--host unix://…` replace inherited Docker contexts, registry
configuration and credential environment variables. Export and import never pull,
run or build an image. The installed Docker CLI itself must be trusted.

Export bytes stream through a 1 MiB read buffer, with output and time budgets.
Metadata output is limited to 64 KiB and 15 seconds. The transfer deadline defaults
to one hour. Progress updates are bounded and CLI waiting occurs only while a
user-requested operation is active; there is no background Docker polling.

Exports use exclusive owner-only files in the selected destination's private
`.cloudnest-recovery/docker-<UUID>/` staging area. Size and streamed SHA-256 are
checked against a second disk read; named file identities and the destination are
revalidated before an exclusive final-directory rename. Existing files or backup
directories are never overwritten. Failure, cancellation or a crash cannot
publish a partial export. Incomplete staging is not resumed or automatically
promoted after restart; it may remain in this private area for manual review.
Ordinary scanning excludes this reserved staging directory. Import uses a private
OS temporary folder named `cloudnest-docker-<UUID>`; incomplete copies may remain
there if interrupted. Cleanup only removes app-created files with matching recorded
identities and empty owned directories; changed or unknown data is retained.

Import accepts only fixed archive/manifest names and fully local regular files;
symlinks, hard links, traversal names, oversized manifests, changed approvals and
checksum mismatches are refused. The original backup is unchanged. A matching
checksum establishes integrity, **not authenticity**: only approve backups from
sources you trust. Docker load can restore image tags. Cancelling or timing out a
load cannot roll back layers the daemon has already accepted; inspect Docker
before retrying. CloudNest terminates only its own CLI child, never unrelated
Docker processes or the daemon. No container is started by import.

Application-consistent volume and database exports need separate, owner-reviewed
procedures. There are no controls implying these backups are supported.

## Verification and remaining release checks

Automated tests use a generated executable harness and a fixture Unix socket,
never the owner's Docker installation or private configuration. They verify fixed
arguments and immutable IDs, environment isolation, exact exported/imported bytes,
output budgets, failure/timeout/cancellation, protected and symlink destinations,
no overwrite, changed staging, approved-manifest binding, mismatched hashes,
symlink/hard-link refusal and traversal rejection.

A real Docker save/load round trip and native visual inspection remain release
checks requiring an owner-selected disposable image and a running daemon. Harness
success is not a claim that a live Docker integration has been tested. Memory and
throughput against real images have not been measured.

Official CLI references: [image save](https://docs.docker.com/reference/cli/docker/image/save/),
[image load](https://docs.docker.com/reference/cli/docker/image/load/),
[image inspect](https://docs.docker.com/reference/cli/docker/image/inspect/).
