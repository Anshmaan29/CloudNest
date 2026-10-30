-- Portable Drive Markdown is canonical; these tables are rebuildable index,
-- operational recovery state, and owner review/audit state.
CREATE TABLE brain_heads (
 memory_id TEXT PRIMARY KEY, revision TEXT NOT NULL UNIQUE, project TEXT NOT NULL,
 visibility TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL,
 updated_at TEXT NOT NULL
);
CREATE TABLE brain_revisions (
 revision TEXT PRIMARY KEY, memory_id TEXT NOT NULL, parent_revision TEXT,
 version INTEGER NOT NULL, drive_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL,
 created_at TEXT NOT NULL
);
CREATE INDEX brain_revisions_memory ON brain_revisions(memory_id,version);
CREATE TABLE brain_intents (
 memory_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
 base_revision TEXT, revision TEXT NOT NULL, drive_id TEXT,
 payload TEXT NOT NULL, requested_by TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE brain_config (key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE brain_inbox (
 id TEXT PRIMARY KEY, client_id TEXT NOT NULL, project TEXT NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, source TEXT NOT NULL, category TEXT NOT NULL,
 created_at TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','approving','approved','rejected')),
 memory_id TEXT
);
CREATE INDEX brain_inbox_status ON brain_inbox(status,created_at);
CREATE TABLE brain_rate_limits (
 identity TEXT NOT NULL, minute INTEGER NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(identity,minute)
);
ALTER TABLE brain_revisions ADD COLUMN operation_id TEXT;
ALTER TABLE brain_revisions ADD COLUMN request_hash TEXT;
ALTER TABLE brain_intents ADD COLUMN request_hash TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX brain_revision_operation ON brain_revisions(operation_id);
CREATE TABLE brain_reindex_jobs (
 id TEXT PRIMARY KEY, state TEXT NOT NULL, cursor TEXT, scanned INTEGER NOT NULL DEFAULT 0,
 busy_token TEXT, busy_until INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
);
CREATE TABLE brain_reindex_rows (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, memory_id TEXT NOT NULL, drive_id TEXT NOT NULL,
 payload TEXT NOT NULL, PRIMARY KEY(job_id,drive_id)
);

ALTER TABLE brain_inbox ADD COLUMN operation_id TEXT;
ALTER TABLE brain_inbox ADD COLUMN approval_payload TEXT;
CREATE TABLE brain_clients (id TEXT PRIMARY KEY,sha256 TEXT NOT NULL UNIQUE,projects TEXT NOT NULL,permissions TEXT NOT NULL,expires_at TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL);
CREATE TABLE brain_client_revocations (id TEXT PRIMARY KEY,revoked_at TEXT NOT NULL);

CREATE TABLE brain_import_jobs(id TEXT PRIMARY KEY,payload TEXT NOT NULL,next_index INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL);

ALTER TABLE brain_reindex_rows ADD COLUMN conflict INTEGER NOT NULL DEFAULT 0;

ALTER TABLE brain_intents ADD COLUMN commit_id TEXT;
ALTER TABLE brain_reindex_rows ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';
CREATE TABLE brain_reindex_receipts(job_id TEXT NOT NULL,revision TEXT NOT NULL,memory_id TEXT NOT NULL,canonical_id TEXT NOT NULL,content_hash TEXT NOT NULL,version INTEGER NOT NULL,conflict INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(job_id,revision));
