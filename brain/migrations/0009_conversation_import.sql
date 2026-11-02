-- Selected excerpts only. Raw account exports are never persisted.
CREATE TABLE brain_conversation_imports(id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,provider TEXT NOT NULL,project TEXT NOT NULL,created_at TEXT NOT NULL,rolled_back_at TEXT);
CREATE TABLE brain_conversation_sources(fingerprint TEXT PRIMARY KEY,batch_id TEXT NOT NULL,proposal_id TEXT NOT NULL UNIQUE,provenance TEXT NOT NULL);
CREATE INDEX brain_conversation_sources_batch ON brain_conversation_sources(batch_id);
