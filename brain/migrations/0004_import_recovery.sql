-- Operational import state survives lost responses and index rebuilds.
-- Existing jobs remain resumable by cursor; their original request hash is unknown.
ALTER TABLE brain_import_jobs ADD COLUMN request_hash TEXT;
ALTER TABLE brain_import_jobs ADD COLUMN total INTEGER NOT NULL DEFAULT 0 CHECK(total BETWEEN 0 AND 20);
ALTER TABLE brain_import_jobs ADD COLUMN busy_token TEXT;
ALTER TABLE brain_import_jobs ADD COLUMN busy_until INTEGER NOT NULL DEFAULT 0;
UPDATE brain_import_jobs SET total=json_array_length(json_extract(payload,'$.records'));
CREATE INDEX brain_import_progress ON brain_import_jobs((next_index<total) DESC,created_at DESC,id);
