-- Single-owner browser auth. Owner-verifier epoch changes invalidate all prior
-- passkeys, challenges and sessions without trusting the old verifier again.
CREATE TABLE brain_browser_owners(epoch TEXT PRIMARY KEY,user_handle TEXT NOT NULL);
CREATE TABLE brain_browser_passkeys(
 id TEXT PRIMARY KEY,epoch TEXT NOT NULL,public_key TEXT NOT NULL,counter INTEGER NOT NULL,
 label TEXT NOT NULL,transports TEXT NOT NULL,created_at INTEGER NOT NULL,last_used_at INTEGER,
 auth_nonce TEXT,revoked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX brain_browser_passkeys_epoch ON brain_browser_passkeys(epoch,revoked);
CREATE TABLE brain_browser_challenges(
 token_sha256 TEXT PRIMARY KEY,epoch TEXT NOT NULL,kind TEXT NOT NULL,
 challenge TEXT NOT NULL,binding_sha256 TEXT NOT NULL,expires_at INTEGER NOT NULL,label TEXT
);
CREATE INDEX brain_browser_challenges_expiry ON brain_browser_challenges(expires_at);
CREATE TABLE brain_browser_sessions(
 id TEXT PRIMARY KEY,token_sha256 TEXT NOT NULL UNIQUE,epoch TEXT NOT NULL,credential_id TEXT NOT NULL,
 created_at INTEGER NOT NULL,idle_until INTEGER NOT NULL,absolute_until INTEGER NOT NULL
);
CREATE INDEX brain_browser_sessions_epoch ON brain_browser_sessions(epoch,absolute_until);
