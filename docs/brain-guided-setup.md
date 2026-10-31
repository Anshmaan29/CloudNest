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

For an explicitly controlled browser handoff, add `--manual-browser`. The helper writes `authorization.private.url` as mode 600 inside the new private setup directory and prints **only that file's path**. Open its URL with your browser or an authorized browser-control tool while the helper remains running. The helper does not launch `/usr/bin/open` in this mode. The URL contains the temporary state and PKCE challenge; keep it private, and complete consent within three minutes. No authorization code or token is written to this handoff file. Default setup continues to open the system browser normally.

By default, setup creates a fresh UUID directory under `~/Library/Application Support/CloudNest/BrainSetup/`. You may supply `--private-dir /absolute/new-private-directory`; existing directories are never overwritten. The directory is mode `700`; files are mode `600`. A private `.gitignore` ignores every bundle member as an additional precaution if a parent is later initialized as a Git repository:

| Private file | Purpose |
| --- | --- |
| `setup.private.json` | Reviewed Worker identity and configuration digest |
| `wrangler.private.json` | Absolute source/migration/assets paths and enabled Brain configuration |
| `secrets.private.json` | Dedicated Google client/refresh grant, owner verifier, vault signing key |
| `owner-token.private.txt` | Your owner credential, never printed or passed as a command argument |
| `connection.private.json` | `{schemaVersion:1, baseURL, ownerToken}` for an explicit native import |
| `deployment.private.json` | Added during deployment: durable progress and bundle fingerprints |

The five new Worker secrets are `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`, `OWNER_TOKEN_SHA256`, and `VAULT_SIGNING_KEY`. The signing key is 32 random bytes encoded as exactly 64 lowercase hexadecimal characters, distinct from the owner verifier, matching the Brain's actual configuration/signature contract. Existing `CLIENTS_JSON` registrations are never read as values or overwritten. Keep the signing key backed up privately: replacing it invalidates signatures on existing canonical memories. Do not upload the bundle or its logs to GitHub, support tickets, or chat.

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

After a migration/build/deploy failure following a confirmed secret upload, rerunning the same prepared bundle skips uploading the secrets again. An interruption whose secret-upload result is uncertain fails safely if a signing key is observed remotely; inspect the private journal and Cloudflare before continuing. A different bundle's journal, changed configuration, unsafe file permissions, or missing secrets blocks continuation. This initial deployment flow never rotates an existing Brain's signing key. Use the separately reviewed Google grant renewal command below to retain the existing owner identity and vault key.

After deployment, explicitly import `connection.private.json` in the native Brain settings (or enter the origin and owner token privately). Verify an approved test memory, correction, deletion, restricted-client denial, remote index recovery, and a real MCP retrieval with the Mac offline. Successful CLI deployment alone does not prove these acceptance workflows or provider availability.

## Renew the existing Brain Google grant

After reviewing Google's OAuth publication settings, obtain fresh consent using the **same dedicated Desktop client and Google Drive account**. Google grants can still expire or be revoked; publication is not a guarantee of permanent authorization.

Use the existing private manifest, without a new OAuth JSON or setup directory:

```sh
node scripts/setup-brain.mjs --renew-google-grant \
  --prepared "/absolute/private/setup.private.json" \
  --confirm-worker cloudnest-brain --dry-run

node scripts/setup-brain.mjs --renew-google-grant \
  --prepared "/absolute/private/setup.private.json" \
  --confirm-worker cloudnest-brain --manual-browser
```

The dry run checks the local bundle and recipient only. The second command authorizes fresh Google consent and replacement of **only `GOOGLE_REFRESH_TOKEN`** on that existing Worker. Without `--manual-browser`, the normal system browser opens. With it, a unique private renewal directory receives `authorization.private.url`; only its path is printed. Complete the original loopback consent in three minutes. Never copy authorization codes or tokens into chat.

Before accepting a replacement, the helper refreshes the old grant and requests only `user(permissionId)` from Google's `about.get`. It hashes that opaque account identifier and compares it to the newly consented grant. It does not request an email address, display name, or profile picture. The official [about.get scope reference](https://developers.google.com/workspace/drive/api/reference/rest/v3/about/get) permits `drive.file`; the [User resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/User) documents `permissionId`.

A mode-600 `google-account.private.json` caches that account hash, bound to the Worker, configuration, and client and authenticated with the unchanged vault signing key. This allows later renewal when an old grant expires. If the old grant already fails and no authenticated binding exists, the helper stops before consent or upload. It never guesses the account or accepts a replacement account. Keep the private binding with the original recovery bundle.

The owner token and verifier, vault signing key, Desktop client ID/secret, prepared manifest, connection file, and Wrangler configuration remain unchanged. The helper verifies an existing Worker and all original Brain secret names, stages a private candidate, and uses Wrangler's [single-secret put](https://developers.cloudflare.com/workers/wrangler/commands/workers/#secret-put) with the refresh value on stdin. It does not bulk-upload secrets, migrate D1, deploy source, replace AI registrations, or touch Storage's Keychain. The existing native connection import stays valid.

`google-renewal.private.json` records the account-bound transaction and a private `grant-renewal-<UUID>/` directory retains staged recovery files. An upload with an uncertain result stops automatic retries and ordinary deployment from that bundle. Review the private journal and Worker locally; do not delete the evidence, generate a new vault key, or attempt to bypass the check. If upload acknowledgement was durably recorded but local file replacement was interrupted, repeating the same renewal command finishes only the local commit, without another consent or secret upload.

A private `setup-operation.private.lock` prevents concurrent deploy/renewal operations. After an abrupt process exit, a retained lock fails safely and requires local inspection of its process and journal before further work. Never remove a lock while its setup process is active. No override or force-reset option exists.

After success, verify actual canonical memory reads and MCP retrieval against the deployed Brain. A successful secret update alone does not prove those workflows.

## Local verification

```sh
node --test scripts/setup-brain.test.mjs
```

Tests use generated fake credentials and loopback HTTP only. They cover PKCE/state verification, hostile callbacks, denial/timeouts, private path/permission/link checks, JSONC URLs/comments, write-free CLI validation, explicit deployment confirmation, stdin-only secret transfer, existing-key refusal, interrupted deployment recovery, same-account grant renewal, wrong-account denial, signed account bindings, stdin-only refresh replacement, and interrupted renewal recovery. No Google login, real credentials, Cloudflare login, remote writes, or paid services are used by these tests.
