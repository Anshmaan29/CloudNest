# Official implementation references

Reviewed 2026-10-31. Recheck at provider integration time.

- Google desktop OAuth, PKCE, loopback redirects, refresh and revoke:
  https://developers.google.com/identity/protocols/oauth2/native-app
- Limited `drive.file` scope:
  https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- Resumable upload sessions, 256 KiB chunk alignment, 308 ranges and expiry:
  https://developers.google.com/workspace/drive/api/guides/manage-uploads
- Drive file metadata, including optional server-provided SHA-256:
  https://developers.google.com/workspace/drive/api/reference/rest/v3/files
- Pre-generated IDs:
  https://developers.google.com/workspace/drive/api/reference/rest/v3/files/generateIds
- MCP 2025-11-25 compatibility transport and origin checks:
  https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP HTTP authorization (future interactive OAuth implementation):
  https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- Official SDK (used as an independent protocol test client):
  https://github.com/modelcontextprotocol/typescript-sdk
- D1 SQLite/FTS5 statements:
  https://developers.cloudflare.com/d1/sql-api/sql-statements/
- Usage-limited free tiers:
  https://developers.cloudflare.com/workers/platform/pricing/
  https://developers.cloudflare.com/d1/platform/pricing/

The current feasibility server explicitly targets the 2025-11-25 compatibility
protocol, not every newer protocol revision. No provider-specific connection
is claimed based solely on standards support.

- Codex HTTP MCP and environment-sourced bearer credentials (live tested):
  https://learn.chatgpt.com/docs/extend/mcp
- Wrangler OAuth/keyring and scoped login:
  https://developers.cloudflare.com/workers/wrangler/commands/general/#login
