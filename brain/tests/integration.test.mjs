import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import wrangler from 'wrangler';
const { unstable_splitSqlQuery: splitSqlQuery } = wrangler;
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

let runtime, db, endpoint;
const tokens = { reader: randomBytes(32).toString('hex'), other: randomBytes(32).toString('hex'), expired: randomBytes(32).toString('hex'), revoked: randomBytes(32).toString('hex') };
const hash = token => createHash('sha256').update(token).digest('hex');
before(async () => {
  const bundled = await build({ entryPoints: ['brain/worker/index.ts'], bundle: true, write: false, format: 'esm', target: 'es2022' });
  const grants = Object.entries(tokens).map(([id, token]) => ({ id, sha256: hash(token), projects: [id === 'other' ? 'other' : 'cloudnest'], expiresAt: id === 'expired' ? '2000-01-01T00:00:00Z' : '2099-01-01T00:00:00Z', revoked: id === 'revoked' }));
  runtime = new Miniflare(convertV4MiniflareOptions({
    modules: true, script: bundled.outputFiles[0].text, compatibilityDate: '2026-10-30',
    host: '127.0.0.1', port: 0, cf: false, d1Databases: { DB: 'cloudnest-test' },
    bindings: { CLIENTS_JSON: JSON.stringify(grants), ALLOWED_ORIGINS: '', PUBLIC_ORIGIN: '' }
  }));
  endpoint = new URL('/mcp', await runtime.ready);
  db = await runtime.getD1Database('DB');
  const migration = await readFile('brain/migrations/0001_feasibility.sql', 'utf8');
  await db.batch(splitSqlQuery(migration).map(sql => db.prepare(sql)));
  const insert = db.prepare('INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at,expires_at) VALUES(?,?,?,?,?,1,?,?,?)');
  await db.batch([
    insert.bind('safe', 'cloudnest', 'Archive safety', 'Keep originals until SHA-256 verification.', 'fixture:phase0', 'approved', '2026-10-30T00:00:00.000Z', null),
    insert.bind('private', 'cloudnest', 'Private safety', 'PRIVATE_SENTINEL', 'fixture:phase0', 'private', '2026-10-30T00:00:00.000Z', null),
    insert.bind('inbox', 'cloudnest', 'Unapproved safety', 'INBOX_SENTINEL', 'fixture:phase0', 'inbox', '2026-10-30T00:00:00.000Z', null),
    insert.bind('other', 'other', 'Other safety', 'OTHER_SENTINEL', 'fixture:phase0', 'approved', '2026-10-30T00:00:00.000Z', null),
    insert.bind('old', 'cloudnest', 'Expired safety', 'EXPIRED_SENTINEL', 'fixture:phase0', 'approved', '2026-10-30T00:00:00.000Z', '2000-01-01T00:00:00.000Z')
  ]);
});
after(async () => { if (runtime) await runtime.dispose(); });
function headers(token = tokens.reader) { return { Authorization: `Bearer ${token}`, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' }; }
async function rpc(method, params = {}, extra = {}, token = tokens.reader) {
  return fetch(endpoint, { method: 'POST', headers: { ...headers(token), ...extra }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
}
async function call(name, args = {}, token = tokens.reader) {
  const response = await rpc('tools/call', { name, arguments: args }, {}, token);
  assert.equal(response.status, 200); const reply = await response.json();
  assert.equal(reply.result?.isError, undefined, JSON.stringify(reply));
  return JSON.parse(reply.result.content[0].text);
}
test('official MCP SDK connects and retrieves an authorized memory over HTTP', async () => {
  const client = new Client({ name: 'cloudnest-feasibility-test', version: '0.1.0' });
  try {
    await client.connect(new StreamableHTTPClientTransport(endpoint, { requestInit: { headers: { Authorization: `Bearer ${tokens.reader}` } } }));
    assert.equal(client.getServerVersion().name, 'cloudnest-brain-feasibility');
    const list = await client.listTools();
    assert.deepEqual(list.tools.map(t => t.name), ['memory_search', 'memory_read', 'memory_recent', 'project_context']);
    const reply = await client.callTool({ name: 'memory_search', arguments: { query: 'verification' } });
    const memories = JSON.parse(reply.content[0].text).memories;
    assert.equal(memories.length, 1); assert.equal(memories[0].id, 'safe');
  } finally { await client.close(); }
});
test('missing, invalid, expired and revoked credentials fail closed', async () => {
  assert.equal((await fetch(endpoint)).status, 401);
  for (const token of ['x'.repeat(64), tokens.expired, tokens.revoked]) assert.equal((await rpc('tools/list', {}, {}, token)).status, 401);
});
test('private, Inbox, expired and cross-project memories never appear', async () => {
  const search = await call('memory_search', { query: 'safety' });
  assert.deepEqual(search.memories.map(m => m.id), ['safe']);
  for (const id of ['private', 'inbox', 'old', 'other', 'does-not-exist']) assert.deepEqual((await call('memory_read', { id })).memories, []);
  assert.deepEqual((await call('memory_recent', { project: 'other' })).memories, []);
  assert.deepEqual((await call('memory_recent', {}, tokens.other)).memories.map(m => m.id), ['other']);
});
test('project context is bounded, authorized and carries provenance', async () => {
  const context = await call('project_context', { project: 'cloudnest' });
  assert.equal(context.memories.length, 1); assert.equal(context.memories[0].source, 'fixture:phase0');
  assert.deepEqual((await call('project_context', { project: 'other' })).memories, []);
});
test('origin, protocol and transport checks reject incompatible requests', async () => {
  assert.equal((await rpc('tools/list', {}, { Origin: 'https://attacker.example' })).status, 403);
  assert.equal((await rpc('tools/list', {}, { 'MCP-Protocol-Version': 'invalid' })).status, 400);
  assert.equal((await fetch(endpoint, { headers: headers() })).status, 405);
  assert.equal((await rpc('tools/list', {}, { Accept: 'application/json' })).status, 406);
});
test('malformed and oversized JSON is rejected before dispatch', async () => {
  for (const content of ['[]', '{', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping', params: 'invalid' }), ' '.repeat(20_000)]) {
    const response = await fetch(endpoint, { method: 'POST', headers: headers(), body: content });
    assert.equal(response.status, 400);
  }
});
test('write tools and unexpected parameters are unavailable', async () => {
  assert.equal((await (await rpc('tools/call', { name: 'memory_delete', arguments: { id: 'safe' } })).json()).error.code, -32602);
  assert.equal((await (await rpc('tools/call', { name: 'memory_search', arguments: { query: 'safety', visibility: 'private' } })).json()).error.code, -32602);
  assert.deepEqual((await call('memory_search', { query: "' OR 1=1 --" })).memories, []);
});
test('FTS correction and deletion update results without stale copies', async () => {
  await db.prepare("INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at) VALUES('change','cloudnest','Change','alphafixture','fixture',1,'approved','2026-10-30T00:00:00Z')").run();
  assert.equal((await call('memory_search', { query: 'alphafixture' })).memories.length, 1);
  await db.prepare("UPDATE memories SET body='betafixture',version=2 WHERE id='change'").run();
  assert.equal((await call('memory_search', { query: 'alphafixture' })).memories.length, 0);
  assert.equal((await call('memory_search', { query: 'betafixture' })).memories[0].version, 2);
  await db.prepare("DELETE FROM memories WHERE id='change'").run();
  assert.equal((await call('memory_search', { query: 'betafixture' })).memories.length, 0);
});
test('audit records contain only authorized IDs and no query or token', async () => {
  const rows = (await db.prepare('SELECT * FROM audit').all()).results;
  assert.ok(rows.length > 0);
  assert.ok(!rows.some(r => ['private', 'inbox', 'old'].includes(r.memory_id)));
  const encoded = JSON.stringify(rows); assert.ok(!encoded.includes(tokens.reader));
});
test('large memory bodies are bounded before being returned', async () => {
  await db.prepare("INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at) VALUES('large','cloudnest','Large',?,'fixture',1,'approved','2026-10-30T00:00:00Z')").bind('boundedfixture '.repeat(5000)).run();
  const memory = (await call('memory_read', { id: 'large' })).memories[0];
  assert.equal(memory.body.length, 2000);
  await db.prepare("DELETE FROM memories WHERE id='large'").run();
});
test('audit failure prevents returning retrieved content', async () => {
  await db.prepare('DROP TABLE audit').run();
  const response = await rpc('tools/call', { name: 'memory_read', arguments: { id: 'safe' } });
  const text = await response.text(); const value = JSON.parse(text);
  assert.equal(value.result.isError, true);
  assert.ok(!text.includes('Keep originals'));
});
