import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { parseJSONC, requireOutsideGit, resolvePlan, loopbackAuthorization, obtainGrant, prepare, loadPrepared, deployPrepared, renewGoogleGrant, runPrivate, SetupError } from './setup-brain.mjs';

const scriptRepo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scope = 'https://www.googleapis.com/auth/drive.file';
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'cloudnest-setup-test-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true })); // Generated test fixtures only.
  const repo = path.join(base, 'repo'), input = path.join(base, 'input');
  fs.mkdirSync(path.join(repo, '.git'), { recursive: true }); fs.mkdirSync(input);
  fs.mkdirSync(path.join(repo, 'migrations')); fs.mkdirSync(path.join(repo, 'scripts')); fs.mkdirSync(path.join(repo, 'node_modules/wrangler/bin'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'worker.ts'), 'export default {};');
  fs.writeFileSync(path.join(repo, 'scripts/build-console.mjs'), '// Test-only build stub, never executed.');
  fs.writeFileSync(path.join(repo, 'node_modules/wrangler/bin/wrangler.js'), '// Test-only CLI stub, never executed.');
  const client = { client_id: 'unit-client-' + crypto.randomUUID() + '.apps.googleusercontent.com', client_secret: 'test-only-desktop-public-client-value' };
  const oauthClient = path.join(input, 'desktop.json'); fs.writeFileSync(oauthClient, JSON.stringify({ installed: client }));
  const config = path.join(input, 'wrangler.local.jsonc');
  const configuration = { name: 'cloudnest-brain-test', account_id: crypto.randomBytes(16).toString('hex'), main: path.join(repo, 'worker.ts'), compatibility_date: '2026-10-30', d1_databases: [{ binding: 'DB', database_name: 'cloudnest-test', database_id: crypto.randomUUID(), migrations_dir: path.join(repo, 'migrations') }], vars: { PUBLIC_ORIGIN: 'https://brain.example.test', BRAIN_ENABLED: 'false' }, assets: { directory: path.join(repo, 'web/dist'), run_worker_first: true } };
  fs.writeFileSync(config, JSON.stringify(configuration));
  return { base, repo, input, client, options: { oauthClient, config, privateDir: path.join(base, 'private-bundle') }, configuration };
}
const fakeGrant = async () => 'test-only-offline-grant-not-real';
async function requestStatus(input, options) { const response = await fetch(input, options); await response.text(); return response.status; }
async function preparedFixture(t) { const f = fixture(t); const manifest = await prepare(resolvePlan(f.options, f.repo), fakeGrant); return { ...f, manifest, prepared: loadPrepared(manifest, f.repo) }; }

test('JSONC parsing preserves URL and escaped strings and handles comment-adjacent trailing commas', () => {
  assert.deepEqual(parseJSONC('{ // heading\n "url":"https://example.test/a//b", "value":"escaped\\\"/*still string*/", "list":[1, /*end*/ ], /*end*/ }'), { url: 'https://example.test/a//b', value: 'escaped"/*still string*/', list: [1] });
  assert.throws(() => parseJSONC('{ /* unfinished'), SetupError);
});
test('private paths reject every Git ancestor, symlink aliases, and bare repositories', t => {
  const f = fixture(t);
  assert.throws(() => requireOutsideGit(path.join(f.repo, 'private/secrets.json'), f.repo), SetupError);
  const other = path.join(f.base, 'other'); fs.mkdirSync(other); fs.writeFileSync(path.join(other, '.git'), 'gitdir: elsewhere');
  assert.throws(() => requireOutsideGit(path.join(other, 'private'), f.repo), SetupError);
  const alias = path.join(f.base, 'alias'); fs.symlinkSync(other, alias);
  assert.throws(() => requireOutsideGit(path.join(alias, 'private'), f.repo), SetupError);
  const bare = path.join(f.base, 'bare'); fs.mkdirSync(path.join(bare, 'objects'), { recursive: true }); fs.mkdirSync(path.join(bare, 'refs')); fs.writeFileSync(path.join(bare, 'HEAD'), 'ref: refs/heads/main');
  assert.throws(() => requireOutsideGit(path.join(bare, 'private'), f.repo), SetupError);
  assert.equal(requireOutsideGit(path.join(f.base, 'repository-name-lookalike/private'), f.repo), path.join(fs.realpathSync(f.base), 'repository-name-lookalike/private'));
});
test('prepare writes only owner-private new files and a distinct recoverable vault key without client registrations', async t => {
  const f = await preparedFixture(t), p = f.prepared;
  assert.equal(fs.statSync(p.directory).mode & 0o777, 0o700);
  for (const file of fs.readdirSync(p.directory)) assert.equal(fs.statSync(path.join(p.directory, file)).mode & 0o777, 0o600);
  assert.equal(p.config.vars.BRAIN_ENABLED, 'true'); assert.equal(p.config.assets.run_worker_first, true);
  assert.equal(p.secrets.GOOGLE_REFRESH_TOKEN, await fakeGrant()); assert.match(p.secrets.VAULT_SIGNING_KEY, /^[a-f0-9]{64}$/);
  const owner = fs.readFileSync(path.join(p.directory, 'owner-token.private.txt'), 'utf8').trim();
  assert.equal(p.secrets.OWNER_TOKEN_SHA256, crypto.createHash('sha256').update(owner).digest('hex'));
  assert.notEqual(p.secrets.VAULT_SIGNING_KEY, owner); assert.equal(p.secrets.CLIENTS_JSON, undefined);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(p.directory, 'connection.private.json'))), { schemaVersion: 1, baseURL: f.configuration.vars.PUBLIC_ORIGIN, ownerToken: owner });
  assert.throws(() => resolvePlan(f.options, f.repo), /never overwritten/);
});
test('prepared secrets satisfy the real Brain configured contract and invalid signing encodings cannot load', async t => {
  const f = await preparedFixture(t);
  const compiled = await build({ entryPoints: [path.join(scriptRepo, 'brain/memory/drive-vault.ts')], bundle: true, format: 'esm', platform: 'node', write: false });
  const { configured } = await import('data:text/javascript;base64,' + Buffer.from(compiled.outputFiles[0].text).toString('base64'));
  assert.equal(configured({ ...f.prepared.secrets, BRAIN_ENABLED: 'true' }), true);
  const file = path.join(f.prepared.directory, 'secrets.private.json'), original = f.prepared.secrets;
  for (const key of [crypto.randomBytes(32).toString('base64url'), original.OWNER_TOKEN_SHA256, original.VAULT_SIGNING_KEY.toUpperCase()]) {
    const secrets = { ...original, VAULT_SIGNING_KEY: key }; fs.writeFileSync(file, JSON.stringify(secrets));
    assert.equal(configured({ ...secrets, BRAIN_ENABLED: 'true' }), false);
    assert.throws(() => loadPrepared(f.manifest, f.repo), /incomplete/);
  }
});
test('manual browser authorization writes a private URL handoff through the injected opener without displaying its content', async t => {
  const f = fixture(t), plan = resolvePlan({ ...f.options, manualBrowser: true }, f.repo);
  const authorizationURL = 'https://accounts.google.com/o/oauth2/v2/auth?' + new URLSearchParams({ client_id: f.client.client_id, state: 'test-only-unpredictable-state', code_challenge: 'test-only-pkce-challenge' });
  const output = [], originalLog = console.log; console.log = value => output.push(value);
  t.after(() => { console.log = originalLog; });
  await prepare(plan, async (client, options) => {
    assert.equal(client.client_id, f.client.client_id); assert.equal(typeof options.openBrowser, 'function');
    await options.openBrowser(authorizationURL);
    const handoff = path.join(plan.directory, 'authorization.private.url');
    assert.equal(fs.statSync(handoff).mode & 0o777, 0o600);
    assert.equal(fs.readFileSync(handoff, 'utf8'), authorizationURL + '\n');
    assert.equal(output.some(value => value.includes(authorizationURL) || value.includes(f.client.client_id)), false);
    assert.ok(output.some(value => value.includes(handoff)));
    await assert.rejects(options.openBrowser('https://untrusted.example.test/auth'), /Unexpected/);
    return fakeGrant();
  });
});
test('input rejects web OAuth, source escapes, extra resources, linked secrets, and relaxed private permissions', async t => {
  const f = fixture(t);
  fs.writeFileSync(f.options.oauthClient, JSON.stringify({ web: f.client })); assert.throws(() => resolvePlan(f.options, f.repo), /Desktop/);
  fs.writeFileSync(f.options.oauthClient, JSON.stringify({ installed: f.client }));
  fs.writeFileSync(f.options.config, JSON.stringify({ ...f.configuration, r2_buckets: [] })); assert.throws(() => resolvePlan(f.options, f.repo), /separate review/);
  const outside = path.join(f.base, 'outside.ts'); fs.writeFileSync(outside, 'export default {};');
  fs.writeFileSync(f.options.config, JSON.stringify({ ...f.configuration, main: outside })); assert.throws(() => resolvePlan(f.options, f.repo), /entry point/);
  fs.writeFileSync(f.options.config, JSON.stringify(f.configuration));
  const manifest = await prepare(resolvePlan(f.options, f.repo), fakeGrant);
  fs.chmodSync(path.join(f.options.privateDir, 'secrets.private.json'), 0o644); assert.throws(() => loadPrepared(manifest, f.repo), /owner-only/);
  fs.chmodSync(path.join(f.options.privateDir, 'secrets.private.json'), 0o600);
  fs.linkSync(path.join(f.options.privateDir, 'secrets.private.json'), path.join(f.base, 'hard-link')); assert.throws(() => loadPrepared(manifest, f.repo), /without links/);
});
test('loopback rejects wrong state, duplicate code, cross-origin and non-GET callbacks before accepting its own session', async t => {
  const auth = await loopbackAuthorization({ timeoutMs: 3000 }); t.after(() => auth.close());
  const callback = new URL(auth.redirectURI); callback.searchParams.set('state', auth.state); callback.searchParams.set('code', 'test-code');
  const bad = new URL(callback); bad.searchParams.set('state', 'not-the-state'); assert.equal(await requestStatus(bad), 400);
  const duplicate = new URL(callback); duplicate.searchParams.append('code', 'second'); assert.equal(await requestStatus(duplicate), 400);
  assert.equal(await requestStatus(callback, { headers: { origin: 'https://untrusted.example.test' } }), 400);
  assert.equal(await requestStatus(callback, { method: 'POST' }), 400);
  const accepted = await fetch(callback); assert.equal(accepted.status, 200); assert.equal(accepted.headers.get('cache-control'), 'no-store');
  assert.equal(await auth.code, 'test-code'); assert.doesNotMatch(await accepted.text(), /test-code|state=/);
});
test('PKCE exchange uses fixed official endpoints and the actual loopback verifier, with only drive.file offline scope', async () => {
  let auth;
  const result = await obtainGrant({ client_id: 'test-client', client_secret: 'test-client-value' }, {
    openBrowser: async value => { auth = new URL(value); assert.equal(auth.origin + auth.pathname, 'https://accounts.google.com/o/oauth2/v2/auth'); assert.equal(auth.searchParams.get('scope'), scope); assert.equal(auth.searchParams.get('access_type'), 'offline'); const callback = new URL(auth.searchParams.get('redirect_uri')); callback.searchParams.set('code', 'loopback-test-code'); callback.searchParams.set('state', auth.searchParams.get('state')); assert.equal(await requestStatus(callback), 200); },
    fetchImpl: async (url, request) => { assert.equal(url, 'https://oauth2.googleapis.com/token'); assert.equal(request.redirect, 'error'); assert.equal(request.body.get('code'), 'loopback-test-code'); assert.equal(crypto.createHash('sha256').update(request.body.get('code_verifier')).digest('base64url'), auth.searchParams.get('code_challenge')); return new Response(JSON.stringify({ refresh_token: await fakeGrant(), scope }), { status: 200 }); }
  });
  assert.equal(result, await fakeGrant());
});
test('declined and expired authorization sessions fail without storing or revealing a grant', async () => {
  const auth = await loopbackAuthorization({ timeoutMs: 3000 }); const callback = new URL(auth.redirectURI); callback.searchParams.set('state', auth.state); callback.searchParams.set('error', 'access_denied');
  await requestStatus(callback); await assert.rejects(auth.code, /declined/);
  const timeout = await loopbackAuthorization({ timeoutMs: 15 }); await assert.rejects(timeout.code, /timed out/);
});
test('cancelled authorization forcibly closes a peer with incomplete HTTP headers', async t => {
  const auth = await loopbackAuthorization({ timeoutMs: 3000 });
  const socket = net.createConnection({ host: '127.0.0.1', port: Number(new URL(auth.redirectURI).port) });
  t.after(() => socket.destroy());
  await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
  socket.write('GET /callback HTTP/1.1\r\nHost: ');
  const closed = new Promise(resolve => socket.once('close', resolve));
  auth.close(); await assert.rejects(auth.code, /cancelled/);
  await Promise.race([closed, new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('Callback socket did not close within its shutdown budget.')), 1500); timer.unref(); })]);
  assert.equal(socket.destroyed, true);
});
test('CLI dry-run performs no authentication, writes, or secret logging', t => {
  const f = fixture(t);
  fs.writeFileSync(f.options.config, JSON.stringify({ ...f.configuration, main: path.join(scriptRepo, 'brain/worker/index.ts'), d1_databases: [{ ...f.configuration.d1_databases[0], migrations_dir: path.join(scriptRepo, 'brain/migrations') }], assets: undefined }));
  const result = spawnSync(process.execPath, [path.join(scriptRepo, 'scripts/setup-brain.mjs'), '--oauth-client', f.options.oauthClient, '--config', f.options.config, '--private-dir', f.options.privateDir, '--dry-run'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /No files written/); assert.equal(fs.existsSync(f.options.privateDir), false);
  assert.equal(result.stdout.includes(f.client.client_id), false); assert.equal(result.stdout.includes(f.client.client_secret), false);
});
function fakeCloud(prepared, { names = [{ name: 'CLIENTS_JSON' }], emptyWorker = false, failMigrations = false, uncertainUpload = false } = {}) {
  const calls = []; let current = names;
  const run = async (command, args, directory, label, settings = {}) => {
    calls.push({ command, args, label, settings });
    assert.equal(directory, prepared.directory);
    for (const secret of Object.values(prepared.secrets)) assert.equal(args.some(argument => argument.includes(secret)), false);
    if (label === 'check-existing-worker') return JSON.stringify(emptyWorker ? [] : [{ id: 'test-existing-deployment' }]);
    if (label === 'check-existing-secret-names') return JSON.stringify(current);
    if (label === 'upload-new-brain-secrets') { assert.deepEqual(JSON.parse(settings.input), prepared.secrets); current = [...current, ...Object.keys(prepared.secrets).map(name => ({ name }))]; if (uncertainUpload) throw new SetupError('Injected upload interruption.'); }
    if (label === 'apply-existing-database-migrations' && failMigrations) throw new SetupError('Injected migration failure.');
    return '';
  };
  return { calls, run, clearFailure: () => { failMigrations = false; } };
}
test('explicit deploy preserves CLIENTS_JSON and passes new secrets on stdin, then applies all migrations, builds, deploys', async t => {
  const f = await preparedFixture(t), cloud = fakeCloud(f.prepared);
  await assert.rejects(deployPrepared(f.prepared, 'wrong-worker', cloud.run), /confirm-worker/); assert.equal(cloud.calls.length, 0);
  await deployPrepared(f.prepared, f.prepared.manifest.worker, cloud.run);
  assert.deepEqual(cloud.calls.map(call => call.label), ['check-existing-worker', 'check-existing-secret-names', 'upload-new-brain-secrets', 'apply-existing-database-migrations', 'build-console', 'deploy-existing-worker']);
  assert.ok(cloud.calls[3].args.includes('--remote')); assert.ok(cloud.calls[3].args.includes('DB'));
  assert.ok(cloud.calls[5].args.includes('--strict')); assert.ok(cloud.calls[5].args.includes('--no-autoconfig'));
  assert.equal(JSON.parse(cloud.calls[2].settings.input).CLIENTS_JSON, undefined);
  assert.equal(loadPrepared(f.manifest, f.repo).journal.secretsUploaded, true);
});
test('missing Worker and previously initialized vault refuse any new grant upload', async t => {
  const f = await preparedFixture(t), missing = fakeCloud(f.prepared, { emptyWorker: true });
  await assert.rejects(deployPrepared(f.prepared, f.prepared.manifest.worker, missing.run), /No existing/); assert.equal(missing.calls.length, 1);
  const existing = fakeCloud(f.prepared, { names: [{ name: 'VAULT_SIGNING_KEY' }] });
  await assert.rejects(deployPrepared(f.prepared, f.prepared.manifest.worker, existing.run), /refuses to replace/); assert.equal(existing.calls.length, 2);
});
test('retry after migration failure keeps the same uploaded signing key and never reuploads credentials', async t => {
  const f = await preparedFixture(t), cloud = fakeCloud(f.prepared, { failMigrations: true });
  await assert.rejects(deployPrepared(f.prepared, f.prepared.manifest.worker, cloud.run), /Injected/);
  const resumed = loadPrepared(f.manifest, f.repo); assert.equal(resumed.journal.secretsUploaded, true); cloud.clearFailure();
  await deployPrepared(resumed, resumed.manifest.worker, cloud.run);
  assert.equal(cloud.calls.filter(call => call.label === 'upload-new-brain-secrets').length, 1);
  assert.equal(loadPrepared(f.manifest, f.repo).secrets.VAULT_SIGNING_KEY, f.prepared.secrets.VAULT_SIGNING_KEY);
});
test('uncertain secret upload retains recovery evidence and refuses to overwrite an observed signing key', async t => {
  const f = await preparedFixture(t), cloud = fakeCloud(f.prepared, { uncertainUpload: true });
  await assert.rejects(deployPrepared(f.prepared, f.prepared.manifest.worker, cloud.run), /Injected/);
  const resumed = loadPrepared(f.manifest, f.repo); assert.equal(resumed.journal.secretsUploadStarted, true); assert.equal(resumed.journal.secretsUploaded, false);
  await assert.rejects(deployPrepared(resumed, resumed.manifest.worker, cloud.run), /refuses to replace/);
  assert.equal(cloud.calls.filter(call => call.label === 'upload-new-brain-secrets').length, 1);
});
test('prepared configuration and deployment-journal mismatches fail before any remote operation', async t => {
  const f = await preparedFixture(t);
  const journal = path.join(f.prepared.directory, 'deployment.private.json'); fs.writeFileSync(journal, JSON.stringify({ schemaVersion: 1, worker: 'other-worker', secretsUploaded: true }), { mode: 0o600 });
  assert.throws(() => loadPrepared(f.manifest, f.repo), /different setup bundle/);
  fs.unlinkSync(journal);
  const config = path.join(f.prepared.directory, 'wrangler.private.json'); const altered = structuredClone(f.prepared.config); altered.name = 'other-worker'; fs.writeFileSync(config, JSON.stringify(altered));
  assert.throws(() => loadPrepared(f.manifest, f.repo), /configuration changed/);
});


function processFixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cloudnest-private-command-'));
  fs.chmodSync(directory, 0o700);
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return fs.realpathSync(directory);
}
test('actual subprocess keeps JSON stdout separate from stderr warnings and writes private combined diagnostics', async t => {
  const directory = processFixture(t);
  const script = "process.stderr.write('warning: synthetic diagnostic\\n'); process.stdout.write(JSON.stringify({deployments:[{id:'fixture-deployment'}],logLevel:process.env.WRANGLER_LOG}));";
  const output = await runPrivate(process.execPath, ['-e', script], directory, 'json-fixture', { timeoutMs: 3000 });
  assert.deepEqual(JSON.parse(output), { deployments: [{ id: 'fixture-deployment' }], logLevel: 'log' });
  const files = fs.readdirSync(directory); assert.equal(files.length, 1);
  const file = path.join(directory, files[0]); assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  const diagnostic = fs.readFileSync(file, 'utf8'); assert.match(diagnostic, /synthetic diagnostic/); assert.match(diagnostic, /fixture-deployment/);
});
test('actual subprocess nonzero status rejects even when stdout contains valid JSON', async t => {
  const directory = processFixture(t);
  await assert.rejects(runPrivate(process.execPath, ['-e', "process.stdout.write('[]'); process.stderr.write('synthetic failure'); process.exitCode=7;"], directory, 'nonzero-fixture', { timeoutMs: 3000 }), /Setup command failed/);
  assert.match(fs.readFileSync(path.join(directory, fs.readdirSync(directory)[0]), 'utf8'), /synthetic failure/);
});
test('actual subprocess stdout and stderr budgets are bounded and never return truncated success', async t => {
  for (const stream of ['stdout', 'stderr']) {
    const directory = processFixture(t);
    await assert.rejects(runPrivate(process.execPath, ['-e', `process.${stream}.write(Buffer.alloc(131072, 88)); setInterval(()=>{},1000);`], directory, 'budget-fixture', { maximumBytes: 4096, timeoutMs: 3000 }), /budget/);
    const files = fs.readdirSync(directory); assert.equal(files.length, 1);
    assert.ok(fs.statSync(path.join(directory, files[0])).size <= 4096);
  }
});
test('actual subprocess deadline escalates an unresponsive owned child and reports an uncertain result', async t => {
  const directory = processFixture(t), pidFile = path.join(directory, 'child.pid');
  const script = "require('node:fs').writeFileSync(process.argv[1],String(process.pid)); process.on('SIGTERM',()=>{}); setInterval(()=>{},1000);";
  const started = Date.now();
  await assert.rejects(runPrivate(process.execPath, ['-e', script, pidFile], directory, 'deadline-fixture', { timeoutMs: 250 }), /deadline.*uncertain/);
  assert.ok(Date.now() - started < 3000);
  const pid = Number(fs.readFileSync(pidFile, 'utf8'));
  assert.throws(() => process.kill(pid, 0), error => error.code === 'ESRCH');
});
test('subprocess spawn failure and unsafe diagnostic labels fail without output acceptance', async t => {
  const directory = processFixture(t);
  await assert.rejects(runPrivate(path.join(directory, 'missing-command'), [], directory, 'missing-fixture', { timeoutMs: 1000 }), /could not start/);
  await assert.rejects(runPrivate(process.execPath, ['-e', 'process.exit(0)'], directory, '../escape', { timeoutMs: 1000 }), /Invalid private subprocess/);
  await assert.rejects(runPrivate(process.execPath, ['-e', 'process.exit(0)'], directory, 'oversized-setting', { maximumBytes: 2_097_153 }), /Invalid private subprocess/);
});


async function deployedFixture(t) {
  const f = await preparedFixture(t), cloud = fakeCloud(f.prepared);
  await deployPrepared(f.prepared, f.prepared.manifest.worker, cloud.run);
  return { ...f, prepared: loadPrepared(f.manifest, f.repo) };
}
function renewalMocks(prepared, { wrongAccount = false, expiredOld = false, uncertainUpload = false } = {}) {
  const nextGrant = 'fixture-renewed-refresh-grant-rn0', calls = [], requests = [];
  const oldGrant = prepared.secrets.GOOGLE_REFRESH_TOKEN;
  const fetchImpl = async (value, request) => {
    const url = new URL(value); requests.push({ url: url.href, request });
    assert.equal(request.redirect, 'error'); assert.ok(request.signal);
    if (url.origin + url.pathname === 'https://oauth2.googleapis.com/token') {
      assert.equal(request.method, 'POST'); assert.equal(request.body.get('client_id'), prepared.secrets.GOOGLE_CLIENT_ID);
      assert.equal(request.body.get('client_secret'), prepared.secrets.GOOGLE_CLIENT_SECRET);
      assert.equal(request.body.get('grant_type'), 'refresh_token');
      const grant = request.body.get('refresh_token'); assert.ok([oldGrant, nextGrant].includes(grant));
      if (expiredOld && grant === oldGrant) return new Response('{"error":"invalid_grant"}', { status: 400 });
      return new Response(JSON.stringify({ access_token: grant === oldGrant ? 'fixture-old-access-rn0' : 'fixture-new-access-rn0', scope }), { status: 200 });
    }
    assert.equal(url.origin + url.pathname, 'https://www.googleapis.com/drive/v3/about');
    assert.equal(url.searchParams.get('fields'), 'user(permissionId)'); assert.equal([...url.searchParams].length, 1);
    const fresh = request.headers.Authorization === 'Bearer fixture-new-access-rn0';
    assert.ok(fresh || request.headers.Authorization === 'Bearer fixture-old-access-rn0');
    return new Response(JSON.stringify({ user: { permissionId: wrongAccount && fresh ? 'different-fixture-account' : 'same-fixture-account' } }), { status: 200 });
  };
  const run = async (command, args, directory, label, settings = {}) => {
    calls.push({ command, args, directory, label, settings }); assert.equal(directory, prepared.directory);
    for (const value of [...Object.values(prepared.secrets), nextGrant]) assert.equal(args.some(argument => argument.includes(value)), false);
    assert.equal(args.at(-2), '--config'); assert.equal(args.at(-1), path.join(prepared.directory, 'wrangler.private.json'));
    if (label === 'renew-check-worker') return JSON.stringify([{ id: 'existing-fixture-deployment' }]);
    if (label === 'renew-check-secret-names') return JSON.stringify(Object.keys(prepared.secrets).concat('CLIENTS_JSON').map(name => ({ name })));
    assert.equal(label, 'renew-google-refresh-token');
    assert.deepEqual(args.slice(1, 6), ['secret', 'put', 'GOOGLE_REFRESH_TOKEN', '--name', prepared.manifest.worker]);
    assert.equal(settings.input, nextGrant + '\n');
    if (uncertainUpload) throw new SetupError('Injected uncertain renewal upload.');
    return '';
  };
  let consents = 0;
  const authorization = async client => { consents++; assert.deepEqual(client, { client_id: prepared.secrets.GOOGLE_CLIENT_ID, client_secret: prepared.secrets.GOOGLE_CLIENT_SECRET }); return nextGrant; };
  return { nextGrant, calls, requests, run, fetchImpl, authorization, consents: () => consents };
}
test('renewal binds the same Drive account, uploads only refresh stdin, and preserves every owner key and configuration byte', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared);
  const names = ['owner-token.private.txt', 'connection.private.json', 'wrangler.private.json', 'setup.private.json'];
  const original = names.map(name => fs.readFileSync(path.join(f.prepared.directory, name)));
  const result = await renewGoogleGrant(f.prepared, f.prepared.manifest.worker, mock);
  assert.equal(mock.consents(), 1); assert.equal(mock.calls.length, 3);
  assert.equal(result.secrets.GOOGLE_REFRESH_TOKEN, mock.nextGrant);
  for (const key of Object.keys(f.prepared.secrets).filter(name => name !== 'GOOGLE_REFRESH_TOKEN')) assert.equal(result.secrets[key], f.prepared.secrets[key]);
  names.forEach((name, i) => assert.deepEqual(fs.readFileSync(path.join(result.directory, name)), original[i]));
  const bindingFile = path.join(result.directory, 'google-account.private.json'), binding = fs.readFileSync(bindingFile, 'utf8');
  assert.equal(binding.includes('same-fixture-account'), false); assert.equal(binding.includes(mock.nextGrant), false);
  assert.equal(fs.statSync(bindingFile).mode & 0o777, 0o600);
  assert.equal(JSON.parse(fs.readFileSync(path.join(result.directory, 'google-renewal.private.json'))).state, 'completed');
  assert.equal(loadPrepared(f.manifest, f.repo).journal.secretBundleSHA256, crypto.createHash('sha256').update(JSON.stringify(result.secrets)).digest('hex'));
});
test('a different consent account is rejected before any secret upload and original identity survives', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared, { wrongAccount: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, mock), /different Google Drive account/);
  assert.equal(mock.calls.length, 2); assert.deepEqual(loadPrepared(f.manifest, f.repo).secrets, f.prepared.secrets);
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.prepared.directory, 'google-renewal.private.json'))).state, 'cancelled');
});
test('expired old grants without an authenticated account binding stop before browser consent', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared, { expiredOld: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, mock), /no trusted private account binding/);
  assert.equal(mock.consents(), 0); assert.equal(mock.calls.length, 2); assert.deepEqual(loadPrepared(f.manifest, f.repo).secrets, f.prepared.secrets);
});
test('a preserved signed binding supports a later expired old grant without changing account or vault key', async t => {
  const f = await deployedFixture(t);
  const first = renewalMocks(f.prepared, { wrongAccount: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, first), /different Google Drive account/);
  const second = renewalMocks(f.prepared, { expiredOld: true });
  const result = await renewGoogleGrant(f.prepared, f.prepared.manifest.worker, second);
  assert.equal(result.secrets.GOOGLE_REFRESH_TOKEN, second.nextGrant); assert.equal(result.secrets.VAULT_SIGNING_KEY, f.prepared.secrets.VAULT_SIGNING_KEY);
});
test('uncertain rotation keeps staged recovery evidence and refuses automatic upload retry or ordinary deployment', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared, { uncertainUpload: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, mock), /Injected uncertain/);
  const journal = JSON.parse(fs.readFileSync(path.join(f.prepared.directory, 'google-renewal.private.json')));
  assert.equal(journal.state, 'upload-started'); assert.ok(fs.existsSync(path.join(f.prepared.directory, journal.candidate, 'secrets.private.json')));
  const resumed = loadPrepared(f.manifest, f.repo); assert.deepEqual(resumed.secrets, f.prepared.secrets);
  const calls = mock.calls.length;
  await assert.rejects(renewGoogleGrant(resumed, resumed.manifest.worker, mock), /uncertain/); assert.equal(mock.calls.length, calls);
  await assert.rejects(deployPrepared(resumed, resumed.manifest.worker, mock.run), /incomplete Google renewal/); assert.equal(mock.calls.length, calls);
});
test('manual renewal hands only an official private URL to the opener and rejects immutable-file changes during consent', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared), output = [], oldLog = console.log;
  console.log = text => output.push(text); t.after(() => { console.log = oldLog; });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, { ...mock, manualBrowser: true, authorization: async (client, options) => {
    const url = 'https://accounts.google.com/o/oauth2/v2/auth?state=synthetic-state&code_challenge=synthetic-challenge';
    await options.openBrowser(url);
    const journal = JSON.parse(fs.readFileSync(path.join(f.prepared.directory, 'google-renewal.private.json')));
    const handoff = path.join(f.prepared.directory, journal.candidate, 'authorization.private.url');
    assert.equal(fs.readFileSync(handoff, 'utf8'), url + '\n'); assert.equal(fs.statSync(handoff).mode & 0o777, 0o600);
    assert.equal(output.some(text => text.includes(url) || text.includes(mock.nextGrant)), false);
    fs.appendFileSync(path.join(f.prepared.directory, 'connection.private.json'), ' ');
    return mock.nextGrant;
  } }), /changed during consent/);
  assert.equal(mock.calls.length, 2); assert.deepEqual(loadPrepared(f.manifest, f.repo).secrets, f.prepared.secrets);
});

test('a confirmed renewal interrupted between local writes completes without consent or another remote upload', async t => {
  const f = await deployedFixture(t), mock = renewalMocks(f.prepared, { uncertainUpload: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, mock), /Injected uncertain/);
  const file = path.join(f.prepared.directory, 'google-renewal.private.json');
  const renewal = JSON.parse(fs.readFileSync(file));
  // Model an acknowledged upload followed by a crash after replacing only the
  // local secret file. The durable acknowledgement authorizes local completion.
  renewal.state = 'uploaded'; fs.writeFileSync(file, JSON.stringify(renewal));
  fs.copyFileSync(path.join(f.prepared.directory, renewal.candidate, 'secrets.private.json'), path.join(f.prepared.directory, 'secrets.private.json'));
  const interrupted = loadPrepared(f.manifest, f.repo);
  assert.equal(interrupted.secrets.GOOGLE_REFRESH_TOKEN, mock.nextGrant);
  const rejectNetwork = async () => { throw new Error('Recovery must not make network calls or obtain another grant'); };
  const recovered = await renewGoogleGrant(interrupted, interrupted.manifest.worker, { run: rejectNetwork, authorization: rejectNetwork, fetchImpl: rejectNetwork });
  assert.equal(recovered.secrets.VAULT_SIGNING_KEY, f.prepared.secrets.VAULT_SIGNING_KEY);
  assert.equal(JSON.parse(fs.readFileSync(file)).state, 'completed');
});
test('tampered cached account bindings cannot authorize expired-grant fallback', async t => {
  const f = await deployedFixture(t), first = renewalMocks(f.prepared, { wrongAccount: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, first), /different Google Drive account/);
  const file = path.join(f.prepared.directory, 'google-account.private.json'), binding = JSON.parse(fs.readFileSync(file));
  binding.accountSHA256 = crypto.randomBytes(32).toString('hex'); fs.writeFileSync(file, JSON.stringify(binding));
  const attempt = renewalMocks(f.prepared, { expiredOld: true });
  await assert.rejects(renewGoogleGrant(f.prepared, f.prepared.manifest.worker, attempt), /account binding/);
  assert.equal(attempt.consents(), 0); assert.equal(attempt.calls.length, 2);
  assert.deepEqual(loadPrepared(f.manifest, f.repo).secrets, f.prepared.secrets);
});
