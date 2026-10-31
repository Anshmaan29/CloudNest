import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
const source = (
  await build({
    entryPoints: ["web/console/browser-session.ts"],
    bundle: true,
    write: false,
    format: "esm",
    platform: "node",
  })
).outputFiles[0].text;
const { BrowserSession } = await import(
  "data:text/javascript;base64," + Buffer.from(source).toString("base64")
);
const originalFetch = globalThis.fetch,
  originalWindow = globalThis.window;
afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalWindow === undefined) delete globalThis.window;
  else globalThis.window = originalWindow;
});
const active = () => ({
  authenticated: true,
  csrf: "a".repeat(64),
  idleUntil: Date.now() + 1800000,
  absoluteUntil: Date.now() + 43200000,
});
test("reload inspects HttpOnly cookie session without Bearer or persisted authentication material", async () => {
  let sent;
  globalThis.fetch = async (url, options) => {
    sent = { url, options };
    return Response.json(active());
  };
  const session = new BrowserSession();
  await session.inspect();
  assert.equal(session.state.authenticated, true);
  assert.equal(sent.url, "/api/v1/auth/session");
  assert.equal(sent.options.credentials, "same-origin");
  assert.equal(sent.options.cache, "no-store");
  assert.equal(sent.options.headers.Authorization, undefined);
  assert.equal(sent.options.body, undefined);
});
test("cookie mutations send tab CSRF and never a synthetic owner Bearer", async () => {
  let sent;
  globalThis.fetch = async (url, options) => {
    sent = { url, options };
    return Response.json({ authenticated: false });
  };
  const session = new BrowserSession();
  session.state = active();
  await session.call("/logout", {});
  assert.equal(sent.options.headers["X-CloudNest-CSRF"], "a".repeat(64));
  assert.equal(sent.options.headers.Authorization, undefined);
  assert.equal(sent.options.credentials, "same-origin");
  assert.equal(sent.url, "/api/v1/auth/logout");
});
test("locking rejects a late response so stale sign-in cannot restore authenticated tab state", async () => {
  let finish;
  globalThis.fetch = () =>
    new Promise((resolve) => {
      finish = resolve;
    });
  const session = new BrowserSession(),
    pending = session.inspect();
  session.clear();
  finish(Response.json(active()));
  await assert.rejects(pending, /canceled/);
  assert.equal(session.state.authenticated, false);
  assert.equal(session.state.csrf, "");
});
test("sign-out clears tab access immediately while retaining CSRF only in the outgoing request", async () => {
  let finish, header;
  globalThis.fetch = async (url, options) => {
    header = options.headers["X-CloudNest-CSRF"];
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const session = new BrowserSession();
  session.state = active();
  const pending = session.signOut(true);
  assert.equal(session.state.authenticated, false);
  assert.equal(session.state.csrf, "");
  assert.equal(header, "a".repeat(64));
  finish(Response.json({ authenticated: false }));
  await pending;
  assert.equal(session.state.authenticated, false);
});
test("an oversized streamed auth response is bounded and unsupported passkeys do not start a ceremony", async () => {
  const session = new BrowserSession();
  globalThis.fetch = async () => new Response("x".repeat(65537));
  await assert.rejects(session.inspect(), /size limit/);
  let contacted = false;
  globalThis.fetch = async () => {
    contacted = true;
    return Response.json({});
  };
  globalThis.window = { isSecureContext: false };
  await assert.rejects(session.signIn(), /HTTPS/);
  assert.equal(contacted, false);
});
