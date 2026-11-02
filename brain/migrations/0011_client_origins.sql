-- Exact, owner-approved extension origins belong to a scoped client, not a
-- deployment-wide allowlist. Empty by default for existing clients.
ALTER TABLE brain_clients ADD COLUMN origins TEXT NOT NULL DEFAULT '[]';
