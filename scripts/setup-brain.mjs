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
  return { repo, directory, config, client: { client_id: installed.client_id, client_secret: installed.client_secret }, worker: config.name, origin };
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
  const refresh = await authorization(plan.client), owner = crypto.randomBytes(32).toString('base64url');
  if (privateDirectory(plan.directory, plan.repo) !== plan.directory) fail('Private directory changed during authorization; no grant was saved.');
  const secrets = { GOOGLE_CLIENT_ID: plan.client.client_id, GOOGLE_CLIENT_SECRET: plan.client.client_secret, GOOGLE_REFRESH_TOKEN: refresh, OWNER_TOKEN_SHA256: sha(owner), VAULT_SIGNING_KEY: crypto.randomBytes(32).toString('base64url') };
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
  if (Object.keys(secrets).sort().join() !== SECRET_NAMES.join() || Object.values(secrets).some(value => typeof value !== 'string' || !value.length) || !/^[a-f0-9]{64}$/.test(secrets.OWNER_TOKEN_SHA256) || secrets.VAULT_SIGNING_KEY.length < 32) fail('Prepared secrets are incomplete or contain unexpected keys.');
  for (const source of [config.main, config.d1_databases?.[0]?.migrations_dir, config.assets?.directory].filter(Boolean)) if (!path.isAbsolute(source) || !inside(canonicalProspective(source), fs.realpathSync(repo))) fail('Prepared source paths no longer belong to this repository. Prepare a new reviewed bundle.');
  const owner = readBounded(path.join(directory, 'owner-token.private.txt'), { privateFile: true }).trim();
  if (sha(owner) !== secrets.OWNER_TOKEN_SHA256) fail('Owner token does not match its prepared verifier.');
  let journal = {};
  if (fs.existsSync(path.join(directory, 'deployment.private.json'))) journal = read('deployment.private.json');
  if (Object.keys(journal).length && (journal.schemaVersion !== 1 || journal.worker !== manifest.worker || journal.configurationSHA256 !== manifest.configurationSHA256 || journal.secretBundleSHA256 !== sha(JSON.stringify(secrets)))) fail('Deployment journal belongs to a different setup bundle. No remote changes were attempted.');
  return { directory, manifest, config, secrets, journal, repo };
}
function runPrivate(command, args, directory, label, { input = '', cwd = REPO } = {}) {
  return new Promise((resolve, reject) => {
    const log = path.join(directory, label + '-' + crypto.randomUUID() + '.private.log');
    const fd = fs.openSync(log, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    const child = spawn(command, args, { cwd, stdio: ['pipe', fd, fd], env: { ...process.env, WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG: 'error', NO_COLOR: '1', CI: 'true' } });
    child.stdin.on('error', () => {}); child.stdin.end(input);
    child.once('error', () => { fs.closeSync(fd); reject(new SetupError('A setup subprocess could not start. Private diagnostic logs were retained.')); });
    child.once('exit', status => { fs.closeSync(fd); if (status !== 0) reject(new SetupError('Setup command failed at ' + label + '. Inspect its private log locally; never upload that log.')); else resolve(readBounded(log, { privateFile: true, maximum: 2_097_152 })); });
  });
}
export async function deployPrepared(prepared, confirmedWorker, run = runPrivate) {
  const { directory, manifest, repo, secrets } = prepared;
  if (confirmedWorker !== manifest.worker) fail('Deployment requires --confirm-worker matching the reviewed Worker name.');
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
}

export async function main(args = process.argv.slice(2)) {
  const options = {}; const keys = { '--oauth-client': 'oauthClient', '--config': 'config', '--private-dir': 'privateDir', '--prepared': 'prepared', '--confirm-worker': 'confirmWorker' };
  for (let i = 0; i < args.length; i++) {
    if (keys[args[i]]) { if (!args[i + 1] || args[i + 1].startsWith('--')) fail('Missing setup argument.'); options[keys[args[i]]] = args[++i]; }
    else if (['--dry-run', '--validate', '--deploy', '--help'].includes(args[i])) options[args[i].slice(2)] = true;
    else fail('Unknown setup argument. Use --help.');
  }
  if (options.help) { console.log('Prepare only: node scripts/setup-brain.mjs --oauth-client /absolute/Desktop-client.json [--config /absolute/wrangler.local.jsonc] [--private-dir /absolute/new-private-directory] [--dry-run]\nDeploy separately: node scripts/setup-brain.mjs --deploy --prepared /absolute/private/setup.private.json --confirm-worker cloudnest-brain\nNever paste tokens into Terminal commands or chat. Deployment uses only the existing Worker and D1.'); return; }
  if (options.deploy) {
    if (!options.prepared || options.oauthClient) fail('Deploy requires an existing --prepared bundle and no new OAuth input.');
    const prepared = loadPrepared(options.prepared);
    console.log('Reviewed recipient Worker: ' + prepared.manifest.worker + '; configured account fingerprint: ' + sha(prepared.config.account_id).slice(0, 12) + '. Existing client registrations remain untouched.');
    if (options['dry-run'] || options.validate) { console.log('Validated prepared bundle. No authentication, uploads, migrations, or deployment performed.'); return; }
    await deployPrepared(prepared, options.confirmWorker); console.log('Deployment completed. Live memory and MCP acceptance checks are still required.'); return;
  }
  const plan = resolvePlan(options);
  console.log('Recipient Worker: ' + plan.worker + '; configured account fingerprint: ' + sha(plan.config.account_id).slice(0, 12) + '. A NEW Drive file-only offline grant, owner verifier, and vault signing key will be prepared outside Git.');
  if (options['dry-run'] || options.validate) { console.log('Inputs validated. No files written, browser opened, secrets uploaded, or deployment performed.'); return; }
  console.log('Complete Google consent in your browser. CloudNest Storage credentials are never read.');
  const prepared = await prepare(plan);
  console.log('Private setup prepared at: ' + prepared + '\nNo secrets were uploaded. Review the private configuration, then invoke --deploy with --confirm-worker explicitly. Keep the vault signing key for recovery.');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error instanceof SetupError ? error.message : 'Setup failed. Check your input paths and permissions. No credential values were printed.'); process.exitCode = 1; });
