# AI connections and portable context

Official documentation checked on 2026-10-31. Product menus, regional access and
workspace policies can change. CloudNest does not automatically connect every
assistant, synchronize arbitrary chats, or install a browser extension.

## What has actually been tested

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Earlier deployed feasibility proof: Codex CLI 0.165.0, an existing ChatGPT login, temporary project-scoped bearer grant; search/read confirmed in D1 audit | A real external coding client retrieved a disposable saved memory over authenticated HTTPS. The temporary grant was subsequently revoked. | Canonical Drive-backed production acceptance, Codex OAuth interoperability, or any consumer chat website connection. See [verification record](verification.md). |
| Current official MCP SDK tests against local Miniflare and real D1 | Discovery, dynamic client registration, PKCE consent, approved retrieval and automatic refresh work together, including a real local HTTP callback after portless loopback registration. | A deployed OAuth flow or provider account/UI acceptance. Drive is an explicit test transport; no live Google account is involved. See [OAuth tests](../brain/tests/oauth.test.mjs). |
| Installed CLI inspected read-only during this documentation pass | `codex --version` reports 0.165.0; relevant `mcp add` and `mcp login` flags exist. | No new server was registered, credential read, account signed in, configuration changed or billable model called. |

The newer canonical service still needs its own deployed-client acceptance test.
Consumer Claude, ChatGPT, Gemini, DeepSeek and Kimi account interfaces have not
been tested with CloudNest. A documented transport is not a completed integration.

## Provider matrix

Every row can use the manual context bridge described below. “Documented” means
the provider describes the capability, not that this account has it enabled.

| Product/surface | Documented connection path | Relevant access limits | CloudNest verification |
| --- | --- | --- | --- |
| Claude web/Desktop remote connectors | Custom remote MCP connector, OAuth or configured request headers. [Official guide](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp) | Guide lists Free, Pro, Max, Ultra, Team and Enterprise; Free has one custom connector. Organization roles control adding connectors. | Account/UI and OAuth/header flow unverified. |
| ChatGPT web | Custom MCP plugin with streaming HTTP and OAuth; DCR is a documented registration option. [Official guide](https://developers.openai.com/api/docs/guides/custom-mcp-server) | Workspace permissions and security restrictions apply. This guide does not infer a subscription entitlement where the cited page does not establish one. | Account/UI unverified; the Codex proof below is separate. |
| Codex CLI / IDE / app MCP configuration | Streamable HTTP, environment-sourced bearer credentials, or OAuth. [Official MCP docs](https://learn.chatgpt.com/docs/extend/mcp) | Provider account access, workspace policies and model quotas still apply. | Earlier CLI bearer feasibility proof passed; current canonical/OAuth deployment acceptance pending. |
| Gemini Apps web/mobile | Add a custom MCP app in the web interface; it can then be used on web/mobile. [Official Gemini Apps help](https://support.google.com/gemini/answer/17209137) | US, age18+, personal Google Account, English and Keep Activity enabled; work/school accounts excluded by the current guide. | Account/UI and OAuth unverified. |
| Gemini CLI | Remote streaming HTTP with OAuth discovery/DCR. [Official CLI docs](https://geminicli.com/docs/tools/mcp-server/) | CLI authentication/model access is separate from Gemini Apps eligibility; browser callback requirements apply. | Documented, not tested with CloudNest. |
| DeepSeek consumer chat | No arbitrary custom-MCP setup path established by the official materials reviewed. [API tool-calling docs](https://api-docs.deepseek.com/guides/tool_calls/) document a developer capability, not consumer-chat setup. | Consumer connector eligibility unknown. | Use manual context; no consumer connection claim. |
| Kimi consumer chat | No arbitrary custom-MCP setup path established for ordinary Kimi chat by the official materials reviewed. | Consumer connector eligibility unknown. | Use manual context; Kimi Code is a separate surface. |
| Kimi Code CLI / editor | HTTP MCP, scoped bearer environment variables and browser OAuth are documented. [Official Kimi Code MCP docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html) | Account/model entitlement and organization restrictions were not checked. | Documented, not tested with CloudNest. |

## Shared CloudNest connection contract

Use the deployed HTTPS `/mcp` endpoint of your own Worker. All URLs below are
reserved illustrative placeholders, not public CloudNest endpoints. Give each
client its own project-scoped grant; never provide the owner credential, Google
OAuth JSON, Google refresh token or vault signing key to an assistant.

Default tools are `memory_search`, `memory_read`, `memory_recent` and
`project_context`. They return approved, unexpired memories in granted projects.
Private memories remain excluded. Optional `memory_propose` requires explicit
owner consent and adds a review Inbox proposal; it does not approve, edit or
delete saved memories or archived files. Tool filtering in a client is useful
for usability; server-side authorization remains authoritative.

CloudNest currently advertises public-client OAuth with PKCE S256 and DCR; it
does not support Client ID Metadata Document fetching or confidential-client
secret authentication. Select automatic registration/DCR where offered. If an
account requires a different authentication profile, treat it as unverified and
use the manual bridge. Authentication details and revocation are in
[MCP OAuth](mcp-oauth.md); these are independent of the server's separate Google
Drive authorization.

## Codex: practical setup templates

These are instructions to review, not commands executed by this documentation
task. Use a new, distinct server name and preserve existing MCP entries.

For a scoped bearer grant, the CLI supports an environment variable reference:

```sh
codex mcp add cloudnest_bearer \
  --url https://brain.example.invalid/mcp \
  --bearer-token-env-var CLOUDNEST_CLIENT_TOKEN
```

Supply that environment variable privately through your own credential workflow.
Do not replace it with the owner credential or paste a token into a command,
repository, screenshot or chat. The corresponding configuration shape is:

```toml
[mcp_servers.cloudnest_bearer]
url = "https://brain.example.invalid/mcp"
bearer_token_env_var = "CLOUDNEST_CLIENT_TOKEN"
enabled_tools = ["memory_search", "memory_read", "memory_recent", "project_context"]
```

The installed 0.165.0 help confirms these flags; the
[official CLI reference](https://learn.chatgpt.com/docs/cli/reference) documents
HTTP server registration and environment-sourced bearer authentication.

For the separate OAuth path, configure a distinct entry with read-only scopes:

```toml
[mcp_servers.cloudnest_oauth]
url = "https://brain.example.invalid/mcp"
scopes = ["memory:read"]
enabled_tools = ["memory_search", "memory_read", "memory_recent", "project_context"]
```

Then initiate explicit DCR login:

```sh
codex mcp login cloudnest_oauth --oauth-client-registration dcr --scopes memory:read
```

Review the real client/callback, approve only the intended projects in the owner
console, and leave proposal permission off unless needed. Codex documents scope
selection, DCR and issuer-checked callbacks in its
[MCP configuration guide](https://learn.chatgpt.com/docs/extend/mcp).

Codex's documented portless loopback callback handling inserts an active listener
port. CloudNest now tests the RFC8252 literal-loopback-port rule through the SDK
and a real local callback listener. Codex OAuth still needs its own deployed
client acceptance check. Remote HTTPS redirect checks remain exact; the earlier
bearer proof is unaffected.

For an acceptance test, create a disposable approved fact and a separate private
fact. Ask the connected client to search and read the approved fact; inspect
CloudNest's real audit events, verify the private fact cannot be retrieved, then
revoke the temporary grant and verify retrieval fails. Record the actual client
version and authentication method. A successful server listing alone is not
memory-retrieval acceptance. No model invocation was made during this docs task.

## Claude and ChatGPT web

For Claude, add the remote URL through its custom connector settings. Choose
automatic registration for CloudNest's DCR profile, or a documented request-header
setup with a dedicated scoped bearer. Remote connectors originate from
Anthropic's infrastructure, so a loopback-only test server cannot satisfy this
path. Team/Enterprise administrators may need to add the connector before
members can connect. Follow the account's current menus in the
[official Claude guide](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp).

For ChatGPT web, current official documentation uses Plugins → add a custom MCP
server → configure OAuth → create/install the plugin, then select it with `@`.
Choose DCR when available. The document's OAuth static-client settings do not
mean “paste the CloudNest owner token.” Account access and workspace restrictions
must be checked in the actual interface; neither the Codex CLI proof nor the
OpenAI Responses API establishes consumer-web access. See
[OpenAI's custom MCP guide](https://developers.openai.com/api/docs/guides/custom-mcp-server).

## Gemini Apps and Gemini CLI

Eligible Gemini Apps accounts add a server under Connected Apps → Custom apps on
the web and complete the displayed sign-in. If the documented US/age/account/
language/activity requirements are not met, use the manual bridge or separately
evaluate Gemini CLI. Do not change account region, activity settings or workspace
policy automatically. [Google's consumer setup instructions](https://support.google.com/gemini/answer/17209137).

Gemini CLI distinguishes streaming HTTP `httpUrl` from legacy SSE `url`. A
generic OAuth/discovery candidate is:

```json
{
  "mcpServers": {
    "cloudnest": {
      "httpUrl": "https://brain.example.invalid/mcp",
      "trust": false,
      "includeTools": ["memory_search", "memory_read", "memory_recent", "project_context"]
    }
  }
}
```

The CLI documents `/mcp auth cloudnest` for OAuth. Its remote OAuth flow needs a
working browser and local callback. This template is documentation-derived and
has not been tested against CloudNest. [Official Gemini CLI configuration](https://geminicli.com/docs/tools/mcp-server/).

## DeepSeek and Kimi

DeepSeek's API tool calling requires application code to execute tools; it does
not itself demonstrate a custom-connector option in consumer chat.
[Official tool-calling guide](https://api-docs.deepseek.com/guides/tool_calls/).
DeepSeek also documents using its API as a model provider inside Codex while
preserving MCP configuration. That is a separate optional API/client integration,
requires a provider credential and can involve API billing. CloudNest does not
run its setup script or require this route.
[Official DeepSeek/Codex integration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/).

Kimi Code is distinct from ordinary Kimi chat. Its documented `mcp.json` candidate
can reference a scoped bearer environment variable:

```json
{
  "mcpServers": {
    "cloudnest": {
      "url": "https://brain.example.invalid/mcp",
      "bearerTokenEnvVar": "CLOUDNEST_CLIENT_TOKEN",
      "enabledTools": ["memory_search", "memory_read", "memory_recent", "project_context"]
    }
  }
}
```

The documented alternative is browser OAuth through `/mcp-config login cloudnest`.
Neither route has been tested with CloudNest. See the
[Kimi Code configuration reference](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html).

## Manual Context Bridge: all six assistant families

This works through ordinary copy/paste in Claude, ChatGPT, Gemini, DeepSeek, Kimi
and coding agents, without requiring a model API key or a paid API integration:

1. Unlock the authenticated Brain console and open Continue in Another AI.
2. Choose the project; enter the task/objective, progress, unresolved problems
   and next action. Generate the compact handoff from approved project memories.
3. Review and edit the text. Add relevant file references or decisions manually
   where needed; remove information you do not want to send to the destination.
4. Copy the handoff and paste it into the chosen assistant. The destination
   selection does not transmit anything automatically.
5. When the task changes, regenerate or edit the handoff. Review any proposed
   durable fact in CloudNest before saving it. Pasted text cannot grant new
   server permissions or silently modify the memory vault.

An editable handoff carries task/objective, relevant approved memories, project
context and decisions, progress, unresolved issues, references and the next
recommended action. `project_context` provides a compact read-only context pack
for configured clients. Manual copies are snapshots and are not revoked or
corrected retroactively inside another provider's chat history.

CloudNest adds no mandatory paid model API. Each assistant's own account limits,
data handling and any optional CLI/API charges still apply. A future multi-model
chat hub or browser side panel is separate work and is not required for this flow.
