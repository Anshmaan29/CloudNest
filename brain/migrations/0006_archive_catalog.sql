-- Explicit owner-published metadata only. No Drive credentials, paths or contents.
CREATE TABLE brain_archives (
  id TEXT PRIMARY KEY, project TEXT NOT NULL,
  visibility TEXT NOT NULL CHECK(visibility IN ('private','approved')),
  name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('file','folder')),
  bytes INTEGER NOT NULL CHECK(bytes >= 0), sha256 TEXT,
  drive_file_id TEXT NOT NULL, manifest_file_id TEXT NOT NULL,
  drive_target TEXT NOT NULL CHECK(drive_target IN ('file','folder','manifest')),
  file_count INTEGER, checked_at TEXT NOT NULL, local_state TEXT NOT NULL
    CHECK(local_state IN ('original','recovery','removed','unknown')),
  published_at TEXT NOT NULL
);
CREATE INDEX brain_archives_visibility_project ON brain_archives(visibility,project,id);
CREATE TABLE brain_restore_requests (
  id TEXT PRIMARY KEY, archive_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','completed','dismissed')),
  created_at TEXT NOT NULL, acknowledged_at TEXT
);
CREATE UNIQUE INDEX brain_restore_one_pending ON brain_restore_requests(archive_id) WHERE status='pending';
CREATE INDEX brain_restore_pending ON brain_restore_requests(status,created_at,id);
