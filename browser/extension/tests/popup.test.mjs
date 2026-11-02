import test from 'node:test';
import assert from 'node:assert/strict';

class Element {
  constructor(id = '') { this.id = id; this.value = ''; this.checked = false; this.disabled = false; this.open = true; this.listeners = {}; this.children = []; this.dataset = {}; this.textContent = ''; }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  click() { this.listeners.click?.(); }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  querySelectorAll() { return []; }
}
const buttonIDs = ['connect', 'disconnect', 'search', 'notes', 'build-context', 'copy', 'insert', 'handoff', 'capture', 'propose'];
async function until(predicate) {
  const end = performance.now() + 2000;
  while (!predicate()) { if (performance.now() >= end) throw new Error('Popup did not settle.'); await new Promise(resolve => setImmediate(resolve)); }
}
async function popup(t, { connection, fetcher } = {}) {
  const keys = ['document', 'chrome', 'fetch'], before = Object.fromEntries(keys.map(key => [key, globalThis[key]]));
  t.after(() => { for (const key of keys) { if (before[key] === undefined) delete globalThis[key]; else globalThis[key] = before[key]; } });
  const nodes = new Map(), memory = connection ? { connection } : {}, hosts = new Set(), requests = [];
  const node = id => { if (!nodes.has(id)) nodes.set(id, new Element(id)); return nodes.get(id); };
  globalThis.document = { getElementById: node, querySelectorAll: () => buttonIDs.map(node), createElement: () => new Element() };
  globalThis.chrome = {
    runtime: { getURL: () => 'chrome-extension://synthetic-extension/' },
    permissions: {
      request: async ({ origins }) => { origins.forEach(origin => hosts.add(origin)); return true; },
      getAll: async () => ({ origins: [...hosts] }),
      remove: async ({ origins }) => { origins.forEach(origin => hosts.delete(origin)); return true; }
    },
    storage: { session: {
      setAccessLevel: async input => assert.deepEqual(input, { accessLevel: 'TRUSTED_CONTEXTS' }),
      get: async () => ({ ...memory }), set: async input => Object.assign(memory, input), remove: async key => { delete memory[key]; }
    } }
  };
  globalThis.fetch = async (url, init) => {
    const request = JSON.parse(init.body); requests.push(request);
    const result = fetcher ? await fetcher(request) : request.method === 'initialize' ? { protocolVersion: '2025-11-25' } : { tools: [{ name: 'memory_search' }, { name: 'project_context' }, { name: 'memory_propose' }] };
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }));
  };
  await import('../popup.mjs?fixture=' + crypto.randomUUID());
  return { node, memory, hosts, requests };
}
function fill(f) { f.node('origin').value = 'https://brain.example.invalid'; f.node('project').value = 'project-one'; f.node('token').value = 'f'.repeat(64); }
function saved() { return { origin: 'https://brain.example.invalid', project: 'project-one', token: 'f'.repeat(64), tools: ['memory_search', 'project_context', 'memory_propose'], expiresAt: Date.now() + 10000 }; }

test('actual popup verifies MCP before storing only a session-scoped connection', async t => {
  const f = await popup(t); fill(f); assert.equal(f.memory.connection, undefined);
  f.node('connect').click(); await until(() => f.memory.connection && !f.node('connect').disabled);
  assert.deepEqual(f.requests.map(request => request.method), ['initialize', 'tools/list']);
  assert.equal(f.memory.connection.origin, 'https://brain.example.invalid'); assert.equal(f.node('token').value, '');
  assert.deepEqual([...f.hosts], ['https://brain.example.invalid/*']);
});
test('disconnect during MCP pairing cannot resurrect a late session or host grant', async t => {
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  const f = await popup(t, { fetcher: request => request.method === 'initialize' ? blocked : { tools: [{ name: 'memory_search' }, { name: 'project_context' }] } });
  fill(f); f.node('connect').click(); await until(() => f.requests.length === 1);
  f.node('disconnect').click(); await until(() => f.hosts.size === 0);
  release({ protocolVersion: '2025-11-25' }); await until(() => !f.node('connect').disabled);
  assert.equal(f.memory.connection, undefined); assert.equal(f.hosts.size, 0); assert.equal(f.requests.length, 1);
  assert.match(f.node('status').textContent, /Disconnected/);
});
test('actual Inbox action requires explicit consent and makes one scoped proposal without auto-approval', async t => {
  const f = await popup(t, { connection: saved(), fetcher: () => ({ content: [{ type: 'text', text: JSON.stringify({ proposal: { id: 'fixture-proposal', status: 'pending' } }) }] }) });
  f.node('proposal-title').value = 'Selected conversation'; f.node('proposal-body').value = 'Only reviewed selection'; f.node('proposal-source').value = 'User selection';
  f.node('propose').click(); await until(() => !f.node('propose').disabled);
  assert.equal(f.requests.length, 0); assert.match(f.node('status').textContent, /explicitly approve/);
  f.node('proposal-consent').checked = true; f.node('propose').click(); f.node('propose').click();
  await until(() => !f.node('propose').disabled);
  assert.equal(f.requests.length, 1); assert.equal(f.requests[0].params.name, 'memory_propose');
  assert.equal(f.requests[0].params.arguments.project, 'project-one'); assert.equal(f.requests[0].params.arguments.body, 'Only reviewed selection');
  assert.equal(f.node('proposal-body').value, ''); assert.equal(f.node('proposal-consent').checked, false);
  assert.match(f.node('status').textContent, /not an approved memory/);
});
test('timeout or ambiguous Inbox response is never retried automatically or reported as saved', async t => {
  const f = await popup(t, { connection: saved(), fetcher: () => ({ content: [{ type: 'text', text: '{}' }] }) });
  f.node('proposal-title').value = 'Selection'; f.node('proposal-body').value = 'Reviewed'; f.node('proposal-source').value = 'User'; f.node('proposal-consent').checked = true;
  f.node('propose').click(); await until(() => !f.node('propose').disabled);
  assert.equal(f.requests.length, 1); assert.equal(f.node('proposal-body').value, 'Reviewed'); assert.match(f.node('status').textContent, /uncertain/);
});

test('switching paired project clears old context, selected results and proposal drafts', async t => {
  const f = await popup(t, { connection: saved() });
  f.node('context').value = 'Previously approved private context';
  f.node('proposal-body').value = 'Unsubmitted private selection'; f.node('proposal-consent').checked = true;
  f.node('results').append(new Element());
  fill(f); f.node('project').value = 'project-two'; f.node('connect').click();
  await until(() => f.memory.connection?.project === 'project-two' && !f.node('connect').disabled);
  assert.equal(f.node('context').value, ''); assert.equal(f.node('results').children.length, 0);
  assert.equal(f.node('proposal-body').value, ''); assert.equal(f.node('proposal-consent').checked, false);
});

test('local pairing import keeps token out of DOM and does not connect automatically', async t => {
  const f=await popup(t);await until(()=>f.node('status').textContent.length>0);
  const fixture={schemaVersion:1,kind:'scoped-client',origin:'https://brain.example.invalid',project:'project-one',token:'f'.repeat(64)};
  f.node('pairing-file').files=[{size:200,text:async()=>JSON.stringify(fixture)}];await f.node('pairing-file').listeners.change();
  assert.equal(f.requests.length,0);assert.equal(f.memory.connection,undefined);assert.equal(f.node('token').value,'');assert.equal(f.node('project').value,'project-one');
  f.node('connect').click();await until(()=>!!f.memory.connection);assert.equal(f.memory.connection.token,fixture.token);
});
test('disconnect invalidates an unfinished local connection-file read', async t => {
  const f=await popup(t);await until(()=>f.node('status').textContent.length>0);let finish;
  f.node('pairing-file').files=[{size:200,text:()=>new Promise(resolve=>{finish=resolve;})}];const pending=f.node('pairing-file').listeners.change();
  f.node('disconnect').click();finish(JSON.stringify({schemaVersion:1,kind:'scoped-client',origin:'https://brain.example.invalid',project:'project-one',token:'f'.repeat(64)}));await pending;
  assert.equal(f.node('project').value,'');assert.equal(f.node('token').value,'');assert.equal(f.memory.connection,undefined);assert.equal(f.requests.length,0);
});
