import { test, before, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
} from "node:crypto";
import { encodeCBOR } from "@levischuck/tiny-cbor";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import wrangler from "wrangler";
const origin = "https://brain.example.test",
  rpID = "brain.example.test",
  owner = randomBytes(32).toString("hex"),
  rotatedOwner = randomBytes(32).toString("hex"),
  hash = (x) => createHash("sha256").update(x).digest(),
  hex = (x) => hash(x).toString("hex"),
  b64 = (x) => Buffer.from(x).toString("base64url");
let script, runtime, db;
before(async () => {
  script = (
    await build({
      stdin: {
        resolveDir: process.cwd(),
        contents: `import {handleBrowserAuth,authorizeOwner} from './brain/api/browser-auth.ts';import {BrainError} from './brain/memory/record.ts';import worker from './brain/worker/index.ts';export default {async fetch(request,env){try{if(new URL(request.url).pathname==='/mcp')return worker.fetch(request,env);if(request.headers.has('X-Test-Rotate'))env={...env,OWNER_TOKEN_SHA256:env.NEXT_OWNER_SHA256};const auth=await handleBrowserAuth(request,env);if(auth)return auth;const authorization=await authorizeOwner(request,env);return Response.json({ok:true,mode:authorization.mode});}catch(e){return Response.json({error:e instanceof BrainError?e.message:'Service unavailable'},{status:e instanceof BrainError?e.status:503});}}};`,
      },
      bundle: true,
      write: false,
      format: "esm",
      target: "es2022",
    })
  ).outputFiles[0].text;
});
beforeEach(async () => {
  runtime = new Miniflare(
    convertV4MiniflareOptions({
      modules: true,
      script,
      compatibilityDate: "2026-10-30",
      cf: false,
      d1Databases: { DB: "browser-auth" },
      bindings: {
        PUBLIC_ORIGIN: origin,
        OWNER_TOKEN_SHA256: hex(owner),
        NEXT_OWNER_SHA256: hex(rotatedOwner),
        CLIENTS_JSON: "[]",
        ALLOWED_ORIGINS: origin,
      },
    }),
  );
  db = await runtime.getD1Database("DB");
  for (const name of [
    "0001_feasibility.sql",
    "0002_canonical.sql",
    "0008_browser_auth.sql",
  ])
    await db.batch(
      wrangler
        .unstable_splitSqlQuery(
          await readFile("brain/migrations/" + name, "utf8"),
        )
        .map((sql) => db.prepare(sql)),
    );
});
afterEach(async () => runtime?.dispose());
class Browser {
  cookies = new Map();
  csrf = "";
  async call(
    path,
    body,
    headers = {},
    method = body === undefined ? "GET" : "POST",
  ) {
    const response = await runtime.dispatchFetch(origin + "/api/v1" + path, {
      method,
      headers: {
        Origin: origin,
        "Content-Type": "application/json",
        "Sec-Fetch-Site": "same-origin",
        Cookie: [...this.cookies].map(([k, v]) => k + "=" + v).join(";"),
        "X-CloudNest-CSRF": this.csrf,
        ...headers,
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    for (const raw of response.headers.getSetCookie()) {
      const [key, value] = raw.split(";")[0].split("=");
      if (!value || raw.includes("Max-Age=0")) this.cookies.delete(key);
      else this.cookies.set(key, value);
    }
    const value = await response.json();
    if (value.csrf) this.csrf = value.csrf;
    return { response, value };
  }
  async bootstrap() {
    const result = await this.call("/auth/session");
    assert.equal(result.response.status, 200);
    return result;
  }
  async registrationOptions() {
    await this.bootstrap();
    const r = await this.call(
      "/auth/register/options",
      { label: "Fixture passkey" },
      { Authorization: "Bearer " + owner },
    );
    assert.equal(r.response.status, 200, JSON.stringify(r.value));
    return r.value.options;
  }
}
function authenticator(
  options,
  { originValue = origin, rpValue = rpID, uv = true, crossOrigin = false } = {},
) {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
      namedCurve: "prime256v1",
    }),
    jwk = publicKey.export({ format: "jwk" }),
    id = randomBytes(32),
    cose = encodeCBOR(
      new Map([
        [1, 2],
        [3, -7],
        [-1, 1],
        [-2, new Uint8Array(Buffer.from(jwk.x, "base64url"))],
        [-3, new Uint8Array(Buffer.from(jwk.y, "base64url"))],
      ]),
    );
  const length = Buffer.alloc(2);
  length.writeUInt16BE(id.length);
  const counter = Buffer.alloc(4),
    authData = Buffer.concat([
      hash(rpValue),
      Buffer.from([0x41 | (uv ? 4 : 0)]),
      counter,
      Buffer.alloc(16),
      length,
      id,
      Buffer.from(cose),
    ]),
    clientData = Buffer.from(
      JSON.stringify({
        type: "webauthn.create",
        challenge: options.challenge,
        origin: originValue,
        crossOrigin,
      }),
    );
  const response = {
    id: b64(id),
    rawId: b64(id),
    type: "public-key",
    clientExtensionResults: { credProps: { rk: true } },
    authenticatorAttachment: "platform",
    response: {
      attestationObject: b64(
        encodeCBOR(
          new Map([
            ["fmt", "none"],
            ["attStmt", new Map()],
            ["authData", new Uint8Array(authData)],
          ]),
        ),
      ),
      clientDataJSON: b64(clientData),
      transports: ["internal"],
    },
  };
  return { response, privateKey, id: b64(id), userHandle: options.user.id };
}
function assertion(
  options,
  key,
  {
    originValue = origin,
    rpValue = rpID,
    uv = true,
    counter = 1,
    challenge = options.challenge,
    userHandle = key.userHandle,
    corrupt = false,
    crossOrigin = false,
  } = {},
) {
  const count = Buffer.alloc(4);
  count.writeUInt32BE(counter);
  const authData = Buffer.concat([
      hash(rpValue),
      Buffer.from([uv ? 5 : 1]),
      count,
    ]),
    clientData = Buffer.from(
      JSON.stringify({
        type: "webauthn.get",
        challenge,
        origin: originValue,
        crossOrigin,
      }),
    ),
    signature = sign(
      "sha256",
      Buffer.concat([authData, hash(clientData)]),
      key.privateKey,
    );
  if (corrupt) signature[signature.length - 1] ^= 1;
  return {
    id: key.id,
    rawId: key.id,
    type: "public-key",
    clientExtensionResults: {},
    authenticatorAttachment: "platform",
    response: {
      authenticatorData: b64(authData),
      clientDataJSON: b64(clientData),
      signature: b64(signature),
      userHandle,
    },
  };
}
async function enroll(browser = new Browser()) {
  const options = await browser.registrationOptions(),
    key = authenticator(options),
    result = await browser.call("/auth/register/verify", key.response, {
      Authorization: "Bearer " + owner,
    });
  assert.equal(result.response.status, 200, JSON.stringify(result.value));
  return { browser, key, result, options };
}
async function loginOptions(browser) {
  await browser.bootstrap();
  const r = await browser.call("/auth/login/options", {});
  assert.equal(r.response.status, 200);
  return r.value.options;
}

test("enrollment requires current owner Bearer, exact origin and CSRF; existing sessions cannot enroll alone", async () => {
  const b = new Browser();
  await b.bootstrap();
  assert.equal(
    (await b.call("/auth/register/options", {})).response.status,
    401,
  );
  assert.equal(
    (
      await b.call(
        "/auth/register/options",
        {},
        { Authorization: "Bearer " + randomBytes(32).toString("hex") },
      )
    ).response.status,
    401,
  );
  assert.equal(
    (
      await b.call(
        "/auth/register/options",
        {},
        {
          Authorization: "Bearer " + owner,
          Origin: "https://attacker.example.test",
        },
      )
    ).response.status,
    403,
  );
  assert.equal(
    (
      await b.call(
        "/auth/register/options",
        {},
        { Authorization: "Bearer " + owner, "X-CloudNest-CSRF": "wrong" },
      )
    ).response.status,
    403,
  );
  const enrolled = await enroll(b);
  assert.equal(enrolled.result.value.authenticated, true);
  assert.equal(
    (await b.call("/auth/register/options", {})).response.status,
    401,
  );
});
test("discoverable UV options, real ES256 verification and opaque secure cookie survive fresh reload", async () => {
  const { browser, key, result, options } = await enroll();
  assert.equal(options.rp.id, rpID);
  assert.equal(options.authenticatorSelection.residentKey, "required");
  assert.equal(options.authenticatorSelection.userVerification, "required");
  assert.deepEqual(options.pubKeyCredParams, [{ alg: -7, type: "public-key" }]);
  const cookies = result.response.headers.getSetCookie();
  assert.ok(
    cookies.some(
      (c) =>
        c.startsWith("__Host-cloudnest_session=") &&
        c.includes("HttpOnly") &&
        c.includes("Secure") &&
        c.includes("SameSite=Strict") &&
        c.includes("Path=/"),
    ),
  );
  const raw = browser.cookies.get("__Host-cloudnest_session");
  const stored = await db
    .prepare("SELECT * FROM brain_browser_sessions")
    .first();
  assert.equal(stored.token_sha256, hex(raw));
  assert.ok(!JSON.stringify(stored).includes(raw));
  assert.equal(stored.absolute_until - stored.created_at, 12 * 60 * 60_000);
  assert.equal(stored.idle_until - stored.created_at, 30 * 60_000);
  browser.csrf = "";
  const reload = await browser.bootstrap();
  assert.equal(reload.value.authenticated, true);
  assert.match(browser.csrf, /^[a-f0-9]{64}$/);
  assert.equal((await browser.call("/protected")).response.status, 200);
  assert.equal((await browser.call("/protected", {})).response.status, 200);
  const second = new Browser(),
    authOptions = await loginOptions(second);
  assert.ok(!authOptions.allowCredentials?.length);
  assert.equal(authOptions.userVerification, "required");
  assert.equal(
    (await second.call("/auth/login/verify", assertion(authOptions, key)))
      .response.status,
    200,
  );
});
test("registration rejects wrong origin, wrong RP and missing user verification without storing credentials", async () => {
  for (const config of [
    { originValue: "https://evil.example.test" },
    { rpValue: "evil.example.test" },
    { uv: false },
  ]) {
    const b = new Browser(),
      options = await b.registrationOptions(),
      key = authenticator(options, config);
    assert.equal(
      (
        await b.call("/auth/register/verify", key.response, {
          Authorization: "Bearer " + owner,
        })
      ).response.status,
      401,
    );
  }
  assert.equal(
    (
      await db
        .prepare("SELECT count(*) AS n FROM brain_browser_passkeys")
        .first()
    ).n,
    0,
  );
});
test("one-use challenges reject sequential replay, concurrent replay and expired ceremonies", async () => {
  const { browser, key } = await enroll();
  const options = await loginOptions(browser),
    response = assertion(options, key);
  const cookie = browser.cookies.get("__Host-cloudnest_challenge");
  const results = await Promise.all([
    browser.call("/auth/login/verify", response),
    browser.call("/auth/login/verify", response),
  ]);
  assert.deepEqual(results.map((r) => r.response.status).sort(), [200, 401]);
  browser.cookies.set("__Host-cloudnest_challenge", cookie);
  assert.equal(
    (await browser.call("/auth/login/verify", response)).response.status,
    401,
  );
  const expired = await loginOptions(browser);
  await db
    .prepare("UPDATE brain_browser_challenges SET expires_at=?")
    .bind(Date.now() - 1)
    .run();
  assert.equal(
    (
      await browser.call(
        "/auth/login/verify",
        assertion(expired, key, { counter: 2 }),
      )
    ).response.status,
    401,
  );
});
test("assertions reject forged signatures, wrong origin/RP/challenge/user handle and absent UV", async () => {
  const { key } = await enroll();
  for (const config of [
    { corrupt: true },
    { originValue: "https://evil.example.test" },
    { rpValue: "evil.example.test" },
    { challenge: "different" },
    { userHandle: b64(randomBytes(32)) },
    { uv: false },
  ]) {
    const b = new Browser(),
      options = await loginOptions(b);
    assert.equal(
      (await b.call("/auth/login/verify", assertion(options, key, config)))
        .response.status,
      401,
    );
  }
});
test("challenge is bound to the initiating browser cookie and failed verification consumes its attempt", async () => {
  const { key } = await enroll(),
    first = new Browser(),
    options = await loginOptions(first),
    second = new Browser();
  await second.bootstrap();
  second.cookies.set(
    "__Host-cloudnest_challenge",
    first.cookies.get("__Host-cloudnest_challenge"),
  );
  assert.equal(
    (await second.call("/auth/login/verify", assertion(options, key))).response
      .status,
    401,
  );
  const invalid = assertion(options, key, { corrupt: true });
  assert.equal(
    (await first.call("/auth/login/verify", invalid)).response.status,
    401,
  );
  assert.equal(
    (await first.call("/auth/login/verify", assertion(options, key))).response
      .status,
    401,
  );
});
test("cookie mutations reject missing CSRF, foreign/null/missing Origin and sibling fetch-site; Bearer CLI remains supported", async () => {
  const { browser } = await enroll();
  for (const headers of [
    { "X-CloudNest-CSRF": "" },
    { Origin: "https://evil.example.test" },
    { Origin: "null" },
    { Origin: "" },
    { "Sec-Fetch-Site": "same-site" },
  ])
    assert.equal(
      (await browser.call("/protected", {}, headers)).response.status,
      403,
    );
  assert.equal(
    (await browser.call("/protected", {}, { Authorization: "Bearer wrong" }))
      .response.status,
    401,
  );
  const bearer = await runtime.dispatchFetch(
    "http://127.0.0.1/api/v1/protected",
    { method: "POST", headers: { Authorization: "Bearer " + owner } },
  );
  assert.equal(bearer.status, 200);
  assert.equal((await bearer.json()).mode, "bearer");
});
test("owner verifier rotation invalidates existing sessions, passkeys and pending enrollment challenges", async () => {
  const { browser, key } = await enroll();
  const options = await loginOptions(new Browser());
  assert.ok(options.challenge);
  assert.equal(
    (await browser.call("/protected", undefined, { "X-Test-Rotate": "yes" }))
      .response.status,
    401,
  );
  const b = new Browser();
  await b.bootstrap();
  const fresh = (
    await b.call("/auth/login/options", {}, { "X-Test-Rotate": "yes" })
  ).value.options;
  assert.equal(
    (
      await b.call("/auth/login/verify", assertion(fresh, key), {
        "X-Test-Rotate": "yes",
      })
    ).response.status,
    401,
  );
  const c = new Browser(),
    registerOptions = await c.registrationOptions(),
    candidate = authenticator(registerOptions);
  assert.equal(
    (
      await c.call("/auth/register/verify", candidate.response, {
        "X-Test-Rotate": "yes",
        Authorization: "Bearer " + owner,
      })
    ).response.status,
    401,
  );
});
test("idle and absolute deadlines fail closed; revocation/logout invalidate fresh reload and all sessions", async () => {
  const { browser, key } = await enroll();
  await db
    .prepare("UPDATE brain_browser_sessions SET idle_until=?")
    .bind(Date.now() - 1)
    .run();
  assert.equal((await browser.call("/protected")).response.status, 401);
  assert.equal((await browser.bootstrap()).value.authenticated, false);
  const options = await loginOptions(browser);
  assert.equal(
    (await browser.call("/auth/login/verify", assertion(options, key))).response
      .status,
    200,
  );
  await db
    .prepare("UPDATE brain_browser_sessions SET absolute_until=?")
    .bind(Date.now() - 1)
    .run();
  assert.equal((await browser.call("/protected")).response.status, 401);
  const first = new Browser(),
    firstOptions = await loginOptions(first);
  assert.equal(
    (
      await first.call(
        "/auth/login/verify",
        assertion(firstOptions, key, { counter: 2 }),
      )
    ).response.status,
    200,
  );
  const other = new Browser(),
    otherOptions = await loginOptions(other);
  assert.equal(
    (
      await other.call(
        "/auth/login/verify",
        assertion(otherOptions, key, { counter: 3 }),
      )
    ).response.status,
    200,
  );
  const logout = await first.call("/auth/logout", {});
  assert.equal(logout.response.status, 200);
  assert.equal((await first.bootstrap()).value.authenticated, false);
  assert.equal((await other.bootstrap()).value.authenticated, true);
  assert.equal(
    (await other.call("/auth/revoke-sessions", {})).response.status,
    200,
  );
  assert.equal((await other.bootstrap()).value.authenticated, false);
});
test("missing authorization audit never enrolls a credential or issues a session", async () => {
  const browser = new Browser(),
    options = await browser.registrationOptions(),
    key = authenticator(options);
  await db.prepare("DROP TABLE audit").run();
  assert.equal(
    (
      await browser.call("/auth/register/verify", key.response, {
        Authorization: "Bearer " + owner,
      })
    ).response.status,
    409,
  );
  assert.equal(
    (
      await db
        .prepare("SELECT count(*) AS n FROM brain_browser_passkeys")
        .first()
    ).n,
    0,
  );
  assert.equal(
    (
      await db
        .prepare("SELECT count(*) AS n FROM brain_browser_sessions")
        .first()
    ).n,
    0,
  );
});

test("an owner browser cookie never authorizes the real scoped-Bearer MCP endpoint", async () => {
  const { browser } = await enroll();
  const response = await runtime.dispatchFetch(origin + "/mcp", {
    method: "POST",
    headers: {
      Origin: origin,
      Cookie: [...browser.cookies].map(([k, v]) => k + "=" + v).join(";"),
      "X-CloudNest-CSRF": browser.csrf,
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
  });
  assert.equal(response.status, 401);
});
test("signature-counter rollback cannot be hidden behind a fresh challenge", async () => {
  const { key } = await enroll(),
    first = new Browser(),
    firstOptions = await loginOptions(first);
  assert.equal(
    (
      await first.call(
        "/auth/login/verify",
        assertion(firstOptions, key, { counter: 5 }),
      )
    ).response.status,
    200,
  );
  const second = new Browser(),
    secondOptions = await loginOptions(second);
  assert.equal(
    (
      await second.call(
        "/auth/login/verify",
        assertion(secondOptions, key, { counter: 4 }),
      )
    ).response.status,
    401,
  );
});
test("revoking every browser session invalidates multiple simultaneously active browsers", async () => {
  const { browser, key } = await enroll(),
    other = new Browser(),
    options = await loginOptions(other);
  assert.equal(
    (await other.call("/auth/login/verify", assertion(options, key))).response
      .status,
    200,
  );
  assert.equal(
    (
      await db
        .prepare("SELECT count(*) AS n FROM brain_browser_sessions")
        .first()
    ).n,
    2,
  );
  assert.equal(
    (await browser.call("/auth/revoke-sessions", {})).response.status,
    200,
  );
  assert.equal((await other.bootstrap()).value.authenticated, false);
  assert.equal(
    (
      await db
        .prepare("SELECT count(*) AS n FROM brain_browser_sessions")
        .first()
    ).n,
    0,
  );
});

test("cross-origin iframe ceremonies are rejected even when the signed origin and RP are correct", async () => {
  const browser = new Browser(),
    options = await browser.registrationOptions(),
    candidate = authenticator(options, { crossOrigin: true });
  assert.equal(
    (
      await browser.call("/auth/register/verify", candidate.response, {
        Authorization: "Bearer " + owner,
      })
    ).response.status,
    401,
  );
  const { key } = await enroll(),
    other = new Browser(),
    login = await loginOptions(other);
  assert.equal(
    (
      await other.call(
        "/auth/login/verify",
        assertion(login, key, { crossOrigin: true }),
      )
    ).response.status,
    401,
  );
});

test("new owner epoch can enroll a fresh passkey while the previous enrollment stays unusable", async () => {
  const { key } = await enroll(),
    browser = new Browser();
  await browser.call("/auth/session", undefined, { "X-Test-Rotate": "yes" });
  const options = await browser.call(
    "/auth/register/options",
    { label: "Fresh owner epoch" },
    { "X-Test-Rotate": "yes", Authorization: "Bearer " + rotatedOwner },
  );
  assert.equal(options.response.status, 200);
  const fresh = authenticator(options.value.options);
  assert.equal(
    (
      await browser.call("/auth/register/verify", fresh.response, {
        "X-Test-Rotate": "yes",
        Authorization: "Bearer " + rotatedOwner,
      })
    ).response.status,
    200,
  );
  assert.equal(
    (await browser.call("/protected", undefined, { "X-Test-Rotate": "yes" }))
      .response.status,
    200,
  );
  const old = new Browser();
  await old.call("/auth/session", undefined, { "X-Test-Rotate": "yes" });
  const challenge = await old.call(
    "/auth/login/options",
    {},
    { "X-Test-Rotate": "yes" },
  );
  assert.equal(
    (
      await old.call(
        "/auth/login/verify",
        assertion(challenge.value.options, key),
        { "X-Test-Rotate": "yes" },
      )
    ).response.status,
    401,
  );
});
