# Account setup — Phase 0

These instructions describe a fresh installation using your own accounts.
No account IDs, personal endpoints or credentials are included in the public
repository. Copy `brain/wrangler.example.jsonc` to ignored
`brain/wrangler.local.jsonc` for your deployment, and pass that local config
with `--config`. Keep the tracked example configuration generic. No paid plan
is required for the disposable feasibility checks.

## Google: cloudnest-os

1. Open https://console.cloud.google.com/projectcreate and create project
   `cloudnest-os`. Google project IDs are globally unique; if unavailable,
   choose a suffix and use the actual ID in console links. The project display
   name can still be CloudNest OS.
2. In that project, enable **Google Drive API**:
   https://console.cloud.google.com/apis/library/drive.googleapis.com?project=cloudnest-os
3. Open **Google Auth Platform → Branding / Audience**. Configure personal
   testing, select External if applicable, and add your own Google account as
   a test user. Use truthful app/contact details. Stay in Testing for now.
4. In **Data Access**, request only
   `https://www.googleapis.com/auth/drive.file`.
5. In **Clients → Create client**, select **Desktop app**, name it
   `CloudNest macOS`, and download the JSON to a private folder outside the
   repository. Do not choose Web, Android or iOS as the client type.
6. Open CloudNest → Settings & Security → **Import OAuth JSON…**, select it,
   then **Sign in with Google**. Complete consent in your normal browser.
   The app uses PKCE S256, random state and a short-lived IPv4 loopback
   listener on a random port. It requests offline access for resumable jobs.
   The callback times out after three minutes; retry sign-in if needed.
7. The app copies configuration and tokens into Keychain under `org.cloudnest.os`.
   Retain or remove the downloaded JSON according to your own recovery policy;
   CloudNest never deletes the download. Testing-mode refresh tokens can expire;
   reconnect when Google requires it.

### Disposable Drive round trip

Create a new folder outside any Git checkout with one small disposable file.
CLI steps, from the repository root:

```sh
build/cloudnest scan /path/to/disposable-folder
build/cloudnest archive /path/to/disposable-folder /path/to/disposable-folder/test.bin
build/cloudnest jobs
```

Confirm the file **and** recovery manifest exist in the new CloudNest Storage
Drive folders. The job must say `verified`. A missing SHA-256, mismatched
size, inaccessible object or unverified manifest fails closed.

Interrupt a larger test upload by quitting CloudNest or disabling the network,
then restart and use **Resume / verify** or `cloudnest resume JOB-UUID`.
The server's acknowledged offset is authoritative. Upload sessions live in
Keychain and expire on Google's schedule. Restarting an expired session uses
the same pre-generated Drive file ID. Originals remain unchanged.

Restore with the local JSON manifest from
`~/Library/Application Support/CloudNest/manifests/`, into a different empty
folder. Compare originals and restored copies with `shasum -a 256`. Repeat
with an already-existing destination filename and confirm that it is refused.
The original path in a manifest is informational only.

### Official Drive for desktop

Install the official Google Drive application if needed. In its own Preferences,
confirm **Google Drive →
My Drive syncing options → Stream files**. Keep this independent of CloudNest.
Do not archive from `~/Library/CloudStorage` and do not manipulate Drive caches.
Finder quick actions/pinning are a later milestone.

## Cloudflare: cloudnest-brain

Complete the Google round trip first. This deployment is a disposable feasibility
service, not yet a canonical personal memory vault.

```sh
npm ci
npx wrangler login --use-keyring --scopes account:read user:read workers_scripts:write d1:write
npx wrangler whoami
npx wrangler d1 create cloudnest-brain
```

Log in through the browser using your existing Cloudflare account. Choose the
Free plan. Put the returned **database_id** (an identifier, not a credential)
in ignored `brain/wrangler.local.jsonc`. The example configuration has an all-zero ID so it cannot accidentally
target the configured development database. Worker name is already configured.

```sh
npx wrangler d1 migrations apply cloudnest-brain --local --config brain/wrangler.local.jsonc
npx wrangler d1 execute cloudnest-brain --local --config brain/wrangler.local.jsonc --file brain/tests/disposable-memory.sql
node scripts/create-mcp-client.mjs /absolute/private/folder/cloudnest-auth
```

The generator creates a 256-bit test token and SHA-256 grant file outside the
repository with private filesystem permissions. It prints paths only. Never
commit either file. For local development, add `CLIENTS_JSON` as a JSON-encoded
string in ignored `brain/.dev.vars` (see `.dev.vars.example`), then use
`npm run dev:brain`. Leave the local binding on `127.0.0.1`.

For deployment, set the origin controls in the configuration
to your actual HTTPS Worker origin; do not include wildcard origins. Then:

```sh
npx wrangler secret put CLIENTS_JSON --config brain/wrangler.local.jsonc < /absolute/private/folder/cloudnest-auth/clients.json
npx wrangler d1 migrations apply cloudnest-brain --remote --config brain/wrangler.local.jsonc
npx wrangler d1 execute cloudnest-brain --remote --config brain/wrangler.local.jsonc --file brain/tests/disposable-memory.sql
npx wrangler deploy --config brain/wrangler.local.jsonc
```

The SQL file above contains one disposable approved test memory. Review it
before applying. Do not upload personal information or a conversation transcript.
Run the SDK probe:

```sh
node scripts/probe-mcp.mjs https://YOUR-WORKER.workers.dev/mcp /absolute/private/folder/cloudnest-auth/token.txt verification
```

Then configure **one real AI client that supports remote Streamable HTTP and
custom bearer headers** and ask it to find the disposable memory. A passing
SDK probe alone does not satisfy the external AI acceptance test. Clients that
require OAuth discovery need a later authorization flow; do not bypass their
requirements or claim universal support.

Remove the grant (or set `revoked: true`) and update the secret to revoke it.
The generator defaults to a 30-day expiry. There is no dashboard/token manager
yet. Keep development and real-client credentials separate. Monitor current
Workers/D1 free-tier quotas; no paid upgrade is authorized by these instructions.

## Completing the gate

Keep raw Drive IDs, account endpoints and detailed logs in private local working
files. Publish only redacted source/restore hashes, interruption outcomes and
verified client/version results in `docs/verification.md`.
Phase 1 starts only when the live feasibility workflows pass. The detailed
provider/account matrix must be researched when that integration is implemented.

## Approved local reclaim

Only after a disposable archive has been restored successfully, use the native
**Reclaim…** action. First move it to managed recovery; use **Put back** to
verify reversal. A second **Remove copy…** approval permanently removes exactly
that verified recovery payload. Nothing in Trash is emptied. Open files, changed
content, missing checksums, changed manifests or failed file-use checks block
removal. A crash during cleanup is reconciled without automatic deletion.

The CLI exposes the same two distinct approval flags shown in README. Apply
those only to a reviewed job ID. Restoring later consumes space again; the
historical observed removal delta is not a promise about current free space.
