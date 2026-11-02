# Browser Context Companion

CloudNest's Manifest V3 popup runs only when opened. It has no background worker,
permanent content script, polling, model API or provider-specific auto-send code.
Chrome and Edge are the intended browsers. Store publication and real-browser
acceptance are release gates; automated tests are not evidence of a loaded
consumer extension.

## Load and pair

1. In Chrome's `chrome://extensions` or Edge's `edge://extensions`, enable
   Developer mode and choose **Load unpacked**, selecting `browser/extension`.
   No build or package download is needed.
2. Open the extension popup. Copy the displayed `chrome-extension://<id>` origin.
   For a self-hosted Brain, its owner must allow that **exact** origin in the
   Worker's `ALLOWED_ORIGINS` configuration when required by its Origin checks.
   Preserve existing necessary exact entries; do not add a wildcard or all
   extension origins. Deployment configuration changes remain owner operations.
3. In the authenticated Brain Console's Connections screen, create a dedicated,
   expiring client for only the project(s) this browser should read. Enable
   **proposals to the review Inbox** only if selected-text saving is wanted.
   Copy its one-time scoped credential. Never use the Brain owner credential.
4. Enter the Brain HTTPS origin, one authorized project ID and scoped credential
   in the popup. Click **Connect this session**, grant access to that exact host,
   and wait for the MCP tool check. Connection does not submit a memory.

The popup accepts an HTTPS origin without paths, query strings, credentials,
fragments or custom ports. It verifies the MCP initialize/tools-list responses
before keeping the credential. Owner credentials are not valid MCP clients and
therefore cannot complete this connection check.

## Daily actions

- **Search Brain** retrieves approved memories for the paired project.
- **Project notes** fetches its bounded project context through MCP.
- Select relevant results and build an editable context pack. Sources and memory
  references remain visible. Retrieved text is marked untrusted reference data.
- **Copy context** is the reliable fallback for AI providers without suitable
  integrations. If clipboard permission is unavailable, the text is selected so
  the user can use their normal copy shortcut.
- **Insert into focused field** inserts only into the already focused writable
  textarea or supported contenteditable editor. It never clicks Send, submits a
  form, finds a different editor, or synthesizes Enter. Restricted pages, frames,
  unsupported editors and websites that ignore synthetic input use manual copy.
  Inspect the site's draft before sending it yourself.
- **Continue in Another AI** creates a local editable handoff from your objective,
  progress, problems, file references, next action and selected approved context.
- **Capture selected text** reads only the exact selection after your click.
  Password inputs are refused. Only the page origin is suggested as provenance;
  private URL paths, queries and fragments are not collected. Review the title,
  text and source and tick the consent box before submitting to the Inbox.
  Proposals never become approved memories automatically. Timeouts are uncertain
  writes: inspect the Inbox before trying again, since this UI never auto-retries.

## Permissions and data

Required permissions are `activeTab`, `scripting` and `storage`. The manifest's
optional `https://*/*` declaration permits asking about a user-supplied Brain
host; it grants no host access by itself. Connection requests just the configured
host. Chrome host permissions cannot restrict individual paths, so this grant
covers that host's paths; extension code sends requests only to `/mcp`.

The scoped token is held in `chrome.storage.session` with `TRUSTED_CONTEXTS`
access, not local/sync storage, localStorage, page scripts, logs or URLs. Session
state lasts at most eight hours and is cleared by browser restart or extension
reload/update/disable. No chat history, search results or handoff drafts are
persisted. Closing the popup discards its in-memory drafts and can interrupt an
in-flight request. The network request has a 20-second timeout and bounded reply;
redirects and cookies are refused.

**Disconnect** clears the session/drafts and removes granted host access. When
opened without a valid saved session, the popup also clears stale host grants.
To revoke the bearer credential itself, revoke that dedicated client in Brain
Connections. Revocation and project authorization are enforced by the server.
The extension is single-user and supplies no managed multi-user hosting.

## Verification

```sh
node --test browser/extension/tests/*.test.mjs
node --check browser/extension/popup.mjs
```

Tests cover permission declarations, session bounds, MCP headers and production
response shapes, malformed/oversized responses, scoped tool restrictions,
provenance, handoffs, selection-only capture and insertion without submission.
Actual Chrome/Edge loading, host prompts, live MCP reads/proposals, clipboard
behavior and each provider's editor remain separate acceptance checks.

Official implementation references:
[Chrome permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions),
[session storage](https://developer.chrome.com/docs/extensions/reference/api/storage),
[extension network requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests).
