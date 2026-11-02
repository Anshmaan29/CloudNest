import { brainOrigin, projectID, scopedToken, validSession, SESSION_MS, rpc, tool, approvedMemories, contextPack, handoff, proposal, boundedText } from './core.mjs';
import { selectedText, insertText } from './page-actions.mjs';
const $ = id => document.getElementById(id);
let session = null, rows = [], generation = 0, busy = false, ready = false;
const startupGeneration = generation;
const say = text => { $('status').textContent = text; };
const originPattern = origin => origin + '/*';
const epoch = value => { if (value !== generation) throw new Error('Operation cancelled by disconnection.'); };
async function removeHosts() {
  const granted = await chrome.permissions.getAll();
  if (granted.origins?.length) await chrome.permissions.remove({ origins: granted.origins });
}
async function disconnect() {
  generation++; session = null; rows = []; $('results').replaceChildren(); $('token').value = ''; $('context').value = '';
  for (const id of ['proposal-title', 'proposal-body', 'proposal-source', 'objective', 'progress', 'problems', 'references', 'next']) $(id).value = '';
  $('proposal-consent').checked = false;
  await chrome.storage.session.remove('connection'); await removeHosts();
  $('connection').open = true; say('Disconnected. Session credential, drafts and host access cleared. Revoke the client in Brain Connections to disable it everywhere.');
}
function current() {
  if (!validSession(session)) throw new Error('Connect a valid session first.');
  return session;
}
async function act(work) {
  if (busy || !ready) return;
  busy = true; const request = generation;
  const controls = [...document.querySelectorAll('button')].filter(button => button.id !== 'disconnect');
  controls.forEach(button => { button.disabled = true; });
  try { await work(request); }
  catch (error) { if (request === generation) say(error instanceof Error ? error.message : 'Operation failed. No automatic retry was made.'); }
  finally { busy = false; controls.forEach(button => { button.disabled = false; }); }
}
async function pageAction(func, args = []) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !/^https?:/.test(tab.url || '')) throw new Error('Open a normal web page and focus its editor. Restricted browser pages use manual copy.');
  const result = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, func, args });
  const value = result[0]?.result;
  if (!value || value.error) throw new Error(value?.error || 'This page is unavailable. Use manual copy.');
  return value;
}
function showMemories() {
  const container = $('results'); container.replaceChildren();
  for (const row of rows) {
    const label = document.createElement('label'), check = document.createElement('input');
    check.type = 'checkbox'; check.dataset.id = row.id;
    const title = document.createElement('span'); title.textContent = ' ' + row.title;
    const excerpt = document.createElement('div'); excerpt.className = 'excerpt'; excerpt.textContent = row.body;
    const source = document.createElement('div'); source.className = 'fine'; source.textContent = `Source: ${row.source} · Updated: ${row.updatedAt || 'not supplied'}`;
    label.append(check, title, excerpt, source); container.append(label);
  }
  if (!rows.length) { const empty = document.createElement('p'); empty.textContent = 'No approved memories found for this authorized project.'; container.append(empty); }
}
$('connect').addEventListener('click', () => {
  if (busy || !ready) return;
  // Synchronous validation and permissions.request stay inside this user gesture.
  let candidate;
  try { candidate = { origin: brainOrigin($('origin').value.trim()), project: projectID($('project').value), token: scopedToken($('token').value.trim()) }; }
  catch (error) { say(error.message); return; }
  const access = chrome.permissions.request({ origins: [originPattern(candidate.origin)] });
  void act(async request => {
    const priorOrigin = session?.origin;
    try {
      if (!await access) throw new Error('Brain host permission was not granted.');
      epoch(request); say('Checking scoped MCP access…');
      await rpc(candidate, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'cloudnest-context-companion', version: '0.4.0' } });
      epoch(request);
      const result = await rpc(candidate, 'tools/list', {}); epoch(request);
      if (!Array.isArray(result.tools) || !result.tools.some(tool => tool.name === 'memory_search') || !result.tools.some(tool => tool.name === 'project_context')) throw new Error('The server does not provide the required scoped memory tools.');
      const connected = { ...candidate, tools: result.tools.map(tool => tool.name).filter(name => ['memory_search', 'project_context', 'memory_propose'].includes(name)), expiresAt: Date.now() + SESSION_MS };
      await chrome.storage.session.set({ connection: connected });
      if (request !== generation) { await chrome.storage.session.remove('connection'); throw new Error('Connection cancelled.'); }
      session = connected; $('token').value = ''; $('connection').open = false;
      if (priorOrigin && priorOrigin !== connected.origin) await chrome.permissions.remove({ origins: [originPattern(priorOrigin)] });
      say('Connected for this browser session, up to eight hours. Only approved project memories can be retrieved.');
    } catch (error) {
      $('token').value = '';
      if (priorOrigin !== candidate.origin) await chrome.permissions.remove({ origins: [originPattern(candidate.origin)] });
      throw error;
    }
  });
});
$('disconnect').addEventListener('click', () => { void disconnect().catch(() => say('Session cleared locally; check extension site permissions to remove remaining host access.')); });
for (const [button, name] of [['search', 'memory_search'], ['notes', 'project_context']]) $(button).addEventListener('click', () => void act(async request => {
  const saved = current(), args = { project: saved.project };
  if (name === 'memory_search') args.query = boundedText($('query').value, 200, 'Search query');
  say('Retrieving approved context…');
  const payload = await tool(saved, name, args); epoch(request);
  rows = approvedMemories(payload, saved.project); showMemories();
  say(`${rows.length} approved memories returned. Select only what you want to share.`);
}));
$('build-context').addEventListener('click', () => {
  try {
    const saved = current(), selected = new Set([...$('results').querySelectorAll('input:checked')].map(input => input.dataset.id));
    if (!selected.size) throw new Error('Select at least one approved memory.');
    $('context').value = contextPack(rows.filter(row => selected.has(row.id)), saved.project);
    say('Editable context prepared locally. Review before copying or inserting.');
  } catch (error) { say(error.message); }
});
$('copy').addEventListener('click', () => {
  const text = $('context').value;
  if (!text.trim()) return say('Prepare context or a handoff first.');
  void navigator.clipboard.writeText(text).then(() => say('Copied. Paste into your chosen assistant.')).catch(() => { $('context').focus(); $('context').select(); say('Clipboard unavailable. Selected the context; press Command+C or Ctrl+C.'); });
});
$('insert').addEventListener('click', () => void act(async request => {
  const text = boundedText($('context').value, 20000, 'Context');
  await pageAction(insertText, [text]); epoch(request);
  say('Insertion requested in the focused editor. Inspect the draft: this does not send it, and some websites may ignore synthetic input.');
}));
$('handoff').addEventListener('click', () => {
  const fields = Object.fromEntries(['objective', 'progress', 'problems', 'references', 'next'].map(key => [key, $(key).value]));
  if (!fields.objective.trim()) return say('Enter the task and objective first.');
  $('context').value = handoff(fields, $('context').value); say('Editable handoff generated locally. No model API or page collection was used.');
});
$('capture').addEventListener('click', () => void act(async request => {
  const value = await pageAction(selectedText); epoch(request);
  $('proposal-body').value = value.text; $('proposal-source').value = value.source; $('proposal-consent').checked = false;
  say('Only your selection was captured. Review its title, text and source before sending.');
}));
for (const id of ['proposal-body', 'proposal-title', 'proposal-source']) $(id).addEventListener('input', () => { $('proposal-consent').checked = false; });
$('propose').addEventListener('click', () => void act(async request => {
  const saved = current();
  if (!$('proposal-consent').checked) throw new Error('Review the selected text and explicitly approve sending it to the Inbox.');
  const args = proposal({ title: $('proposal-title').value, body: $('proposal-body').value, source: $('proposal-source').value }, saved.project);
  say('Submitting one proposal. A timeout requires checking the Inbox before another attempt.');
  const result = await tool(saved, 'memory_propose', args); epoch(request);
  if (result.proposal?.status !== 'pending' || typeof result.proposal?.id !== 'string') throw new Error('Submission status uncertain. Check the Inbox before retrying.');
  $('proposal-body').value = ''; $('proposal-consent').checked = false;
  say('Saved to the review Inbox. It is not an approved memory and is not exposed to other assistants.');
}));
await chrome.storage.session.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
$('extension-origin').textContent = chrome.runtime.getURL('').replace(/\/$/, '');
const stored = (await chrome.storage.session.get('connection')).connection;
if (startupGeneration !== generation) {
  ready = true;
} else if (validSession(stored)) {
  session = stored; $('origin').value = stored.origin; $('project').value = stored.project; $('connection').open = false;
  say('Session connected. Requests run only when you click an action.');
} else { await chrome.storage.session.remove('connection'); await removeHosts(); say('Connect a scoped Brain client to begin.'); }
ready = true;
