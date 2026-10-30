-- Rebuildable index only. Canonical Drive writes are a later milestone.
CREATE TABLE memories (
  id TEXT PRIMARY KEY, project TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
  source TEXT NOT NULL, version INTEGER NOT NULL CHECK(version > 0),
  visibility TEXT NOT NULL CHECK(visibility IN ('approved','private','inbox')),
  updated_at TEXT NOT NULL, expires_at TEXT, canonical_drive_id TEXT
);
CREATE VIRTUAL TABLE memories_fts USING fts5(title, body, content='memories', content_rowid='rowid');
CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
END;
CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
  INSERT INTO memories_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE INDEX memories_project ON memories(project,visibility,updated_at);
CREATE TABLE audit (
  id INTEGER PRIMARY KEY, client_id TEXT NOT NULL, action TEXT NOT NULL, memory_id TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
