# Single-owner browser passkeys

The Brain console offers passkey sign-in for its one owner. The existing recovery Bearer credential, Mac Keychain connection and CLI remain available. A browser session never grants MCP access; AI clients still need their separate scoped Bearer grants.

Verification uses pinned `@simplewebauthn/server` 14.0.3 and the bundled `@simplewebauthn/browser` 14.0.0 client. Registration requests discoverable ES256 credentials, device user verification and no identifying attestation. The verifier requires user verification and exact configured origin/RP ID. These options follow the maintained [SimpleWebAuthn server API](https://simplewebauthn.dev/docs/packages/server), [browser API](https://simplewebauthn.dev/docs/packages/browser), and [WebAuthn origin/UV requirements](https://www.w3.org/TR/webauthn-3/). Cryptographic verification executes through the [Workers Web Crypto runtime](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/); this app does not implement its own CBOR or signature verifier.

## Integration contract

Apply migration `0008_browser_auth.sql`. No new environment secret, paid service or Google OAuth client is needed. Existing `DB`, `OWNER_TOKEN_SHA256` and exact HTTPS `PUBLIC_ORIGIN` are required. RP ID is the configured origin's hostname, without expanding trust to sibling origins.

In the REST router, after existing host/protocol boundaries and before its owner gate:

```ts
const browserAuth = await handleBrowserAuth(request, env, path);
if (browserAuth) return browserAuth;
await authorizeOwner(request, env);
```

Remove the old duplicate Bearer-only owner check; preserve owner rate limits and all downstream authorization. Never call `authorizeOwner` from `/mcp`. An explicit invalid Authorization header fails closed rather than falling back to a browser cookie.

| Endpoint under `/api/v1` | Method | Purpose |
| --- | --- | --- |
| `/auth/session` | GET | Restore current session or bootstrap anonymous CSRF; returns `authenticated`, `csrf`, passkey count and session expiry when signed in. |
| `/auth/register/options` | POST | Current owner recovery Bearer plus browser CSRF; accepts optional `label` up to 80 characters. Returns `{options}`. |
| `/auth/register/verify` | POST | Same owner Bearer plus browser CSRF; consumes challenge and verifies the WebAuthn registration response, then issues a browser session. |
| `/auth/login/options` | POST | Browser CSRF and `{}`; returns discoverable, UV-required `{options}`. |
| `/auth/login/verify` | POST | Browser CSRF and WebAuthn assertion; consumes its challenge and issues a fresh browser session. |
| `/auth/logout` | POST | Authorized owner/session, browser CSRF and `{}`; revokes the current browser session and clears cookies. |
| `/auth/revoke-sessions` | POST | Authorized owner/session, browser CSRF and `{}`; revokes every current-epoch browser session and clears this browser's cookies. |

Every browser mutation requires exact Origin and `X-CloudNest-CSRF`; cross-site and sibling-site fetch metadata is rejected. The anonymous CSRF bootstrap is not an authenticated session. CSRF values are derived from high-entropy HttpOnly cookies and returned only in same-origin, uncached JSON. They live in tab memory. Recovery Bearers are used only for explicit advanced access/enrollment, never put in a URL, browser storage or logs.

## Lifetime and revocation

The opaque `__Host-cloudnest_session` cookie is HttpOnly, Secure, SameSite=Strict, has Path=/ and no Domain. D1 stores only its SHA-256 plus a separate internal session ID. Server authorization enforces a 30-minute sliding idle deadline and 12-hour absolute deadline; the console clears visible data when its lifetime hint expires. Refreshing an unexpired page restores its HttpOnly session without pasting a recovery credential.

WebAuthn challenges last five minutes and are bound to the initiating browser's cookie context. A conditional D1 `DELETE ... RETURNING` consumes each challenge once before verification, including failed verification attempts. A replay, expired request or wrong browser cannot issue a session. Signature counters are verified and updated conditionally. Synced passkeys with zero counters remain supported by the library.

Each passkey, owner handle, challenge and session belongs to the current owner-verifier epoch (`OWNER_TOKEN_SHA256`). Rotating that verifier immediately makes all previous browser sessions and passkey enrollments unusable, including an enrollment made with a compromised old owner credential. A new owner-authorized enrollment is then required. Canonical memory, archives and MCP grants are not modified by browser authentication.

Sign-out revokes server session rows. If offline sign-out cannot be confirmed, the console clears this tab and says so; the user must reconnect and sign out before relying on a shared browser being disconnected. Passkeys remain enrolled after ordinary session revocation. Account deletion, passkey recovery codes, owner account recovery and passkey inventory/deletion UI are separate requested work, not completed by this change.

## Device enrollment gate and validation

No passkey is enrolled automatically. After review/deployment, the user must open the configured HTTPS origin, select **Set up passkey**, provide current owner recovery authorization once, and deliberately complete Touch ID, device PIN or security-key verification. Agents must not claim device enrollment from generated test fixtures.

Before accepting real-device completion, verify enrollment, page reload without re-pasting, sign-out followed by passkey sign-in, two-browser global session revocation, and the advanced owner fallback. A browser cookie alone must receive 401 from `/mcp`. The root deployment should also verify the integrated router's original REST behavior and its existing CSP.

Automated tests construct actual ES256 WebAuthn-format registration and assertion bytes and run the production verifier in Miniflare. They cover owner enrollment authority, UV, exact origin/RP, signature forgery, challenge replay/concurrency/expiry/browser binding, cookie CSRF, owner rotation, session deadlines/revocation, audit failure, and MCP isolation. Client tests cover cookie fetch boundaries, late-response cancellation, immediate local sign-out and response-size limits. These checks do not substitute for the user's real authenticator gesture.
