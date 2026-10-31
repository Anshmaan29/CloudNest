-- OAuth credentials are independent of canonical memory/index rebuilds.
-- Only SHA-256 digests of codes/access/refresh tokens are persisted.
CREATE TABLE oauth_clients (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, redirects TEXT NOT NULL,
  metadata TEXT NOT NULL, created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL
);
CREATE TABLE oauth_requests (
  id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES oauth_clients(id),
  redirect_uri TEXT NOT NULL, resource TEXT NOT NULL, challenge TEXT NOT NULL,
  state TEXT NOT NULL, scopes TEXT NOT NULL, created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','approved','denied')),
  grant_id TEXT, code_hash TEXT UNIQUE, code_expires_at INTEGER, code_used_at INTEGER,
  consume_nonce TEXT
);
CREATE INDEX oauth_requests_expiry ON oauth_requests(expires_at);
CREATE TABLE oauth_grants (
  id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES oauth_clients(id),
  resource TEXT NOT NULL, projects TEXT NOT NULL, permissions TEXT NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1)),
  rotation_count INTEGER NOT NULL DEFAULT 0,
  revoked_at INTEGER, revocation_reason TEXT
);
CREATE INDEX oauth_grants_client ON oauth_grants(client_id,resource);
CREATE TABLE oauth_access (
  hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL REFERENCES oauth_grants(id),
  scope TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
);
CREATE INDEX oauth_access_expiry ON oauth_access(expires_at);
CREATE INDEX oauth_access_grant ON oauth_access(grant_id);
CREATE TABLE oauth_refresh (
  hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL REFERENCES oauth_grants(id),
  scope TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  used_at INTEGER, consume_nonce TEXT
);
CREATE INDEX oauth_refresh_expiry ON oauth_refresh(expires_at);
CREATE INDEX oauth_refresh_grant ON oauth_refresh(grant_id);
