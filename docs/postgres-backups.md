# PostgreSQL logical backups through local Docker

This optional owner-operated workflow exports one database in an explicitly selected, already-running local PostgreSQL container. It uses [pg_dump custom format](https://www.postgresql.org/docs/current/app-pgdump.html), whose logical export uses a consistent database snapshot while ordinary application reads and writes continue. It never copies PostgreSQL storage files, Docker volumes or virtual disks. It does not start Docker, start/stop containers, pull images, enumerate databases or change the source database for cleanup.

## Requirements and limits

- A running local Docker daemon at an existing Unix socket and a trusted Docker CLI. The helper uses a new mode-700 configuration directory with empty Docker authentication settings and a restricted host environment.
- One container name or immutable container ID supplied by the owner. Only that container is inspected. Its running state and full immutable ID are checked before every command; names are never reused as command targets after resolution. See [Docker container inspect](https://docs.docker.com/reference/cli/docker/container/inspect/) and [Docker exec](https://docs.docker.com/reference/cli/docker/container/exec/).
- The container must provide the `postgres` OS user, PostgreSQL client tools, `/usr/bin/env` and `/usr/bin/timeout` supporting `-k 5 <seconds> <command>`. Missing or incompatible tools fail safely. Compatibility with a real image must be checked on an owner-approved disposable target.
- PostgreSQL must accept local peer/trust authentication over `/var/run/postgresql` on its default port. Database and role names must be simple ASCII identifiers, at most 63 characters. No password input, `.pgpass`, service configuration, remote host, arbitrary connection string or interactive credential prompt is supported.
- Dumps contain one database's logical objects and data. Cluster-wide roles, other databases, application files, continuous WAL and point-in-time recovery are not included. This is not a replacement for an application's production disaster-recovery procedures.

`docker exec` always uses the pinned container ID, `--user postgres`, and working directory `/`. Inside it, `/usr/bin/env -i` provides a fixed PATH, locale, local connection timeout, `PGPASSFILE=/dev/null` and `PGSERVICEFILE=/dev/null`. PostgreSQL arguments fix the Unix socket and pass the validated role/database as separate arguments. No shell is invoked and no host/container password value is collected or logged. Source database content remains private in the backup files.

## Export and verification

Choose a local destination outside protected, cloud and repository paths. Each export starts in a new private `.cloudnest-recovery/postgres-<UUID>` directory. `pg_dump --format=custom --no-password` streams through bounded one-megabyte buffers while size, free space and SHA-256 are tracked. Source data and its container remain in place.

Successful command completion alone is insufficient. The closed dump's size and streamed hash are rechecked, its `PGDMP` header is checked, and the selected container's `pg_restore --list --format=custom` must parse it successfully. TOC output is bounded and discarded; it is not exposed as a log. Changed files, unexpected members or uncertain identity block publication. An exclusive rename publishes a new `PostgresBackup-<UUID>` folder containing exactly `database.pgdump` and `CLOUDNEST_POSTGRES.json`.

The manifest records source database/role, selected container reference and immutable ID, creation time, bytes and SHA-256. `permitsOriginalCleanup` is always false. Local source metadata stays in this private, owner-controlled artifact. Cloud upload is a separate explicit review action through the native view's optional archive callback.

Default limits are a 20 GB archive, 512 MB host free-space margin, 15 seconds per metadata command, 10 minutes per transfer/verification stage and 8 MB of discarded archive-list output. Values have enforced upper bounds. Compressed dump size does not predict restored database size; ensure Docker/PostgreSQL storage has adequate capacity separately. No real resource-usage or throughput targets are claimed from these limits.

## Restore only a trusted archive into a new database

Restoring PostgreSQL archives can execute arbitrary SQL with the selected role's privileges. A privileged role can affect resources beyond the newly created database. Only restore an archive and container you trust; review SQL using PostgreSQL's supported tools when necessary. `pg_restore --list` validates parsing, not the safety of archive SQL. See [PostgreSQL's restore warning and options](https://www.postgresql.org/docs/current/app-pgrestore.html).

The native view displays the exact proposed `cloudnest_restore_<UUID>` database, immutable container ID and role before approval. The core API generates this name; callers cannot supply an arbitrary existing target name. Before database creation, restore:

1. Revalidates the approved manifest digest, private paths, file ownership and links.
2. Verifies the source dump's exact byte count and SHA-256.
3. Creates and verifies a private copy, then runs `pg_restore --list` on that copy.
4. Uses [createdb](https://www.postgresql.org/docs/current/app-createdb.html) with `template0` to create the new database. If it exists or creation fails, no restore command follows.
5. Runs `pg_restore --single-transaction --exit-on-error --no-owner --no-privileges --no-tablespaces` only against the new name.

No `dropdb`, overwrite, `--clean`, role creation or privilege escalation command is issued. Arbitrary SQL in a trusted archive still runs with the selected role's permissions; this workflow is not a database security sandbox. Successful tool exit must be followed by the owning application's validation of the restored data.

## Interruption and recovery

Before `createdb`, the private session writes and fsyncs `01-create-planned.json` with the exact target name, container ID, role and source digest. Subsequent exclusive records mark confirmed creation and completed restoration. Failure retains the new database, approved input copy and available records. The error exposes the planned name and private recovery-directory path for owner inspection. Source backups and databases are never automatically removed.

Stopping the host Docker CLI does not guarantee that Docker's engine-side exec or PostgreSQL server work has stopped. A fixed `/usr/bin/timeout` wrapper bounds the container client command and escalates after five seconds; server work may still outlive a disconnected client. PostgreSQL tools or archive SQL can also override session timeout settings, so `PGOPTIONS` is not treated as a rollback guarantee. Inspect an interrupted restore's database and server state before deciding what to do. CloudNest never automatically drops an uncertain or failed target.

After successful restore, only unchanged, job-owned private copies/configuration are removed; recovery records remain. Failed dump staging and failed restore input copies remain private for review. Cleanup never recursively removes a user tree or touches unrelated files.

## Validation status

Automated tests use a fake Docker executable and disposable files/socket fixtures. They verify immutable/fixed argv, private empty configuration, credential-free host environment, custom-list validation, mismatches/tampering, source-identifier restrictions, changed/stopped containers, protected/linked paths, exclusive publication, new-name creation before transactional restore, existing-target refusal, preserved failure records, and cancellation/time/output/disk budgets.

No real Docker daemon, container or user database was queried during development. A real PostgreSQL container round trip, concurrent-write consistency check, image/tool compatibility check and application-level restore validation remain pending an explicitly approved disposable target. The optional native controls and review-before-cloud-archive callback are wired into the app. Native compilation is verified; real-container and visual workflow acceptance remain separate pending checks.
