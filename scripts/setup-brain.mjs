#!/usr/bin/env node
// Interactive owner setup only. Never invoked by the app, a login item, or CI.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import crypto from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCOPE = 'https://www.googleapis.com/auth/drive.file';
const SECRET_NAMES = ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'GOOGLE_REFRESH_TOKEN', 'OWNER_TOKEN_SHA256', 'VAULT_SIGNING_KEY'].sort();
export class SetupError extends Error {}
const fail = message => { throw new SetupError(message); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const inside = (child, parent) => child === parent || child.startsWith(parent + path.sep);

export function parseJSONC(text) {
  // Strip comments outside strings; a URL's // must survive unchanged.
  let result = '', quoted = false, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) { result += c; if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; continue; }
    if (c === '"') { quoted = true; result += c; continue; }
    if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; result += '\n'; continue; }
    if (c === '/' && text[i + 1] === '*') { i += 2; while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++; if (i >= text.length) fail('Unterminated configuration comment.'); i++; result += ' '; continue; }
    if (c === ',') { let j = i + 1; while (/\s/.test(text[j] ?? '') && j < text.length) j++; if (text[j] === '}' || text[j] === ']') continue; }
    result += c;
  }
  // A second pass handles trailing commas followed by comments stripped above.
  if (result !== text) return parseJSONC(result);
  try { return JSON.parse(result); } catch { fail('Configuration is not valid JSON or JSONC.'); }
}

export function canonicalProspective(input) {
  if (typeof input !== 'string' || !path.isAbsolute(input)) fail('Use absolute paths for setup inputs.');
  let existing = path.resolve(input); const tail = [];
  while (!fs.existsSync(existing)) { const parent = path.dirname(existing); if (parent === existing) fail('Path has no existing parent.'); tail.unshift(path.basename(existing)); existing = parent; }
  return path.join(fs.realpathSync(existing), ...tail);
}
export function requireOutsideGit(input, repo = REPO) {
  const resolved = canonicalProspective(input), own = fs.realpathSync(repo);
  if (inside(resolved, own)) fail('Credentials and prepared setup must stay outside the source repository.');
  for (let directory = resolved; ; directory = path.dirname(directory)) {
    if (fs.existsSync(path.join(directory, '.git')) || (fs.existsSync(path.join(directory, 'HEAD')) && fs.existsSync(path.join(directory, 'objects')) && fs.existsSync(path.join(directory, 'refs')))) fail('Credentials and prepared setup must stay outside every Git repository.');
    if (path.dirname(directory) === directory) break;
  }
  return resolved;
}
export function readBounded(input, { privateFile = false, maximum = 131072 } = {}) {
  const fd = fs.openSync(input, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.size > maximum || before.nlink !== 1 || (process.getuid && before.uid !== process.getuid())) fail('Input must be an owned, bounded regular file, without links.');
    if (privateFile && (before.mode & 0o077)) fail('Prepared files must have owner-only permissions (chmod 600).');
    const data = fs.readFileSync(fd), after = fs.fstatSync(fd);
    if (data.length > maximum || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) fail('Input changed while being read.');
    return data.toString('utf8');
  } finally { fs.closeSync(fd); }
}
function writePrivate(file, value) {
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function saveJournal(directory, value) {
  const temporary = path.join(directory, '.journal-' + crypto.randomUUID()); writePrivate(temporary, value);
  fs.renameSync(temporary, path.join(directory, 'deployment.private.json'));
  const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
export function resolvePlan(options, repo = REPO) {
  if (!options.oauthClient) fail('Pass --oauth-client with a dedicated Google Desktop App JSON file.');
  const clientPath = requireOutsideGit(options.oauthClient, repo);
  if (fs.lstatSync(options.oauthClient).isSymbolicLink()) fail('OAuth JSON must not be a symbolic link.');
  let installed; try { installed = JSON.parse(readBounded(clientPath)).installed; } catch (error) { if (error instanceof SetupError) throw error; fail('OAuth JSON could not be read.'); }
  if (!installed || typeof installed.client_id !== 'string' || !/^[A-Za-z0-9._-]{8,256}\.apps\.googleusercontent\.com$/.test(installed.client_id) || typeof installed.client_secret !== 'string' || !installed.client_secret.length || installed.client_secret.length > 1024) fail('A dedicated Desktop App OAuth JSON with client ID and secret is required; Web clients are unsupported.');
  const configPath = options.config ?? path.join(repo, 'brain/wrangler.local.jsonc');
  const input = parseJSONC(readBounded(configPath));
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(input.name ?? '')) fail('Configuration needs a valid existing Worker name.');
  if (!/^[a-f0-9]{32}$/i.test(input.account_id ?? '')) fail('Put the existing Cloudflare account ID in your private configuration so deployment cannot select another account.');
  const allowed = ['$schema', 'name', 'main', 'compatibility_date', 'compatibility_flags', 'workers_dev', 'observability', 'account_id', 'd1_databases', 'vars', 'assets'];
  if (Object.keys(input).some(key => !allowed.includes(key))) fail('Use the lightweight CloudNest Wrangler configuration; extra resource, build, environment, or route configuration needs separate review.');
  if (!Array.isArray(input.d1_databases) || input.d1_databases.length !== 1 || input.d1_databases[0].binding !== 'DB' || !/^[a-f0-9-]{36}$/i.test(input.d1_databases[0].database_id ?? '') || /^0{8}-/.test(input.d1_databases[0].database_id)) fail('Configure the existing D1 DB binding and real database ID first.');
  const config = structuredClone(input); delete config.$schema;
  config.observability = { enabled: false };
  const source = fs.realpathSync(path.resolve(path.dirname(configPath), input.main ?? ''));
  if (!inside(source, fs.realpathSync(repo)) || !fs.statSync(source).isFile()) fail('Worker entry point must belong to this source repository.');
  config.main = source;
  const migration = fs.realpathSync(path.resolve(path.dirname(configPath), input.d1_databases[0].migrations_dir ?? 'migrations'));
  if (!inside(migration, fs.realpathSync(repo)) || !fs.statSync(migration).isDirectory()) fail('Migrations must belong to this source repository.');
  config.d1_databases[0].migrations_dir = migration;
  if (config.assets) {
    if (Object.keys(config.assets).some(key => !['directory', 'binding', 'run_worker_first', 'not_found_handling', 'html_handling'].includes(key))) fail('Unexpected assets configuration needs separate review.');
    const assets = canonicalProspective(path.resolve(path.dirname(configPath), config.assets.directory ?? ''));
    if (!inside(assets, fs.realpathSync(repo))) fail('Console assets must belong to this source repository.'); config.assets.directory = assets;
  }
  if (config.vars && Object.keys(config.vars).some(key => SECRET_NAMES.includes(key) || key === 'CLIENTS_JSON')) fail('Secrets must not be placed in configuration vars.');
  config.vars = { ...config.vars, BRAIN_ENABLED: 'true' };
  const origin = config.vars.PUBLIC_ORIGIN;
  if (typeof origin !== 'string') fail('Set PUBLIC_ORIGIN to the existing Worker HTTPS origin first.');
  let parsed; try { parsed = new URL(origin); } catch { fail('Set PUBLIC_ORIGIN to the existing Worker HTTPS origin first.'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.origin !== origin || parsed.search || parsed.hash) fail('PUBLIC_ORIGIN must be an HTTPS origin without credentials or a path.');
  const directory = requireOutsideGit(options.privateDir ?? path.join(os.homedir(), 'Library/Application Support/CloudNest/BrainSetup', crypto.randomUUID()), repo);
  if (fs.existsSync(directory)) fail('Choose a new private setup directory; existing files are never overwritten.');
  return { repo, directory, config, client: { client_id: installed.client_id, client_secret: installed.client_secret }, worker: config.name, origin, manualBrowser: options.manualBrowser === true || options['manual-browser'] === true };
}

export async function loopbackAuthorization({ timeoutMs = 180000 } = {}) {
  const state = crypto.randomBytes(32).toString('base64url'), verifier = crypto.randomBytes(48).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  let resolve, reject, settled = false, timer;
  const code = new Promise((yes, no) => { resolve = yes; reject = no; }); code.catch(() => {});
  const finish = (error, value) => {
    if (settled) return; settled = true; clearTimeout(timer); server.close();
    // close() stops listening but an incomplete/idle HTTP peer can otherwise
    // retain the process. Allow the small success page to flush, then bound all
    // socket lifetimes, including requests with incomplete headers.
    const shutdown = setTimeout(() => server.closeAllConnections(), 250); shutdown.unref();
    if (error) reject(error); else resolve(value);
  };
  const server = http.createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store'); response.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'"); response.setHeader('Content-Type', 'text/plain; charset=utf-8');
    const address = server.address();
    if (settled || !address) { response.writeHead(400).end('Authorization session ended.'); return; }
    const expectedHost = '127.0.0.1:' + address.port;
    let url; try { url = new URL(request.url, 'http://' + expectedHost); } catch { response.writeHead(400).end('Invalid callback.'); return; }
    if (request.method !== 'GET' || (request.url?.length ?? 0) > 8192 || request.headers.host !== expectedHost || request.socket.remoteAddress !== '127.0.0.1' || url.origin !== 'http://' + expectedHost || url.pathname !== '/callback' || (request.headers.origin && request.headers.origin !== 'http://' + expectedHost) || url.searchParams.getAll('state').length !== 1 || url.searchParams.get('state') !== state) { response.writeHead(400).end('Invalid callback.'); return; }
    if (url.searchParams.get('error') && !url.searchParams.has('code')) { response.writeHead(400).end('Authorization was not completed.'); finish(new SetupError('Google authorization was declined; no grant was saved.')); return; }
    const values = url.searchParams.getAll('code');
    if (values.length !== 1 || !values[0] || values[0].length > 4096 || url.searchParams.has('error')) { response.writeHead(400).end('Invalid callback.'); return; }
    response.writeHead(200).end('CloudNest Brain authorization received. Return to Terminal to finish preparing your private setup.'); finish(null, values[0]);
  });
  server.headersTimeout = 5000; server.requestTimeout = 5000; server.keepAliveTimeout = 1000;
  server.maxConnections = 8; server.maxHeadersCount = 32;
  await new Promise((yes, no) => { server.once('error', no); server.listen(0, '127.0.0.1', yes); });
  timer = setTimeout(() => finish(new SetupError('Google authorization timed out; rerun setup when ready.')), timeoutMs); timer.unref();
  return { state, verifier, challenge, redirectURI: 'http://127.0.0.1:' + server.address().port + '/callback', code, close: () => finish(new SetupError('Authorization cancelled.')) };
}
export async function obtainGrant(client, { openBrowser = url => new Promise((yes, no) => execFile('/usr/bin/open', [url], error => error ? no(new SetupError('The browser could not open. Rerun setup from your Mac.')) : yes())), fetchImpl = fetch, timeoutMs } = {}) {
  const callback = await loopbackAuthorization({ timeoutMs });
  try {
    const parameters = new URLSearchParams({ client_id: client.client_id, redirect_uri: callback.redirectURI, response_type: 'code', scope: SCOPE, access_type: 'offline', prompt: 'consent', state: callback.state, code_challenge: callback.challenge, code_challenge_method: 'S256' });
    await openBrowser('https://accounts.google.com/o/oauth2/v2/auth?' + parameters);
    const code = await callback.code;
    const response = await fetchImpl('https://oauth2.googleapis.com/token', { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30000), headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: client.client_id, client_secret: client.client_secret, code, code_verifier: callback.verifier, redirect_uri: callback.redirectURI, grant_type: 'authorization_code' }) });
    if (!response.ok) fail('Google token exchange failed. No provider response or authorization code was printed.');
    const reader = response.body.getReader(); let data = '', bytes = 0;
    for (;;) { const next = await reader.read(); if (next.done) break; bytes += next.value.length; if (bytes > 65536) { await reader.cancel(); fail('Google token response exceeded the safety limit.'); } data += Buffer.from(next.value).toString('utf8'); }
    let token; try { token = JSON.parse(data); } catch { fail('Google token response was invalid.'); }
    if (typeof token.refresh_token !== 'string' || token.refresh_token.length < 8 || token.refresh_token.length > 8192) fail('Google did not provide an offline refresh grant. Use a dedicated Desktop client and consent again.');
    if (typeof token.scope !== 'string' || token.scope.split(/\s+/).filter(Boolean).some(scope => scope !== SCOPE) || !token.scope.split(/\s+/).includes(SCOPE)) fail('The returned Google grant has unexpected scopes; setup stopped.');
    return token.refresh_token;
  } finally { callback.close(); }
}
export async function prepare(plan, authorization = obtainGrant) {
  fs.mkdirSync(path.dirname(plan.directory), { recursive: true, mode: 0o700 });
  requireOutsideGit(plan.directory, plan.repo); fs.mkdirSync(plan.directory, { mode: 0o700 });
  writePrivate(path.join(plan.directory, '.gitignore'), '*\n');
  const browserOptions = plan.manualBrowser ? { openBrowser: async url => {
    if (privateDirectory(plan.directory, plan.repo) !== plan.directory) fail('Private directory changed before browser handoff.');
    const target = new URL(url);
    if (target.origin !== 'https://accounts.google.com' || target.pathname !== '/o/oauth2/v2/auth' || target.username || target.password) fail('Unexpected authorization browser destination.');
    const file = path.join(plan.directory, 'authorization.private.url'); writePrivate(file, url + '\n');
    console.log('Open the authorization URL from this private file using your browser: ' + file);
  } } : undefined;
  const refresh = await authorization(plan.client, browserOptions), owner = crypto.randomBytes(32).toString('base64url');
  if (privateDirectory(plan.directory, plan.repo) !== plan.directory) fail('Private directory changed during authorization; no grant was saved.');
  const ownerHash = sha(owner); let signingKey;
  do { signingKey = crypto.randomBytes(32).toString('hex'); } while (signingKey === ownerHash);
  const secrets = { GOOGLE_CLIENT_ID: plan.client.client_id, GOOGLE_CLIENT_SECRET: plan.client.client_secret, GOOGLE_REFRESH_TOKEN: refresh, OWNER_TOKEN_SHA256: ownerHash, VAULT_SIGNING_KEY: signingKey };
  writePrivate(path.join(plan.directory, 'secrets.private.json'), secrets);
  writePrivate(path.join(plan.directory, 'owner-token.private.txt'), owner + '\n');
  writePrivate(path.join(plan.directory, 'connection.private.json'), { schemaVersion: 1, baseURL: plan.origin, ownerToken: owner });
  writePrivate(path.join(plan.directory, 'wrangler.private.json'), plan.config);
  writePrivate(path.join(plan.directory, 'setup.private.json'), { schemaVersion: 1, worker: plan.worker, configurationSHA256: sha(JSON.stringify(plan.config)), createdAt: new Date().toISOString() });
  const fd = fs.openSync(plan.directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  return path.join(plan.directory, 'setup.private.json');
}
function privateDirectory(directory, repo) {
  const resolved = requireOutsideGit(directory, repo), metadata = fs.lstatSync(directory);
  if (metadata.isSymbolicLink() || !metadata.isDirectory() || (metadata.mode & 0o077) || (process.getuid && metadata.uid !== process.getuid())) fail('Prepared setup directory must be owned by you with mode 700 and no symbolic link.');
  return resolved;
}
export function loadPrepared(file, repo = REPO) {
  const directory = privateDirectory(path.dirname(file), repo);
  if (path.basename(file) !== 'setup.private.json') fail('Pass the generated setup.private.json manifest.');
  const read = name => JSON.parse(readBounded(path.join(directory, name), { privateFile: true }));
  const manifest = read('setup.private.json'), config = read('wrangler.private.json'), secrets = read('secrets.private.json');
  if (manifest.schemaVersion !== 1 || manifest.worker !== config.name || manifest.configurationSHA256 !== sha(JSON.stringify(config)) || config.vars?.BRAIN_ENABLED !== 'true' || !/^[a-f0-9]{32}$/i.test(config.account_id ?? '')) fail('Prepared configuration changed; prepare a new reviewed bundle.');
  if (Object.keys(secrets).sort().join() !== SECRET_NAMES.join() || Object.values(secrets).some(value => typeof value !== 'string' || !value.length) || !/^[a-f0-9]{64}$/.test(secrets.OWNER_TOKEN_SHA256) || !/^[a-f0-9]{64}$/.test(secrets.VAULT_SIGNING_KEY) || secrets.VAULT_SIGNING_KEY === secrets.OWNER_TOKEN_SHA256) fail('Prepared secrets are incomplete or contain unexpected keys.');
  for (const source of [config.main, config.d1_databases?.[0]?.migrations_dir, config.assets?.directory].filter(Boolean)) if (!path.isAbsolute(source) || !inside(canonicalProspective(source), fs.realpathSync(repo))) fail('Prepared source paths no longer belong to this repository. Prepare a new reviewed bundle.');
  const owner = readBounded(path.join(directory, 'owner-token.private.txt'), { privateFile: true }).trim();
  if (sha(owner) !== secrets.OWNER_TOKEN_SHA256) fail('Owner token does not match its prepared verifier.');
  let journal = {};
  if (fs.existsSync(path.join(directory, 'deployment.private.json'))) journal = read('deployment.private.json');
  if (Object.keys(journal).length && (journal.schemaVersion !== 1 || journal.worker !== manifest.worker || journal.configurationSHA256 !== manifest.configurationSHA256)) fail('Deployment journal belongs to a different setup bundle. No remote changes were attempted.');
  if (Object.keys(journal).length && journal.secretBundleSHA256 !== sha(JSON.stringify(secrets))) {
    // A confirmed renewal can be interrupted between two local atomic writes.
    // Accept only its exact staged transition so renewal can finish locally.
    const pending = readRenewal({ directory, manifest, secrets, repo });
    if (pending?.state !== 'uploaded' || pending.beforeSHA256 !== journal.secretBundleSHA256 || pending.afterSHA256 !== sha(JSON.stringify(secrets))) fail('Deployment journal belongs to a different setup bundle. No remote changes were attempted.');
  }
  return { directory, manifest, config, secrets, journal, repo };
}
// Renewal changes only one existing secret. These files remain local and never
// enter manifests, API URLs, command arguments, or the remote memory index.
const RENEWAL_FILE = 'google-renewal.private.json';
const ACCOUNT_FILE = 'google-account.private.json';
const immutableSecrets = secrets => sha(JSON.stringify(SECRET_NAMES.filter(name => name !== 'GOOGLE_REFRESH_TOKEN').map(name => [name, secrets[name]])));
const frozenNames = ['setup.private.json', 'wrangler.private.json', 'owner-token.private.txt', 'connection.private.json'];
const privateJSON = (directory, name) => JSON.parse(readBounded(path.join(directory, name), { privateFile: true }));
function replacePrivate(directory, name, value) {
  const target = path.join(directory, name);
  if (fs.existsSync(target)) readBounded(target, { privateFile: true });
  const temporary = path.join(directory, '.replacement-' + crypto.randomUUID());
  try { writePrivate(temporary, value); fs.renameSync(temporary, target); const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); } }
  finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
}
function setupLease(directory) {
  directory = privateDirectory(directory, REPO);
  const file = path.join(directory, 'setup-operation.private.lock');
  let fd; try { fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600); }
  catch { fail('Another setup operation or an interrupted operation owns this bundle. Inspect its private lock locally before continuing.'); }
  const identity = fs.fstatSync(fd);
  try { fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString() })); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  return () => { const current = fs.lstatSync(file); if (current.dev !== identity.dev || current.ino !== identity.ino) fail('Setup operation lock changed; inspect the private bundle.'); fs.unlinkSync(file); };
}
async function responseJSON(response, failure) {
  if (!response.ok || !response.body) fail(failure);
  const reader = response.body.getReader(); const chunks = []; let bytes = 0;
  for (;;) { const next = await reader.read(); if (next.done) break; bytes += next.value.length; if (bytes > 65536) { await reader.cancel(); fail(failure); } chunks.push(Buffer.from(next.value)); }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, bytes))); } catch { fail(failure); }
}
async function googleAccountHash(client, refresh, fetchImpl) {
  let token, about;
  try {
    token = await responseJSON(await fetchImpl('https://oauth2.googleapis.com/token', { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30000), headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: client.client_id, client_secret: client.client_secret, refresh_token: refresh, grant_type: 'refresh_token' }) }), 'The Google grant could not verify its Drive account.');
    if (typeof token.access_token !== 'string' || token.access_token.length < 8 || token.access_token.length > 16384 || /[\r\n\0]/.test(token.access_token) || (token.scope !== undefined && (typeof token.scope !== 'string' || token.scope.split(/\s+/).filter(Boolean).join(' ') !== SCOPE))) fail('The Google grant returned an unexpected access scope or token.');
    const url = new URL('https://www.googleapis.com/drive/v3/about'); url.searchParams.set('fields', 'user(permissionId)');
    about = await responseJSON(await fetchImpl(url.href, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(30000), headers: { Authorization: 'Bearer ' + token.access_token } }), 'The Google Drive account identity could not be verified.');
  } catch (error) { if (error instanceof SetupError) throw error; fail('Google account verification failed. No provider response or credential was printed.'); }
  const permission = about?.user?.permissionId;
  if (typeof permission !== 'string' || !/^[A-Za-z0-9_-]{1,256}$/.test(permission)) fail('Google Drive did not return a usable account identity.');
  return sha('CloudNest Drive account v1\n' + permission);
}
function accountBinding(prepared) {
  const file = path.join(prepared.directory, ACCOUNT_FILE); if (!fs.existsSync(file)) return null;
  const { signature, ...binding } = privateJSON(prepared.directory, ACCOUNT_FILE);
  const expected = crypto.createHmac('sha256', Buffer.from(prepared.secrets.VAULT_SIGNING_KEY, 'hex')).update(JSON.stringify(binding)).digest('hex');
  if (binding.schemaVersion !== 1 || binding.worker !== prepared.manifest.worker || binding.configurationSHA256 !== prepared.manifest.configurationSHA256 || binding.clientSHA256 !== sha(prepared.secrets.GOOGLE_CLIENT_ID) || !/^[a-f0-9]{64}$/.test(binding.accountSHA256 ?? '') || typeof signature !== 'string' || !/^[a-f0-9]{64}$/.test(signature) || !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) fail('The private Google account binding does not match this existing Brain.');
  return binding.accountSHA256;
}
function readRenewal(prepared) {
  const file = path.join(prepared.directory, RENEWAL_FILE); if (!fs.existsSync(file)) return null;
  const value = privateJSON(prepared.directory, RENEWAL_FILE);
  if (value.schemaVersion !== 1 || value.worker !== prepared.manifest.worker || value.configurationSHA256 !== prepared.manifest.configurationSHA256 || value.immutableSHA256 !== immutableSecrets(prepared.secrets) || !['awaiting-consent', 'prepared', 'upload-started', 'uploaded', 'completed', 'cancelled'].includes(value.state) || !/^grant-renewal-[a-f0-9-]{36}$/.test(value.candidate ?? '') || !/^[a-f0-9]{64}$/.test(value.beforeSHA256 ?? '') || !/^[a-f0-9]{64}$/.test(value.accountSHA256 ?? '') || !value.frozen || frozenNames.some(name => !/^[a-f0-9]{64}$/.test(value.frozen[name] ?? ''))) fail('Google renewal journal does not belong to this unchanged Brain bundle.');
  return value;
}
function completeRenewal(prepared, renewal) {
  if (renewal.state !== 'uploaded') fail('Renewal upload has not been confirmed; local credentials were not replaced.');
  if (frozenNames.some(name => sha(readBounded(path.join(prepared.directory, name), { privateFile: true })) !== renewal.frozen[name])) fail('An immutable prepared file changed during renewal; no local credentials were replaced.');
  const folder = path.join(prepared.directory, renewal.candidate);
  privateDirectory(folder, prepared.repo);
  const candidate = privateJSON(folder, 'secrets.private.json'), digest = sha(JSON.stringify(candidate));
  if (digest !== renewal.afterSHA256 || immutableSecrets(candidate) !== renewal.immutableSHA256 || Object.keys(candidate).sort().join() !== SECRET_NAMES.join() || ![renewal.beforeSHA256, renewal.afterSHA256].includes(sha(JSON.stringify(prepared.secrets)))) fail('The staged renewal changed unexpectedly; inspect its private files.');
  replacePrivate(prepared.directory, 'secrets.private.json', candidate);
  saveJournal(prepared.directory, { ...prepared.journal, secretBundleSHA256: digest, googleGrantRenewedAt: new Date().toISOString() });
  replacePrivate(prepared.directory, RENEWAL_FILE, { ...renewal, state: 'completed', completedAt: new Date().toISOString() });
  return loadPrepared(path.join(prepared.directory, 'setup.private.json'), prepared.repo);
}
export async function renewGoogleGrant(prepared, confirmedWorker, { authorization = obtainGrant, fetchImpl = fetch, run = runPrivate, manualBrowser = false } = {}) {
  if (confirmedWorker !== prepared.manifest.worker) fail('Google renewal requires --confirm-worker matching the existing prepared Worker.');
  const release = setupLease(prepared.directory);
  try {
    prepared = loadPrepared(path.join(prepared.directory, 'setup.private.json'), prepared.repo);
    if (!prepared.journal.secretsUploaded) fail('Renewal requires the existing deployed Brain bundle; it never initializes new Brain secrets.');
    const pending = readRenewal(prepared);
    if (pending?.state === 'uploaded') return completeRenewal(prepared, pending);
    if (pending && !['completed', 'cancelled'].includes(pending.state)) fail('A previous Google renewal is incomplete or its upload result is uncertain. No new grant was uploaded. Inspect the private journal and staged grant locally; automatic replacement is refused.');
    const wrangler = path.join(prepared.repo, 'node_modules/wrangler/bin/wrangler.js');
    if (!fs.existsSync(wrangler)) fail('Install the pinned Wrangler dependency first.');
    const cli = (args, label, input = '') => run(process.execPath, [wrangler, ...args, '--config', path.join(prepared.directory, 'wrangler.private.json')], prepared.directory, label, { input, cwd: prepared.repo });
    let deployments, names;
    try { deployments = JSON.parse(await cli(['deployments', 'list', '--name', confirmedWorker, '--json'], 'renew-check-worker')); names = JSON.parse(await cli(['secret', 'list', '--name', confirmedWorker], 'renew-check-secret-names')); }
    catch { fail('The existing Worker and secret names could not be verified; no Google grant was uploaded.'); }
    if (!Array.isArray(deployments) || !deployments.length || !Array.isArray(names) || names.some(entry => !entry || typeof entry.name !== 'string') || SECRET_NAMES.some(name => !names.some(entry => entry.name === name))) fail('The existing Brain Worker or required secret names are missing; renewal will not initialize or replace other secrets.');
    const client = { client_id: prepared.secrets.GOOGLE_CLIENT_ID, client_secret: prepared.secrets.GOOGLE_CLIENT_SECRET };
    let expected = accountBinding(prepared), live;
    try { live = await googleAccountHash(client, prepared.secrets.GOOGLE_REFRESH_TOKEN, fetchImpl); }
    catch { if (!expected) fail('The old Google grant cannot verify its account and no trusted private account binding exists. Renewal stopped before consent or upload. Recover the original account binding first.'); }
    if (live && expected && live !== expected) fail('The current Google grant disagrees with the trusted account binding. No new grant was uploaded.');
    expected ??= live;
    if (!expected) fail('The existing Drive account could not be bound safely.');
    if (!fs.existsSync(path.join(prepared.directory, ACCOUNT_FILE))) {
      const binding = { schemaVersion: 1, worker: confirmedWorker, configurationSHA256: prepared.manifest.configurationSHA256, clientSHA256: sha(client.client_id), accountSHA256: expected, verifiedAt: new Date().toISOString() };
      const signature = crypto.createHmac('sha256', Buffer.from(prepared.secrets.VAULT_SIGNING_KEY, 'hex')).update(JSON.stringify(binding)).digest('hex');
      writePrivate(path.join(prepared.directory, ACCOUNT_FILE), { ...binding, signature });
    }
    const candidate = 'grant-renewal-' + crypto.randomUUID(), folder = path.join(prepared.directory, candidate);
    fs.mkdirSync(folder, { mode: 0o700 }); writePrivate(path.join(folder, '.gitignore'), '*\n');
    let renewal = { schemaVersion: 1, worker: confirmedWorker, configurationSHA256: prepared.manifest.configurationSHA256, immutableSHA256: immutableSecrets(prepared.secrets), beforeSHA256: sha(JSON.stringify(prepared.secrets)), accountSHA256: expected, candidate, state: 'awaiting-consent', createdAt: new Date().toISOString(), frozen: Object.fromEntries(frozenNames.map(name => [name, sha(readBounded(path.join(prepared.directory, name), { privateFile: true }))])) };
    replacePrivate(prepared.directory, RENEWAL_FILE, renewal);
    try {
      const options = manualBrowser ? { openBrowser: async value => {
        privateDirectory(folder, prepared.repo);
        const url = new URL(value);
        if (url.origin !== 'https://accounts.google.com' || url.pathname !== '/o/oauth2/v2/auth' || url.username || url.password) fail('Unexpected authorization browser destination.');
        const file = path.join(folder, 'authorization.private.url'); writePrivate(file, value + '\n');
        console.log('Open the Google renewal authorization URL from this private file: ' + file);
      } } : undefined;
      const refresh = await authorization(client, options);
      if (typeof refresh !== 'string' || refresh.length < 8 || refresh.length > 8192 || /[\r\n\0]/.test(refresh)) fail('The new Google offline grant is invalid; nothing was uploaded.');
      const account = await googleAccountHash(client, refresh, fetchImpl);
      if (account !== expected) fail('A different Google Drive account was selected. The existing Brain and its credentials were preserved; no new grant was uploaded.');
      const current = loadPrepared(path.join(prepared.directory, 'setup.private.json'), prepared.repo);
      if (sha(JSON.stringify(current.secrets)) !== renewal.beforeSHA256 || frozenNames.some(name => sha(readBounded(path.join(prepared.directory, name), { privateFile: true })) !== renewal.frozen[name])) fail('The prepared Brain changed during consent; no grant was uploaded.');
      const secrets = { ...prepared.secrets, GOOGLE_REFRESH_TOKEN: refresh };
      writePrivate(path.join(folder, 'secrets.private.json'), secrets);
      renewal = { ...renewal, state: 'prepared', afterSHA256: sha(JSON.stringify(secrets)) }; replacePrivate(prepared.directory, RENEWAL_FILE, renewal);
      renewal = { ...renewal, state: 'upload-started' }; replacePrivate(prepared.directory, RENEWAL_FILE, renewal);
      await cli(['secret', 'put', 'GOOGLE_REFRESH_TOKEN', '--name', confirmedWorker], 'renew-google-refresh-token', refresh + '\n');
      renewal = { ...renewal, state: 'uploaded', uploadedAt: new Date().toISOString() }; replacePrivate(prepared.directory, RENEWAL_FILE, renewal);
      return completeRenewal(prepared, renewal);
    } catch (error) {
      if (['awaiting-consent', 'prepared'].includes(renewal.state)) replacePrivate(prepared.directory, RENEWAL_FILE, { ...renewal, state: 'cancelled', cancelledAt: new Date().toISOString() });
      throw error;
    }
  } finally { release(); }
}

/** Capture machine-readable stdout separately; provider diagnostics stay private.
 * Only this owned child's process group is stopped on a deadline or budget error.
 * A failed/uncertain command never returns output as successful deployment evidence. */
export function runPrivate(command, args, directory, label, { input = '', cwd = REPO, maximumBytes = 2_097_152, timeoutMs = 180_000 } = {}) {
  return new Promise((resolve, reject) => {
    if (!/^[a-z][a-z0-9-]{0,79}$/.test(label) || !Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 2_097_152 || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 600_000) fail('Invalid private subprocess limits or label.');
    directory = privateDirectory(directory, REPO);
    const log = path.join(directory, label + '-' + crypto.randomUUID() + '.private.log');
    const fd = fs.openSync(log, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    const chunks = []; let stdoutBytes = 0, logBytes = 0, failure, child, settled = false, childClosed = false, deadline, killTimer, drainTimer;
    const clearTimers = () => { clearTimeout(deadline); clearTimeout(killTimer); clearTimeout(drainTimer); };
    const signalOwned = signal => {
      if (!child?.pid || childClosed || settled) return;
      try {
        if (process.platform === 'win32') child.kill(signal);
        else process.kill(-child.pid, signal);
      } catch { /* A process that already exited needs no further signal. */ }
    };
    const finish = (status, signal) => {
      if (settled) return; settled = true; clearTimers();
      try { fs.fsyncSync(fd); } catch { failure ??= new SetupError('Private diagnostic persistence failed; the setup result is uncertain. Inspect the prepared bundle before retrying.'); }
      try { fs.closeSync(fd); } catch { failure ??= new SetupError('Private diagnostic closure failed; the setup result is uncertain.'); }
      if (failure) { reject(failure); return; }
      if (status !== 0 || signal) { reject(new SetupError('Setup command failed at ' + label + '. Inspect its private log locally; never upload that log.')); return; }
      try { resolve(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, stdoutBytes))); }
      catch { reject(new SetupError('Setup command returned invalid UTF-8 at ' + label + '. No successful result was accepted.')); }
    };
    const stop = error => {
      if (settled || failure) return;
      failure = error; clearTimeout(deadline);
      signalOwned('SIGTERM');
      killTimer = setTimeout(() => signalOwned('SIGKILL'), 250);
      // Grandchildren can retain pipe descriptors. The owned group receives
      // SIGKILL first; draining is then bounded independently of those peers.
      drainTimer = setTimeout(() => {
        child?.stdin.destroy(); child?.stdout.destroy(); child?.stderr.destroy();
        finish(null, null);
      }, 1250);
      killTimer.unref(); drainTimer.unref();
    };
    const consume = (value, stdout) => {
      if (settled || failure) return;
      const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
      const remaining = Math.max(0, maximumBytes - logBytes);
      try {
        let offset = 0, count = Math.min(remaining, chunk.length);
        while (offset < count) {
          const written = fs.writeSync(fd, chunk, offset, count - offset);
          if (written <= 0) throw new Error('Incomplete private log write');
          offset += written; logBytes += written;
        }
      } catch { stop(new SetupError('Private diagnostics could not be retained; the setup result is uncertain. Inspect the prepared bundle before retrying.')); return; }
      if (chunk.length > remaining || (stdout && stdoutBytes + chunk.length > maximumBytes)) {
        stop(new SetupError('Setup output exceeded the private diagnostic budget at ' + label + '. The command was stopped; its remote result is uncertain.')); return;
      }
      if (stdout) { chunks.push(chunk); stdoutBytes += chunk.length; }
    };
    try {
      child = spawn(command, args, { cwd, detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG: 'log', NO_COLOR: '1', CI: 'true' } });
      child.stdout.on('data', chunk => consume(chunk, true));
      child.stderr.on('data', chunk => consume(chunk, false));
      child.stdout.on('error', () => stop(new SetupError('Subprocess output could not be confirmed; the setup result is uncertain.')));
      child.stderr.on('error', () => stop(new SetupError('Subprocess diagnostics could not be confirmed; the setup result is uncertain.')));
      child.stdin.on('error', () => stop(new SetupError('Subprocess input could not be confirmed; the setup result is uncertain.')));
      child.once('error', () => stop(new SetupError('A setup subprocess could not start. Private diagnostic logs were retained.')));
      child.once('close', (status, signal) => { childClosed = true; finish(status, signal); });
      deadline = setTimeout(() => stop(new SetupError('Setup command exceeded its deadline at ' + label + '. The owned subprocess was stopped; its remote result is uncertain. Inspect the prepared bundle before retrying.')), timeoutMs);
      child.stdin.end(input);
    } catch { failure = new SetupError('A setup subprocess could not start. Private diagnostic logs were retained.'); finish(null, null); }
  });
}

export async function deployPrepared(prepared, confirmedWorker, run = runPrivate) {
  const { directory, manifest, repo, secrets } = prepared;
  if (confirmedWorker !== manifest.worker) fail('Deployment requires --confirm-worker matching the reviewed Worker name.');
  const release = setupLease(directory);
  try {
  const pendingRenewal = readRenewal(prepared);
  if (pendingRenewal && !['completed', 'cancelled'].includes(pendingRenewal.state)) fail('An incomplete Google renewal must be resolved before deploying this bundle.');
  const wrangler = path.join(repo, 'node_modules/wrangler/bin/wrangler.js');
  if (!fs.existsSync(wrangler) || !fs.existsSync(path.join(repo, 'scripts/build-console.mjs'))) fail('Install pinned dependencies with npm ci and ensure the console build script exists first.');
  const configPath = path.join(directory, 'wrangler.private.json');
  const journal = state => saveJournal(directory, { schemaVersion: 1, worker: manifest.worker, configurationSHA256: manifest.configurationSHA256, secretBundleSHA256: sha(JSON.stringify(secrets)), ...state });
  const cli = (args, label, input = '') => run(process.execPath, [wrangler, ...args, '--config', configPath], directory, label, { input, cwd: repo });
  let deployments; try { deployments = JSON.parse(await cli(['deployments', 'list', '--name', manifest.worker, '--json'], 'check-existing-worker')); } catch { fail('Could not verify an existing Worker. Sign in to Wrangler separately; setup will not create a Worker.'); }
  if (!Array.isArray(deployments) || deployments.length === 0) fail('No existing deployed Worker was verified. No secrets were uploaded.');
  let names; try { names = JSON.parse(await cli(['secret', 'list', '--name', manifest.worker], 'check-existing-secret-names')); } catch { fail('Could not verify existing secret names; no secrets were uploaded.'); }
  if (!Array.isArray(names) || names.some(entry => typeof entry.name !== 'string')) fail('Unexpected secret list; no secrets were uploaded.');
  if (!prepared.journal.secretsUploaded) {
    if (names.some(entry => SECRET_NAMES.includes(entry.name))) fail('This Worker already has Brain credentials or a vault signing key. Setup refuses to replace them. Recover the existing private bundle; do not regenerate the signing key.');
    journal({ secretsUploadStarted: true, secretsUploaded: false });
    await cli(['secret', 'bulk', '--name', manifest.worker], 'upload-new-brain-secrets', JSON.stringify(secrets));
    journal({ secretsUploaded: true });
  } else if (SECRET_NAMES.some(key => !names.some(entry => entry.name === key))) fail('Previously uploaded secrets are missing; inspect the Worker before retrying.');
  await cli(['d1', 'migrations', 'apply', 'DB', '--remote'], 'apply-existing-database-migrations');
  await run(process.execPath, [path.join(repo, 'scripts/build-console.mjs')], directory, 'build-console', { cwd: repo });
  await cli(['deploy', '--name', manifest.worker, '--no-autoconfig', '--strict'], 'deploy-existing-worker');
  journal({ secretsUploaded: true, deployedAt: new Date().toISOString() });
  } finally { release(); }
}

export async function main(args = process.argv.slice(2)) {
  const options = {}; const keys = { '--oauth-client': 'oauthClient', '--config': 'config', '--private-dir': 'privateDir', '--prepared': 'prepared', '--confirm-worker': 'confirmWorker' };
  for (let i = 0; i < args.length; i++) {
    if (keys[args[i]]) { if (!args[i + 1] || args[i + 1].startsWith('--')) fail('Missing setup argument.'); options[keys[args[i]]] = args[++i]; }
    else if (['--dry-run', '--validate', '--deploy', '--help', '--manual-browser', '--renew-google-grant'].includes(args[i])) options[args[i].slice(2)] = true;
    else fail('Unknown setup argument. Use --help.');
  }
  if (options.help) { console.log('Prepare only: node scripts/setup-brain.mjs --oauth-client /absolute/Desktop-client.json [--config /absolute/wrangler.local.jsonc] [--private-dir /absolute/new-private-directory] [--dry-run] [--manual-browser]\nDeploy separately: node scripts/setup-brain.mjs --deploy --prepared /absolute/private/setup.private.json --confirm-worker cloudnest-brain\nRenew existing Google grant: node scripts/setup-brain.mjs --renew-google-grant --prepared /absolute/private/setup.private.json --confirm-worker cloudnest-brain [--manual-browser]\nNever paste tokens into Terminal commands or chat. Deployment uses only the existing Worker and D1.'); return; }
  if (options['renew-google-grant']) {
    if (!options.prepared || options.oauthClient || options.config || options.privateDir || options.deploy) fail('Renewal requires only an existing --prepared bundle, matching --confirm-worker, and optional --manual-browser.');
    const prepared = loadPrepared(options.prepared);
    if (options.confirmWorker !== prepared.manifest.worker) fail('Google renewal requires --confirm-worker matching the existing prepared Worker.');
    if (options['dry-run'] || options.validate) { console.log('Validated existing renewal recipient. No consent, account lookups, uploads, or local credential changes performed.'); return; }
    console.log('Renewing only the existing Brain Google refresh grant. Owner identity, signing key, client, configuration, and AI registrations are preserved.');
    await renewGoogleGrant(prepared, options.confirmWorker, { manualBrowser: options['manual-browser'] === true });
    console.log('Google refresh grant renewed for the same Drive account. Existing owner connection files remain valid. Verify live memory and MCP retrieval separately.'); return;
  }
  if (options.deploy) {
    if (!options.prepared || options.oauthClient || options['manual-browser']) fail('Deploy requires an existing --prepared bundle and no new OAuth input.');
    const prepared = loadPrepared(options.prepared);
    console.log('Reviewed recipient Worker: ' + prepared.manifest.worker + '; configured account fingerprint: ' + sha(prepared.config.account_id).slice(0, 12) + '. Existing client registrations remain untouched.');
    if (options['dry-run'] || options.validate) { console.log('Validated prepared bundle. No authentication, uploads, migrations, or deployment performed.'); return; }
    await deployPrepared(prepared, options.confirmWorker); console.log('Deployment completed. Live memory and MCP acceptance checks are still required.'); return;
  }
  const plan = resolvePlan(options);
  console.log('Recipient Worker: ' + plan.worker + '; configured account fingerprint: ' + sha(plan.config.account_id).slice(0, 12) + '. A NEW Drive file-only offline grant, owner verifier, and vault signing key will be prepared outside Git.');
  if (options['dry-run'] || options.validate) { console.log('Inputs validated. No files written, browser opened, secrets uploaded, or deployment performed.'); return; }
  console.log(plan.manualBrowser ? 'Manual browser handoff selected. A private authorization URL file will be created; CloudNest Storage credentials are never read.' : 'Complete Google consent in your browser. CloudNest Storage credentials are never read.');
  const prepared = await prepare(plan);
  console.log('Private setup prepared at: ' + prepared + '\nNo secrets were uploaded. Review the private configuration, then invoke --deploy with --confirm-worker explicitly. Keep the vault signing key for recovery.');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error instanceof SetupError ? error.message : 'Setup failed. Check your input paths and permissions. No credential values were printed.'); process.exitCode = 1; });
