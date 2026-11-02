import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
  type RegistrationResponseJSON,
  type AuthenticationResponseJSON,
} from "@simplewebauthn/server";
import { decodeClientDataJSON } from "@simplewebauthn/server/helpers";
import { BrainError, boundedJSON, sha256, text } from "../memory/record";
export interface BrowserAuthEnv {
  DB: D1Database;
  OWNER_TOKEN_SHA256?: string;
  PUBLIC_ORIGIN?: string;
}
interface Session {
  id: string;
  token_sha256: string;
  epoch: string;
  credential_id: string;
  created_at: number;
  idle_until: number;
  absolute_until: number;
}
interface Challenge {
  epoch: string;
  kind: string;
  challenge: string;
  binding_sha256: string;
  expires_at: number;
  label: string | null;
}
interface Passkey {
  id: string;
  epoch: string;
  public_key: string;
  counter: number;
  transports: string;
  revoked: number;
}
const SESSION = "__Host-cloudnest_session",
  PREAUTH = "__Host-cloudnest_csrf",
  CEREMONY = "__Host-cloudnest_challenge";
const IDLE = 30 * 60_000,
  ABSOLUTE = 12 * 60 * 60_000,
  CHALLENGE = 5 * 60_000;
const random = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
const base64 = (value: Uint8Array) =>
  btoa(String.fromCharCode(...value))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
const bytes = (value: string) =>
  Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (c) =>
    c.charCodeAt(0),
  );
const equal = (a: string, b: string) => {
  let d = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++)
    d |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return d === 0;
};
const epoch = (env: BrowserAuthEnv) => {
  if (!/^[a-f0-9]{64}$/.test(env.OWNER_TOKEN_SHA256 ?? ""))
    throw new BrainError(503, "Owner authentication is unavailable");
  return env.OWNER_TOKEN_SHA256!;
};
function cookie(request: Request, name: string): string | null {
  const values = (request.headers.get("Cookie") ?? "")
    .split(";")
    .map((p) => p.trim())
    .filter((p) => p.startsWith(name + "="));
  if (values.length > 1) throw new BrainError(401, "Ambiguous browser session");
  const value = values[0]?.slice(name.length + 1);
  return value && /^[a-f0-9]{64}$/.test(value) ? value : null;
}
const cookieHeader = (name: string, value: string, seconds: number) =>
  `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${seconds}`;
function site(
  request: Request,
  env: BrowserAuthEnv,
  mutation = false,
): { origin: string; rpID: string } {
  let expected: URL;
  try {
    expected = new URL(env.PUBLIC_ORIGIN ?? "");
  } catch {
    throw new BrainError(
      503,
      "Passkeys require the configured HTTPS Brain origin",
    );
  }
  if (
    expected.protocol !== "https:" ||
    expected.origin !== env.PUBLIC_ORIGIN ||
    expected.username ||
    expected.password ||
    new URL(request.url).origin !== expected.origin
  )
    throw new BrainError(403, "Browser authentication origin rejected");
  const origin = request.headers.get("Origin"),
    fetchSite = request.headers.get("Sec-Fetch-Site");
  if (
    (origin && origin !== expected.origin) ||
    (mutation && origin !== expected.origin) ||
    (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none")
  )
    throw new BrainError(403, "Browser authentication origin rejected");
  return { origin: expected.origin, rpID: expected.hostname };
}
async function bearer(request: Request, env: BrowserAuthEnv): Promise<void> {
  const value = request.headers.get("Authorization");
  if (
    !value?.startsWith("Bearer ") ||
    value.length < 40 ||
    value.length > 1024 ||
    !equal(await sha256(value.slice(7)), epoch(env))
  )
    throw new BrainError(401, "Owner recovery authorization required");
}
async function session(
  request: Request,
  env: BrowserAuthEnv,
  touch = false,
): Promise<{ row: Session; token: string } | null> {
  const token = cookie(request, SESSION);
  if (!token) return null;
  const now = Date.now(),
    digest = await sha256(token);
  const row = await env.DB.prepare(
    "SELECT s.* FROM brain_browser_sessions s JOIN brain_browser_passkeys p ON p.id=s.credential_id AND p.epoch=s.epoch AND p.revoked=0 WHERE s.token_sha256=? AND s.epoch=? AND s.idle_until>? AND s.absolute_until>?",
  )
    .bind(digest, epoch(env), now, now)
    .first<Session>();
  if (!row) return null;
  if (touch) {
    const update = await env.DB.prepare(
      "UPDATE brain_browser_sessions SET idle_until=min(absolute_until,?) WHERE token_sha256=? AND epoch=? AND idle_until>? AND absolute_until>?",
    )
      .bind(now + IDLE, digest, epoch(env), now, now)
      .run();
    if (update.meta.changes !== 1) return null;
    row.idle_until = Math.min(row.absolute_until, now + IDLE);
  }
  return { row, token };
}
const csrf = (token: string) => sha256("CloudNest browser CSRF v1\n" + token);
async function mutationContext(
  request: Request,
  env: BrowserAuthEnv,
): Promise<string> {
  site(request, env, true);
  const current = await session(request, env),
    token = current?.token ?? cookie(request, PREAUTH);
  if (
    !token ||
    !equal(request.headers.get("X-CloudNest-CSRF") ?? "", await csrf(token))
  )
    throw new BrainError(
      403,
      "Browser security token expired; reload before retrying",
    );
  return sha256(token);
}
/** REST only. Never call this from the scoped-Bearer MCP endpoint. */
export async function authorizeOwner(
  request: Request,
  env: BrowserAuthEnv,
): Promise<{ mode: "bearer" | "browser" }> {
  if (request.headers.has("Authorization")) {
    await bearer(request, env);
    return { mode: "bearer" };
  }
  if (!cookie(request, SESSION))
    throw new BrainError(401, "Owner authorization required");
  site(request, env, !["GET", "HEAD"].includes(request.method));
  const current = await session(request, env, true);
  if (!current)
    throw new BrainError(
      401,
      "Browser session expired; sign in with your passkey",
    );
  if (
    !["GET", "HEAD"].includes(request.method) &&
    !equal(
      request.headers.get("X-CloudNest-CSRF") ?? "",
      await csrf(current.token),
    )
  )
    throw new BrainError(403, "Browser security token rejected");
  return { mode: "browser" };
}
function requireTopLevel(response: {
  response?: { clientDataJSON?: string };
}): void {
  const encoded = response.response?.clientDataJSON;
  if (typeof encoded !== "string")
    throw new Error("Missing WebAuthn client data");
  const client = decodeClientDataJSON(encoded);
  if (client.crossOrigin || client.topOrigin)
    throw new Error("Cross-origin passkey ceremonies are unsupported");
}
function reply(value: unknown, cookies: string[] = []): Response {
  const headers = new Headers({
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(JSON.stringify(value), { headers });
}
async function limit(
  request: Request,
  env: BrowserAuthEnv,
  maximum: number,
): Promise<void> {
  const minute = Math.floor(Date.now() / 60000),
    identity =
      "browser-auth:" +
      (await sha256(request.headers.get("CF-Connecting-IP") ?? "local"));
  const count = await env.DB.prepare(
    "INSERT INTO brain_rate_limits(identity,minute,count) VALUES(?,?,1) ON CONFLICT(identity,minute) DO UPDATE SET count=count+1 RETURNING count",
  )
    .bind(identity, minute)
    .first<{ count: number }>();
  await env.DB.prepare("DELETE FROM brain_rate_limits WHERE minute<?")
    .bind(minute - 2)
    .run();
  if (!count || count.count > maximum)
    throw new BrainError(
      429,
      "Too many sign-in attempts; wait before retrying",
    );
}
async function ownerHandle(env: BrowserAuthEnv): Promise<string> {
  await env.DB.prepare(
    "INSERT OR IGNORE INTO brain_browser_owners(epoch,user_handle) VALUES(?,?)",
  )
    .bind(epoch(env), base64(crypto.getRandomValues(new Uint8Array(32))))
    .run();
  return (await env.DB.prepare(
    "SELECT user_handle FROM brain_browser_owners WHERE epoch=?",
  )
    .bind(epoch(env))
    .first<{ user_handle: string }>())!.user_handle;
}
async function createChallenge(
  env: BrowserAuthEnv,
  kind: string,
  challenge: string,
  binding: string,
  label: string | null,
): Promise<string> {
  await env.DB.prepare(
    "DELETE FROM brain_browser_challenges WHERE expires_at<?",
  )
    .bind(Date.now())
    .run();
  const token = random();
  const inserted = await env.DB.prepare(
    "INSERT INTO brain_browser_challenges(token_sha256,epoch,kind,challenge,binding_sha256,expires_at,label) SELECT ?,?,?,?,?,?,? WHERE (SELECT count(*) FROM brain_browser_challenges)<256",
  )
    .bind(
      await sha256(token),
      epoch(env),
      kind,
      challenge,
      binding,
      Date.now() + CHALLENGE,
      label,
    )
    .run();
  if (inserted.meta.changes !== 1)
    throw new BrainError(429, "Sign-in is busy; wait a few minutes");
  return token;
}
async function consume(
  request: Request,
  env: BrowserAuthEnv,
  kind: string,
  binding: string,
): Promise<Challenge> {
  const token = cookie(request, CEREMONY);
  if (!token) throw new BrainError(401, "Passkey request expired; start again");
  const row = await env.DB.prepare(
    "DELETE FROM brain_browser_challenges WHERE token_sha256=? AND epoch=? AND kind=? AND binding_sha256=? AND expires_at>? RETURNING *",
  )
    .bind(await sha256(token), epoch(env), kind, binding, Date.now())
    .first<Challenge>();
  if (!row)
    throw new BrainError(
      401,
      "Passkey request expired or was already used; start again",
    );
  return row;
}
async function newSession(
  env: BrowserAuthEnv,
  credential: string,
  nonce: string,
): Promise<Response> {
  const now = Date.now(),
    token = random(),
    id = crypto.randomUUID(),
    digest = await sha256(token);
  await env.DB.prepare(
    "DELETE FROM brain_browser_sessions WHERE absolute_until<=? OR idle_until<=?",
  )
    .bind(now, now)
    .run();
  const saved = await env.DB.prepare(
    "INSERT INTO brain_browser_sessions(id,token_sha256,epoch,credential_id,created_at,idle_until,absolute_until) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM brain_browser_passkeys WHERE id=? AND epoch=? AND revoked=0 AND auth_nonce=?) AND (SELECT count(*) FROM brain_browser_sessions WHERE epoch=?)<128",
  )
    .bind(
      id,
      digest,
      epoch(env),
      credential,
      now,
      now + IDLE,
      now + ABSOLUTE,
      credential,
      epoch(env),
      nonce,
      epoch(env),
    )
    .run();
  if (saved.meta.changes !== 1)
    throw new BrainError(
      409,
      "Passkey or browser session changed; sign in again",
    );
  return reply(
    {
      authenticated: true,
      csrf: await csrf(token),
      idleUntil: now + IDLE,
      absoluteUntil: now + ABSOLUTE,
    },
    [
      cookieHeader(SESSION, token, ABSOLUTE / 1000),
      cookieHeader(CEREMONY, "", 0),
      cookieHeader(PREAUTH, "", 0),
    ],
  );
}
/** Call before the REST owner gate, after host/protocol boundary checks. */
export async function handleBrowserAuth(
  request: Request,
  env: BrowserAuthEnv,
  path = new URL(request.url).pathname.slice("/api/v1".length),
): Promise<Response | null> {
  if (!path.startsWith("/auth/")) return null;
  const { origin, rpID } = site(request, env, request.method !== "GET");
  epoch(env);
  await limit(request, env, request.method === "GET" ? 180 : 40);
  if (path === "/auth/passkeys" && request.method === "GET") {
    await authorizeOwner(request, env);
    const current = await session(request, env);
    const keys = (await env.DB.prepare(
      "SELECT id,label,created_at AS createdAt,last_used_at AS lastUsedAt FROM brain_browser_passkeys WHERE epoch=? AND revoked=0 ORDER BY created_at,id LIMIT 10",
    ).bind(epoch(env)).all<{id:string;label:string;createdAt:number;lastUsedAt:number|null}>()).results;
    return reply({ passkeys: keys.map(key => ({...key,current:current?.row.credential_id===key.id})) });
  }
  if (path === "/auth/session" && request.method === "GET") {
    const current = await session(request, env, true);
    const count = await env.DB.prepare(
      "SELECT count(*) AS n FROM brain_browser_passkeys WHERE epoch=? AND revoked=0",
    )
      .bind(epoch(env))
      .first<{ n: number }>();
    if (current)
      return reply({
        authenticated: true,
        csrf: await csrf(current.token),
        idleUntil: current.row.idle_until,
        absoluteUntil: current.row.absolute_until,
        passkeys: count?.n ?? 0,
      });
    const token = cookie(request, PREAUTH) ?? random();
    return reply(
      {
        authenticated: false,
        csrf: await csrf(token),
        passkeys: count?.n ?? 0,
      },
      [
        cookieHeader(PREAUTH, token, CHALLENGE / 1000),
        cookieHeader(SESSION, "", 0),
      ],
    );
  }
  if (request.method !== "POST")
    throw new BrainError(404, "Browser authentication route not found");
  const binding = await mutationContext(request, env),
    input = await boundedJSON(request, 32768);
  if (path === "/auth/passkeys/revoke") {
    await authorizeOwner(request, env);
    if (Object.keys(input).some(key => !["id", "allowLastPasskeyRemoval"].includes(key)) ||
        typeof input.id !== "string" || !/^[A-Za-z0-9_-]{1,1400}$/.test(input.id) ||
        (input.allowLastPasskeyRemoval !== undefined && input.allowLastPasskeyRemoval !== true))
      throw new BrainError(400, "Invalid passkey revocation request");
    const recovery = input.allowLastPasskeyRemoval === true;
    if (recovery) await bearer(request, env);
    const current = await session(request, env);
    const result = await env.DB.batch([
      env.DB.prepare("UPDATE brain_browser_passkeys SET revoked=1,auth_nonce=NULL WHERE id=? AND epoch=? AND revoked=0 AND (?=1 OR (SELECT count(*) FROM brain_browser_passkeys WHERE epoch=? AND revoked=0)>1)")
        .bind(input.id, epoch(env), recovery ? 1 : 0, epoch(env)),
      env.DB.prepare("DELETE FROM brain_browser_sessions WHERE credential_id=? AND epoch=? AND EXISTS(SELECT 1 FROM brain_browser_passkeys WHERE id=? AND epoch=? AND revoked=1)")
        .bind(input.id, epoch(env), input.id, epoch(env)),
      env.DB.prepare("INSERT INTO audit(client_id,action) VALUES('owner','browser_passkey_revocation_requested')"),
    ]);
    if (result[0].meta.changes !== 1)
      throw new BrainError(409, "Passkey changed or is the last sign-in method. Removing the last passkey requires the current owner recovery credential and explicit confirmation.");
    const signedOut = current?.row.credential_id === input.id;
    return reply({revoked:true,signedOut}, signedOut ? [cookieHeader(SESSION,"",0),cookieHeader(PREAUTH,"",0),cookieHeader(CEREMONY,"",0)] : []);
  }
  if (path === "/auth/register/options") {
    if (Object.keys(input).some((k) => k !== "label"))
      throw new BrainError(400, "Invalid passkey enrollment field");
    await bearer(request, env);
    const label =
        input.label === undefined
          ? "My passkey"
          : text(input.label, "passkey name", 80),
      keys = (
        await env.DB.prepare(
          "SELECT id FROM brain_browser_passkeys WHERE epoch=? AND revoked=0 LIMIT 11",
        )
          .bind(epoch(env))
          .all<{ id: string }>()
      ).results;
    if (keys.length >= 10)
      throw new BrainError(409, "Passkey enrollment limit reached");
    const options = await generateRegistrationOptions({
      rpName: "CloudNest Brain",
      rpID,
      userName: "CloudNest owner",
      userID: bytes(await ownerHandle(env)),
      attestationType: "none",
      timeout: 60000,
      supportedAlgorithmIDs: [-7],
      excludeCredentials: keys.map((k) => ({ id: k.id })),
      authenticatorSelection: {
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required",
      },
      extensions: { credProps: true },
    });
    const token = await createChallenge(
      env,
      "register",
      options.challenge,
      binding,
      label,
    );
    return reply({ options }, [
      cookieHeader(CEREMONY, token, CHALLENGE / 1000),
    ]);
  }
  if (path === "/auth/register/verify") {
    await bearer(request, env);
    const challenge = await consume(request, env, "register", binding);
    let result;
    try {
      requireTopLevel(input as unknown as RegistrationResponseJSON);
      result = await verifyRegistrationResponse({
        response: input as unknown as RegistrationResponseJSON,
        expectedChallenge: challenge.challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
        requireUserPresence: true,
        requireUserVerification: true,
        supportedAlgorithmIDs: [-7],
      });
    } catch {
      throw new BrainError(
        401,
        "Passkey enrollment could not be verified; start again",
      );
    }
    if (!result.verified || !result.registrationInfo.userVerified)
      throw new BrainError(401, "Passkey user verification is required");
    const info = result.registrationInfo,
      nonce = random();
    try {
      await env.DB.batch([
        env.DB.prepare(
          "INSERT INTO brain_browser_passkeys(id,epoch,public_key,counter,label,transports,created_at,last_used_at,auth_nonce) VALUES(?,?,?,?,?,?,?,?,?)",
        ).bind(
          info.credential.id,
          epoch(env),
          base64(info.credential.publicKey),
          info.credential.counter,
          challenge.label,
          JSON.stringify(info.credential.transports ?? []),
          Date.now(),
          Date.now(),
          nonce,
        ),
        env.DB.prepare(
          "INSERT INTO audit(client_id,action) VALUES('owner','browser_passkey_enrolled')",
        ),
      ]);
    } catch {
      throw new BrainError(
        409,
        "Passkey already enrolled or enrollment could not be saved",
      );
    }
    return newSession(env, info.credential.id, nonce);
  }
  if (path === "/auth/login/options") {
    if (Object.keys(input).length)
      throw new BrainError(400, "Passkey sign-in takes an empty object");
    const options = await generateAuthenticationOptions({
      rpID,
      userVerification: "required",
      timeout: 60000,
    });
    const token = await createChallenge(
      env,
      "login",
      options.challenge,
      binding,
      null,
    );
    return reply({ options }, [
      cookieHeader(CEREMONY, token, CHALLENGE / 1000),
    ]);
  }
  if (path === "/auth/login/verify") {
    const challenge = await consume(request, env, "login", binding),
      response = input as unknown as AuthenticationResponseJSON;
    if (typeof response.id !== "string" || response.id.length > 1400)
      throw new BrainError(401, "Passkey sign-in could not be verified");
    const credential = await env.DB.prepare(
      "SELECT * FROM brain_browser_passkeys WHERE id=? AND epoch=? AND revoked=0",
    )
      .bind(response.id, epoch(env))
      .first<Passkey>();
    const handle = await env.DB.prepare(
      "SELECT user_handle FROM brain_browser_owners WHERE epoch=?",
    )
      .bind(epoch(env))
      .first<{ user_handle: string }>();
    if (
      !credential ||
      !handle ||
      response.response?.userHandle !== handle.user_handle
    )
      throw new BrainError(401, "Passkey sign-in could not be verified");
    let result;
    try {
      requireTopLevel(response);
      result = await verifyAuthenticationResponse({
        response,
        expectedChallenge: challenge.challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
        requireUserVerification: true,
        credential: {
          id: credential.id,
          publicKey: bytes(credential.public_key),
          counter: credential.counter,
          transports: JSON.parse(credential.transports),
        },
      });
    } catch {
      throw new BrainError(
        401,
        "Passkey sign-in could not be verified; start again",
      );
    }
    if (!result.verified || !result.authenticationInfo.userVerified)
      throw new BrainError(401, "Passkey user verification is required");
    const nonce = random(),
      updated = await env.DB.batch([
        env.DB.prepare(
          "UPDATE brain_browser_passkeys SET counter=?,last_used_at=?,auth_nonce=? WHERE id=? AND epoch=? AND counter=? AND revoked=0",
        ).bind(
          result.authenticationInfo.newCounter,
          Date.now(),
          nonce,
          credential.id,
          epoch(env),
          credential.counter,
        ),
        env.DB.prepare(
          "INSERT INTO audit(client_id,action) VALUES('owner','browser_passkey_sign_in')",
        ),
      ]);
    if (updated[0].meta.changes !== 1)
      throw new BrainError(409, "Passkey changed during sign-in; start again");
    return newSession(env, credential.id, nonce);
  }
  if (path === "/auth/logout" || path === "/auth/revoke-sessions") {
    if (Object.keys(input).length)
      throw new BrainError(400, "Sign-out takes an empty object");
    await authorizeOwner(request, env);
    if (path === "/auth/revoke-sessions")
      await env.DB.prepare("DELETE FROM brain_browser_sessions WHERE epoch=?")
        .bind(epoch(env))
        .run();
    else {
      const token = cookie(request, SESSION);
      if (token)
        await env.DB.prepare(
          "DELETE FROM brain_browser_sessions WHERE token_sha256=? AND epoch=?",
        )
          .bind(await sha256(token), epoch(env))
          .run();
    }
    await env.DB.prepare(
      "INSERT INTO audit(client_id,action) VALUES('owner','browser_sessions_revoked')",
    ).run();
    return reply({ authenticated: false }, [
      cookieHeader(SESSION, "", 0),
      cookieHeader(PREAUTH, "", 0),
      cookieHeader(CEREMONY, "", 0),
    ]);
  }
  throw new BrainError(404, "Browser authentication route not found");
}
