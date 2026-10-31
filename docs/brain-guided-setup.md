# Private Brain setup

This helper prepares a separate Google grant for the remote Brain. It does not read Storage's Keychain credentials, sign in unattended, or deploy by default. Storage works independently throughout setup. Use the existing free-tier Worker and D1 database; this flow creates neither resources nor subscriptions.

## Before starting

1. Install this repository's pinned dependencies with `npm ci` and use a Node version supported by the pinned Wrangler.
2. In your Google Cloud project, enable Drive API and create a **separate Desktop App OAuth client** named for CloudNest Brain. Download its JSON outside every Git repository. Keep Storage's client and grant separate. The helper uses the official system-browser, PKCE S256, random-state, IPv4 loopback flow and requests only `drive.file`. See [Google's Desktop OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).
3. Review your private `brain/wrangler.local.jsonc`: existing Worker name, existing `account_id`, existing D1 `DB` binding/database ID, `PUBLIC_ORIGIN` as the existing HTTPS origin, and your intended browser `ALLOWED_ORIGINS`. Keep the public template free of real IDs and endpoints. For the console, configure assets directory `../web/dist` with `run_worker_first: true` and the existing console binding. The helper creates a separate private deployment configuration with `BRAIN_ENABLED: "true"`; it never edits the source configuration.
4. Sign in to Wrangler separately if needed using its normal login command. Do not paste account tokens into this helper or chat. Confirm the account matches your private configuration. Terminal shows a hash fingerprint of the configured account ID, rather than disclosing the ID.

Google external OAuth projects in **Testing** issue Drive refresh grants lasting seven days. Review the appropriate consent-screen publication/personal-use settings before relying on long-term remote availability. Grants can also be revoked or expire later. Setup does not change Google's publication status. See [Google's refresh-token expiration rules](https://developers.google.com/identity/protocols/oauth2#expiration).

## Validate without signing in

From the repository root, replacing the JSON filename with your own local path:

```sh
node scripts/setup-brain.mjs \
  --oauth-client "$HOME/Downloads/your-dedicated-brain-desktop-client.json" \
  --dry-run
```

`--validate` is equivalent to `--dry-run`. Neither opens a browser, writes files, obtains a grant, accesses Cloudflare, or deploys. You can pass `--config /absolute/private/config.jsonc` explicitly. Credentials and prepared output are refused inside any Git worktree or bare repository, including symlink aliases.

## Prepare a new grant locally

Run the same command without `--dry-run`. Finish consent in your browser; never copy the returned authorization code into chat. A three-minute callback deadline prevents an abandoned listener remaining indefinitely. Rejected callbacks cannot replace the session's state or verifier.

By default, setup creates a fresh UUID directory under `~/Library/Application Support/CloudNest/BrainSetup/`. You may supply `--private-dir /absolute/new-private-directory`; existing directories are never overwritten. The directory is mode `700`; files are mode `600`. A private `.gitignore` ignores every bundle member as an additional precaution if a parent is later initialized as a Git repository:

| Private file | Purpose |
| --- | --- |
| `setup.private.json` | Reviewed Worker identity and configuration digest |
| `wrangler.private.json` | Absolute source/migration/assets paths and enabled Brain configuration |
| `secrets.private.json` | Dedicated Google client/refresh grant, owner verifier, vault signing key |
| `owner-token.private.txt` | Your owner credential, never printed or passed as a command argument |
| `connection.private.json` | `{schemaVersion:1, baseURL, ownerToken}` for an explicit native import |
| `deployment.private.json` | Added during deployment: durable progress and bundle fingerprints |

The five new Worker secrets are `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`, `OWNER_TOKEN_SHA256`, and `VAULT_SIGNING_KEY`. Existing `CLIENTS_JSON` registrations are never read as values or overwritten. Keep the signing key backed up privately: replacing it invalidates signatures on existing canonical memories. Do not upload the bundle or its logs to GitHub, support tickets, or chat.

## Review, then deploy explicitly

Inspect the private configuration locally and confirm its account, Worker, D1 database, origin, and source paths. Use the printed manifest path:

```sh
node scripts/setup-brain.mjs --deploy \
  --prepared "/absolute/private/setup.private.json" \
  --confirm-worker cloudnest-brain --dry-run

node scripts/setup-brain.mjs --deploy \
  --prepared "/absolute/private/setup.private.json" \
  --confirm-worker cloudnest-brain
```

The second command authorizes the concrete upload and deployment. It first verifies an existing deployed Worker and lists secret **names**. It refuses an already initialized Brain, then sends the new secrets to Wrangler on stdin, applies every pending D1 migration (including client OAuth migrations), builds the console, and deploys with strict checks and automatic resource configuration disabled. Subprocess output goes only to private mode-600 logs; the terminal never prints credentials or provider response bodies. The pinned Wrangler's documented [secret bulk command](https://developers.cloudflare.com/workers/wrangler/commands/workers/#secret-bulk) accepts stdin; command flags were also checked with Wrangler 4.156.0 `--help`.

After a migration/build/deploy failure following a confirmed secret upload, rerunning the same prepared bundle skips uploading the secrets again. An interruption whose secret-upload result is uncertain fails safely if a signing key is observed remotely; inspect the private journal and Cloudflare before continuing. A different bundle's journal, changed configuration, unsafe file permissions, or missing secrets blocks continuation. This helper does not rotate an existing Brain's key or automate renewal of an expired Google grant; renewals must preserve the original vault key and owner identity through an explicitly reviewed operation.

After deployment, explicitly import `connection.private.json` in the native Brain settings (or enter the origin and owner token privately). Verify an approved test memory, correction, deletion, restricted-client denial, remote index recovery, and a real MCP retrieval with the Mac offline. Successful CLI deployment alone does not prove these acceptance workflows or provider availability.

## Local verification

```sh
node --test scripts/setup-brain.test.mjs
```

Tests use generated fake credentials and loopback HTTP only. They cover PKCE/state verification, hostile callbacks, denial/timeouts, private path/permission/link checks, JSONC URLs/comments, write-free CLI validation, explicit deployment confirmation, stdin-only secret transfer, existing-key refusal, and interrupted deployment recovery. No Google login, real credentials, Cloudflare login, remote writes, or paid services are used by these tests.
