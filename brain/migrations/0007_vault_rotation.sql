-- Rotation checkpoints attest exact historical bytes under the replacement key.
-- No secret key, old or new, is persisted in D1.
CREATE TABLE brain_vault_rotations (
 id TEXT PRIMARY KEY, state TEXT NOT NULL CHECK(state IN('scanning','signing','verifying','complete')),
 key_sha256 TEXT NOT NULL, root_id TEXT, root_hash TEXT, root_verified INTEGER NOT NULL DEFAULT 0, cursor TEXT, scanned INTEGER NOT NULL DEFAULT 0,
 busy_token TEXT, busy_until INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX brain_vault_one_active ON brain_vault_rotations((1)) WHERE state<>'complete';
CREATE TABLE brain_vault_rotation_rows (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, memory_id TEXT NOT NULL,
 drive_id TEXT NOT NULL, payload TEXT NOT NULL,
 seen_record INTEGER NOT NULL DEFAULT 0, verified_record INTEGER NOT NULL DEFAULT 0,
 receipt_id TEXT, receipt_hash TEXT, verified_receipt INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(job_id,revision), UNIQUE(job_id,drive_id)
);
CREATE TABLE brain_vault_rotation_receipts (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, drive_id TEXT NOT NULL,
 content_hash TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(job_id,drive_id)
);
CREATE TABLE brain_vault_rotation_heads (
 job_id TEXT NOT NULL, memory_id TEXT NOT NULL, revision TEXT NOT NULL, payload TEXT NOT NULL,
 PRIMARY KEY(job_id,memory_id)
);
CREATE TABLE brain_reindex_untrusted (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, content_hash TEXT NOT NULL,
 PRIMARY KEY(job_id,revision,content_hash)
);
CREATE TABLE brain_reindex_retired (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, content_hash TEXT NOT NULL,
 PRIMARY KEY(job_id,revision,content_hash)
);

CREATE TABLE brain_vault_rotation_roots (
 job_id TEXT NOT NULL, drive_id TEXT NOT NULL, content_hash TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(job_id,drive_id)
);
CREATE TABLE brain_reindex_checkpoints (
 job_id TEXT NOT NULL, drive_id TEXT NOT NULL, content_hash TEXT NOT NULL,
 authenticated INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(job_id,drive_id)
);
CREATE TABLE brain_reindex_checkpoint_receipts (
 job_id TEXT NOT NULL, revision TEXT NOT NULL, content_hash TEXT NOT NULL,
 PRIMARY KEY(job_id,revision)
);
