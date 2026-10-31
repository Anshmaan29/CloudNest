# CloudNest MCP OAuth

This is a public-client OAuth authorization-code profile with mandatory PKCE S256,
opaque tokens and explicit owner consent. It adds no runtime SDK or paid model API.
The official MCP SDK is used only in development tests. A real local Workers/D1
test completes discovery, dynamic registration, owner approval, code exchange,
authorized MCP retrieval and automatic refresh. Hosted assistant accounts and a
deployed production endpoint still require separate acceptance checks; this is
not a claim that every AI provider supports this configuration.

## Configuration and deployment

Apply all migrations through 0005, in order. Set PUBLIC_ORIGIN to the exact HTTPS
origin of this Worker, without a trailing slash or path. HTTP is accepted only
for an explicitly configured localhost, 127.0.0.1 or IPv6 loopback origin.
Configure ALLOWED_ORIGINS with the console origin and any explicitly permitted
browser origins. OWNER_TOKEN_SHA256 must contain the SHA-256 digest of an
independent, random owner bearer. Keep the raw owner credential in Keychain or a
private password manager. Never give it to an AI client or include it in a URL.

OAuth uses random 256-bit opaque tokens; only SHA-256 digests are stored in D1.
It needs no OAuth signing key. Canonical Brain approval receipts separately need
VAULT_SIGNING_KEY. The server-side Google connection remains a separate explicit
owner authorization: never copy a Mac Keychain Google refresh token into a Worker.
OAuth can be checked against disposable feasibility data before Google is
configured and does not enable personal-data/canonical mode automatically.

Keep credentials, production D1 IDs and account-specific configuration outside
Git. These implementation files do not deploy anything or change an account.

## Discovery and public endpoints

- GET /.well-known/oauth-protected-resource/mcp, with a root well-known fallback,
  advertises exactly PUBLIC_ORIGIN + /mcp as the resource and this origin as the
  authorization server. Missing credentials at /mcp produce a matching
  WWW-Authenticate resource_metadata challenge with memory:read scope.
- GET /.well-known/oauth-authorization-server advertises /oauth/authorize,
  /oauth/token, /oauth/register, /oauth/revoke, public-client authentication none,
  code responses, authorization_code and refresh_token grants, and S256 only.
  Client-ID metadata document fetching is deliberately unsupported and advertised
  as false. No issuer, callback or audience is inferred from a hostile Host.
- POST /oauth/register accepts JSON up to 8 KiB. Required redirect_uris contains
  one to eight HTTPS or loopback HTTP URIs; optional client_name is bounded
  to 200 characters. Userinfo, fragments, whitespace, backslashes and wildcards
  are rejected. Optional token_endpoint_auth_method must be none. Metadata and
  logos are never fetched. The 201 response returns client_id, issued-at time,
  accepted metadata and supported scopes, without a client secret. Registration
  provides no memory access and does not verify the supplied display name.
- GET /oauth/authorize requires response_type=code, a registered client_id and
  matching registered redirect_uri, resource=PUBLIC_ORIGIN+/mcp, code_challenge and
  code_challenge_method=S256. Scope defaults to memory:read; memory:propose can be
  requested additionally. A bounded optional state is echoed in the callback.
  A valid request stores a five-minute pending consent and redirects only to
  PUBLIC_ORIGIN + /#authorize=REQUEST_UUID. It never automatically approves.
- POST /oauth/token accepts URL-encoded forms up to 16 KiB. Code exchange requires
  grant_type=authorization_code, client_id, code, redirect_uri, code_verifier and
  the exact resource. Refresh requires grant_type=refresh_token, client_id,
  refresh_token and the exact resource. Duplicate form fields, missing S256
  proof, wrong bindings, expiry and reuse are rejected. Optional refresh scope
  may narrow the original scope and cannot restore a removed permission.
- POST /oauth/revoke accepts client_id and token in a URL-encoded body. It revokes
  the matching grant; unknown credentials also return 200 without disclosure.

Token success returns access_token, token_type=Bearer, expires_in (at most 300
seconds), refresh_token and scope. Access is valid only at this Worker's /mcp.
No token is accepted in a query string. Refresh credentials rotate on every use.
Replay, including concurrent exchange of one code or refresh credential, revokes
the entire grant, including descendant access tokens. A lost token response must
be recovered through a new owner-approved authorization rather than replaying
the old credential. Revocation remains durable even if the normal audit sink
fails; its reason is also retained on the grant.

Errors at public endpoints use OAuth error codes in {error:string}. Invalid
client/redirect requests never redirect. Errors after a validated callback URI
can return a standard callback error with state and iss. Ordinary owner API
errors use the existing {error:string} envelope and HTTP status codes.

## Owner console contracts

All of these routes use the existing owner Authorization bearer, strict origin
checks, no-store responses and owner rate limits. AI access/refresh credentials
cannot authenticate them. No cookies or ambient owner session grant consent.

GET /api/v1/oauth/requests/:id returns:

```json
{"request":{"id":"UUID","clientId":"UUID","clientName":"unverified text","redirectUri":"https://client.example/callback","resource":"https://brain.example/mcp","scopes":["memory:read"],"createdAt":"ISO timestamp","expiresAt":"ISO timestamp","status":"pending"}}
```

Show the unverified display name, exact callback URI, resource, requested scopes
and expiry. The owner must choose one to 32 explicit project names. Never derive
permissions from client names, memory contents or instructions inside documents.

POST /api/v1/oauth/requests/:id/approve accepts:

```json
{"projects":["my-project"],"permissions":[]}
```

Optional permissions:["propose"] is accepted only when memory:propose was
requested and the owner explicitly opted in. Omission means read-only. A 200
response is {redirectUrl:string,grantId:string}. Navigate to redirectUrl after
that explicit action. It contains only the standard one-time code, optional
state and issuer. Concurrent approval creates exactly one grant. Expired or
handled requests return 409. Approval replaces older grants for the same public
client and resource, rather than accumulating old project permissions.

POST /api/v1/oauth/requests/:id/deny with {} returns 200 {redirectUrl:string}
containing error=access_denied, optional state and iss. No code is created.

GET /api/v1/oauth/grants returns {grants:[...]}, at most 200 recent records with
active grants first. Each contains id, clientId, clientName, projects,
permissions, expiresAt, revoked, revocationReason, lastSeen, status, managed:true
and oauth:true. lastSeen reflects actual memory-retrieval audit activity, not
an invented online status. POST /api/v1/oauth/grants/:id/revoke with {} returns
200 {revoked:true}. Configured canonical mode also includes these grants in
GET /api/v1/clients, so real AI access can appear in Orbit. The oauth- identity
prefix is reserved from ordinary managed client creation.

## Bounds, retention and browser behavior

Consent and codes expire after five minutes. Access tokens last at most five
minutes; grants and rotating refresh credentials expire 30 days after consent.
A grant allows at most 10,000 successful token issuances, with a durable O(1)
counter, then requires renewed consent. A normal five-minute refresh cycle uses
about 8,640 issuances over 30 days. There are at most 100 active grants, 200 retained
registrations and 200 unexpired pending requests.

Public routes have 300 requests/minute globally, 10 registrations/minute per IP
digest and 60 other OAuth requests/minute per IP digest. Rate rows age out.
Authentication, rate bookkeeping and atomic writes consume actual D1 queries;
Cloudflare free-tier quotas still apply. These application limits do not claim
denial-of-service immunity or unlimited free hosting.

Registration, authorization and successful token exchanges run bounded cleanup:
at most 256 expired access rows, 256 refresh rows, 64 old requests, 16 terminal
grants and 16 unreferenced clients per call. Used refresh hashes and code replay
evidence remain through the original grant expiry plus seven days, including
revoked grants. Unapproved requests become eligible after a day; unreferenced
registrations become eligible after a day without authorization activity.
Expired children are removed before grants and client metadata. Existing audit
IDs remain. There is no background polling and no permanently running Mac.

Protected-resource CORS uses an exact operator allowlist or the actual callback
origin approved in this grant's consent request, never the registration's full
list of possible origins. Another approved
client's token cannot borrow that Origin. An approved Origin can read a 401
challenge for expired credentials. Preflights expose no memory data. Public
token errors also preserve permitted actual-consent-origin CORS. Token exchange,
refresh and revocation additionally check the specific grant's Origin. There are no
wildcard origins or credential cookies. First-time browser-only dynamic
registration/discovery from an unknown Origin is intentionally unavailable;
use a server/desktop MCP client or explicit operator preregistration/allowlist.

The public console shell serves only GET/HEAD /, /console.js, /console.css and
safe JS/CSS chunk paths. It has a self-only script/style/connect CSP, no frames,
no-referrer and no-store headers. APIs remain authenticated independently of
the shell. Three.js/graph loading is owned by the console build.

## Verification and standards

Run npm run typecheck and npm run test:brain. OAuth tests use real local D1;
all external fetches are forbidden, so no metadata URL or live Google service
can be accessed accidentally. Tests cover official SDK interoperability,
private/project isolation, owner consent races, PKCE and audience bindings,
expiry, code reuse, refresh replay and concurrent rotation, read-only defaults,
Inbox-only proposal opt-in, scope narrowing, Origin/CORS restrictions, revocation,
audit failures, input/rate bounds and retention cleanup.

The SDK loopback test also uses a real local HTTP callback listener. It registers
a portless http://127.0.0.1/callback, authorizes an actual ephemeral listener port,
receives the one-time callback, exchanges it, retrieves an approved memory and
automatically rotates credentials after access expiry. This is local protocol
verification, not a live Codex or consumer-provider account acceptance claim.

RFC8252 permits a port exception only for literal HTTP loopback IPs 127.0.0.1 and
[::1]. CloudNest changes no other component: host, scheme and raw path/query
must match; fragments, userinfo and wildcards remain forbidden. HTTPS and
localhost callbacks remain exact. The actual requested callback is displayed to
the owner and persisted in consent. Code exchange must match that actual URI
exactly, including its actual port, rather than reusing the portless registration.
Migration 0005 adds a unique consent/grant lookup index; existing approved
requests already hold the binding and remain intact.

Primary references consulted before implementation:

- [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [RFC 7636: PKCE](https://www.rfc-editor.org/rfc/rfc7636)
- [RFC 7591: dynamic client registration](https://www.rfc-editor.org/rfc/rfc7591)
- [RFC 8707: resource indicators](https://www.rfc-editor.org/rfc/rfc8707)
- [RFC 9728: protected resource metadata](https://www.rfc-editor.org/rfc/rfc9728)
- [RFC 7009: token revocation](https://www.rfc-editor.org/rfc/rfc7009)
- [RFC 8252: native-app loopback callbacks](https://www.rfc-editor.org/rfc/rfc8252)
- [OAuth security best current practice](https://www.rfc-editor.org/rfc/rfc9700)
