import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { brainOrigin, projectID, scopedToken, validSession, SESSION_MS, rpc, tool, approvedMemories, contextPack, handoff, proposal } from '../core.mjs';
import { selectedText, insertText } from '../page-actions.mjs';
const token = () => 'f'.repeat(64);
const session = () => ({ origin: 'https://brain.example.invalid', token: token(), project: 'project-one', tools: ['memory_search', 'project_context', 'memory_propose'], expiresAt: Date.now() + 10000 });
const response = result => async (url, init) => new Response(JSON.stringify({ jsonrpc: '2.0', id: JSON.parse(init.body).id, result }), { headers: { 'Content-Type': 'application/json' } });
const memory = overrides => ({ id: 'fixture-memory', project: 'project-one', title: 'Example', body: 'Reviewed fact', source: 'Owner note', updated_at: '2026-11-02T00:00:00Z', ...overrides });

test('only an exact HTTPS origin can receive the scoped credential', () => {
  assert.equal(brainOrigin('https://brain.example.invalid/'), 'https://brain.example.invalid');
  for (const value of ['http://brain.example.invalid', 'https://user:pass@brain.example.invalid', 'https://brain.example.invalid/mcp', 'https://brain.example.invalid/?token=example', 'https://brain.example.invalid/#fragment', 'https://brain.example.invalid:444', 'https://*.example.invalid', 'https://localhost']) assert.throws(() => brainOrigin(value));
});
test('project IDs and managed scoped credentials are bounded', () => {
  assert.equal(projectID(' project-one '), 'project-one'); assert.equal(scopedToken(token()), token());
  for (const value of ['', '../private', 'a'.repeat(129), 'two projects']) assert.throws(() => projectID(value));
  for (const value of ['', 'owner', 'Bearer ' + token(), 'g'.repeat(64), token() + 'extra']) assert.throws(() => scopedToken(value));
});
test('session expires and cannot extend beyond the local eight-hour ceiling', () => {
  const now = Date.now(), value = session(); assert.equal(validSession(value, now), true);
  for (const changed of [{ expiresAt: now }, { expiresAt: now + SESSION_MS + 1 }, { tools: null }, { origin: 'http://brain.example.invalid' }, { project: '../wrong' }]) assert.equal(validSession({ ...value, ...changed }, now), false);
});
test('MCP requests match production headers, omit cookies and reject redirects', async () => {
  let seen = false;
  const result = await rpc(session(), 'initialize', {}, async (url, init) => {
    seen = true; assert.equal(url, 'https://brain.example.invalid/mcp'); assert.equal(new URL(url).search, '');
    assert.equal(init.redirect, 'error'); assert.equal(init.credentials, 'omit'); assert.equal(init.cache, 'no-store'); assert.equal(init.referrerPolicy, 'no-referrer');
    assert.equal(init.headers.Authorization, 'Bearer ' + token()); assert.equal(init.headers['MCP-Protocol-Version'], '2025-11-25'); assert.match(init.headers.Accept, /text\/event-stream/);
    return response({ protocolVersion: '2025-11-25' })(url, init);
  });
  assert.equal(seen, true); assert.equal(result.protocolVersion, '2025-11-25');
});
test('expired credentials, denied origins, RPC failures and malformed envelopes fail closed', async () => {
  for (const status of [401, 403, 429, 503]) await assert.rejects(rpc(session(), 'initialize', {}, async () => new Response('{}', { status })));
  for (const value of [{ jsonrpc: '2.0', id: 'wrong', result: {} }, { error: { message: 'private server detail' } }, []]) await assert.rejects(rpc(session(), 'initialize', {}, async () => new Response(JSON.stringify(value))));
  await assert.rejects(rpc(session(), 'initialize', {}, response({ isError: true })), /rejected/);
});
test('oversized responses are bounded before parsing and raw server text is not exposed', async () => {
  await assert.rejects(rpc(session(), 'initialize', {}, async () => new Response('x'.repeat(262145))), /invalid or oversized/);
  await assert.rejects(rpc(session(), 'initialize', {}, async () => new Response('private diagnostic')), error => !error.message.includes('private diagnostic'));
});
test('tool allowlist cannot approve, delete, restore or query another project', async () => {
  for (const name of ['memory_delete', 'memory_approve', 'files_restore', 'arbitrary']) await assert.rejects(tool(session(), name, { project: 'project-one' }));
  await assert.rejects(tool(session(), 'memory_search', { project: 'other-project' }), /mismatch/);
  await assert.rejects(tool({ ...session(), tools: ['memory_search'] }, 'memory_propose', { project: 'project-one' }), /permit/);
});
test('approved production MCP memory shape is supported without inventing visibility fields', async () => {
  const payload = { memories: [memory()] };
  const result = await tool(session(), 'memory_search', { project: 'project-one', query: 'fixture' }, response({ content: [{ type: 'text', text: JSON.stringify(payload) }] }));
  assert.equal(approvedMemories(result, 'project-one')[0].updatedAt, '2026-11-02T00:00:00Z');
});
test('unexpected projects, explicit private results and oversized memory bodies are refused', () => {
  for (const row of [memory({ project: 'private' }), memory({ visibility: 'private' }), memory({ body: 'x'.repeat(2001) }), memory({ title: null })]) assert.throws(() => approvedMemories({ memories: [row] }, 'project-one'));
  assert.throws(() => approvedMemories({ memories: Array(21).fill(memory()) }, 'project-one'));
});
test('context and handoffs retain provenance, mark retrieved text untrusted, and stay bounded', () => {
  const rows = approvedMemories({ memories: [memory()] }, 'project-one'), pack = contextPack(rows, 'project-one');
  assert.match(pack, /untrusted reference data/); assert.match(pack, /Owner note/); assert.match(pack, /fixture-memory/);
  const transfer = handoff({ objective: 'Resume task', progress: 'Archived', problems: 'None', references: 'manifest.json', next: 'Restore' }, pack);
  for (const text of ['Task and objective', 'Current progress', 'Unresolved problems', 'Relevant file references', 'Next recommended action', 'Relevant approved memories, project context and decisions']) assert.ok(transfer.includes(text));
  assert.ok(handoff({ objective: 'x'.repeat(100000) }, 'y'.repeat(100000)).length <= 20000);
});
test('selection proposals preserve source and go only to the supported Inbox tool schema', () => {
  assert.deepEqual(proposal({ title: ' Selection ', body: ' selected text ', source: 'Explicit selection' }, 'project-one'), { project: 'project-one', title: 'Selection', body: 'selected text', source: 'Explicit selection', category: 'conversation-selection' });
  for (const changed of [{ title: '' }, { body: 'x'.repeat(10001) }, { source: '\0' }]) assert.throws(() => proposal({ title: 'Title', body: 'Body', source: 'Source', ...changed }, 'project-one'));
});
test('manifest requests no persistent page reader, background process or mandatory hosts', () => {
  const manifest = JSON.parse(fs.readFileSync(new URL('../manifest.json', import.meta.url)));
  assert.equal(manifest.manifest_version, 3); assert.deepEqual(manifest.permissions.sort(), ['activeTab', 'scripting', 'storage']);
  assert.deepEqual(manifest.optional_host_permissions, ['https://*/*']);
  for (const key of ['host_permissions', 'content_scripts', 'background', 'externally_connectable', 'web_accessible_resources']) assert.equal(manifest[key], undefined);
  assert.equal(manifest.incognito, 'not_allowed'); assert.ok(!manifest.content_security_policy.extension_pages.includes('unsafe-'));
});
test('popup stores tokens only in trusted session storage and does not render retrieved HTML', () => {
  const source = fs.readFileSync(new URL('../popup.mjs', import.meta.url), 'utf8');
  assert.match(source, /TRUSTED_CONTEXTS/); assert.match(source, /chrome\.storage\.session\.set/);
  for (const text of ['storage.local', 'storage.sync', 'localStorage', 'innerHTML', 'outerHTML', '.submit(', 'requestSubmit(', 'console.log', 'setInterval']) assert.ok(!source.includes(text), text);
  assert.match(source, /permissions\.request\(\{ origins: \[originPattern\(candidate\.origin\)\]/);
});
function withPage(page, work) {
  const saved = { document: globalThis.document, window: globalThis.window, location: globalThis.location, InputEvent: globalThis.InputEvent };
  Object.assign(globalThis, page);
  try { return work(); } finally { Object.assign(globalThis, saved); }
}
test('capture reads only selected text and origin, excludes passwords and oversized selections', () => {
  withPage({ document: { activeElement: null }, window: { getSelection: () => ({ toString: () => 'chosen text' }) }, location: { origin: 'https://chat.example.invalid', href: 'https://chat.example.invalid/private?token=secret' } }, () => {
    assert.deepEqual(selectedText(), { text: 'chosen text', source: 'https://chat.example.invalid · user-selected text' });
    document.activeElement = { tagName: 'INPUT', type: 'password' }; assert.match(selectedText().error, /Password/);
    document.activeElement = null; window.getSelection = () => ({ toString: () => 'x'.repeat(10001) }); assert.match(selectedText().error, /10,000/);
  });
});
test('textarea capture respects the explicitly highlighted range', () => {
  withPage({ document: { activeElement: { tagName: 'TEXTAREA', value: 'privateSELECTprivate', selectionStart: 7, selectionEnd: 13 } }, window: { getSelection: () => null }, location: { origin: 'https://chat.example.invalid' } }, () => assert.equal(selectedText().text, 'SELECT'));
});
test('insertion touches only a writable focused textarea and dispatches input without sending', () => {
  const calls = [], active = { tagName: 'TEXTAREA', selectionStart: 0, selectionEnd: 0, value: 'draft', maxLength: -1, setRangeText: (...args) => calls.push(args), dispatchEvent: value => calls.push(value.type) };
  withPage({ document: { activeElement: active }, InputEvent: class { constructor(type) { this.type = type; } } }, () => {
    assert.deepEqual(insertText('context'), { inserted: true }); assert.deepEqual(calls, [['context', 0, 0, 'end'], 'input']);
    active.readOnly = true; assert.ok(insertText('context').error);
    active.readOnly = false; active.maxLength = 5; assert.ok(insertText('context').error);
    document.activeElement = { tagName: 'INPUT', type: 'password' }; assert.ok(insertText('context').error);
  });
});
test('contenteditable insertion requires an actual caret in the focused editor and honest fallback', () => {
  const active = { tagName: 'DIV', isContentEditable: true, getAttribute: () => 'textbox', contains: () => false };
  withPage({ document: { activeElement: active, execCommand: () => false }, window: { getSelection: () => ({ rangeCount: 1, getRangeAt: () => ({ commonAncestorContainer: {} }) }) } }, () => {
    assert.match(insertText('context').error, /caret/); active.contains = () => true; assert.match(insertText('context').error, /manually/);
    document.execCommand = () => true; assert.deepEqual(insertText('context'), { inserted: true });
  });
});

test('multibyte proposal requests respect the actual server byte limit before network access', async () => {
  let sent = false;
  await assert.rejects(rpc(session(), 'tools/call', { text: '😀'.repeat(5000) }, async () => { sent = true; }), /16 KiB/);
  assert.equal(sent, false);
});

test('scoped connection files are bounded, public-host checked and never accept owner files', async () => {
  const {scopedConnectionFile}=await import('../core.mjs');
  const valid={schemaVersion:1,kind:'scoped-client',origin:'https://brain.example.invalid',project:'qa',token:'f'.repeat(64)};
  assert.equal(scopedConnectionFile(JSON.stringify(valid)).project,'qa');
  for(const v of [{schemaVersion:1,baseURL:valid.origin,ownerToken:valid.token},{...valid,ownerToken:valid.token},{...valid,schemaVersion:true},{...valid,origin:'http://brain.example.invalid'},{...valid,origin:valid.origin+'/private'},{...valid,token:'bad'}])assert.throws(()=>scopedConnectionFile(JSON.stringify(v)));
  assert.throws(()=>scopedConnectionFile(' '.repeat(8193)));
});
