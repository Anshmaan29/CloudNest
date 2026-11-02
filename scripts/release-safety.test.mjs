import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { auditEntry, auditZip, LIMITS, readKnownSecrets, safeName, sourceZip } from './release-safety.mjs';
import { auditSource } from './audit-public-source.mjs';
import { packageSource } from './package-source.mjs';
import { auditDmgStage, auditNativeBundle, packageNativeZip, publicGoogleClient, stagePublicGoogleClient, publicReleasePublisher, stageReleasePublisher } from './audit-native-bundle.mjs';

const script = name => fileURLToPath(new URL(name, import.meta.url));
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'cloudnest-public-fixture-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const repo = path.join(base, 'repo'); fs.mkdirSync(repo);
  const git = (...args) => execFileSync('git', args, { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'] });
  git('init', '-q'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Public fixture');
  const write = (name, text) => { fs.mkdirSync(path.dirname(path.join(repo, name)), { recursive: true }); fs.writeFileSync(path.join(repo, name), text); };
  const commit = () => { git('add', '-A'); git('commit', '-qm', 'Public fixture snapshot'); };
  write('README.md', 'Public example, no account data.\n'); commit();
  return { base, repo, git, write, commit, output: path.join(base, 'source.zip') };
}
const fakeGoogle = () => ['ya29.', 'G'.repeat(48)].join('');
const fakeGrant = () => ['1/', '/', 'R'.repeat(48)].join('');
const fakeGitHub = () => ['ghp_', 'H'.repeat(48)].join('');
const entry = (name = 'public.txt', value = 'public data') => ({ name, bytes: Buffer.from(value), mode: '100644' });

for (const name of ['../escape', '/absolute', 'a/../b', 'a//b', 'a\\b', 'C:drive', 'a\nb', '.', 'a/'.repeat(65) + 'b']) {
  test(`unsafe path is rejected (${JSON.stringify(name)})`, () => assert.throws(() => safeName(name), /Unsafe release path/));
}
for (const name of ['secrets.private.json', 'connection.private.json', 'secrets.json', 'owner-token.txt', 'tokens.yaml', 'oauth-client.json', 'brain/wrangler.local.jsonc', 'exports/records.json', '.env', '.dev.vars', 'api-key.json', 'vault-signing-key.txt', 'backup/catalog.sqlite', 'source.zip', '.git/config', 'id_ed25519', '.npmrc']) {
  test(`private filename is blocked (${name})`, () => assert.throws(() => auditEntry(name, Buffer.from('{}')), /Private release filename/));
}
test('public configuration, code, hashes and synthetic fixture identifiers remain valid', () => {
  for (const name of ['brain/.dev.vars.example', 'brain/wrangler.example.jsonc', '.env.example', 'oauth.example.json', 'brain/api/oauth.ts', 'scripts/setup-brain.test.mjs', 'fixtures/records.json']) {
    auditEntry(name, Buffer.from(JSON.stringify({ sha256: 'a'.repeat(64), id: 'fixture-record', client_secret: 'example-value' })));
  }
  auditEntry('brain/.dev.vars.example', Buffer.from('GOOGLE_CLIENT_SECRET=\nGOOGLE_REFRESH_TOKEN=\nVAULT_SIGNING_KEY=\n'));
});
for (const [rule, value] of [['Google token', fakeGoogle()], ['Google token', fakeGrant()], ['service token', fakeGitHub()], ['configured credential', JSON.stringify({ refresh_token: 'r'.repeat(48) })], ['configured credential', JSON.stringify({ VAULT_SIGNING_KEY: 'a'.repeat(64) })], ['environment credential', 'VAULT_SIGNING_KEY=' + 'b'.repeat(64)], ['private key', ['-----BEGIN ', 'PRIVATE KEY-----'].join('')]]) {
  test(`credential fixture is redacted (${rule})`, () => {
    assert.throws(() => auditEntry('public/config.txt', Buffer.from(value)), error => error.message === `${rule}: "public/config.txt"` && !error.message.includes(value));
  });
}
test('binary and oversized source blobs are rejected', () => {
  assert.throws(() => auditEntry('public.bin', Buffer.from([0, 1])), /Unexpected binary/);
  assert.throws(() => auditEntry('public.txt', Buffer.alloc(LIMITS.file + 1)), /size limit/);
});
test('known-secret comparison is optional, bounded, private and symlink-safe', t => {
  const f = fixture(t), privateInput = path.join(f.base, 'compare.json'), secret = 'z'.repeat(48);
  assert.deepEqual(readKnownSecrets(), []);
  fs.writeFileSync(privateInput, JSON.stringify([secret]), { mode: 0o600 });
  const knownSecrets = readKnownSecrets(privateInput);
  assert.throws(() => auditEntry('public.txt', Buffer.from(secret), { knownSecrets }), error => error.message === 'Known private value: "public.txt"');
  fs.symlinkSync(privateInput, path.join(f.base, 'link.json'));
  assert.throws(() => readKnownSecrets(path.join(f.base, 'link.json')), /Invalid private comparison input/);
  fs.chmodSync(privateInput, 0o644);
  assert.throws(() => readKnownSecrets(privateInput), /Invalid private comparison input/);
});
test('source package contains only committed allowlisted files and is reproducible', t => {
  const f = fixture(t);
  f.write('.gitignore', '.private/\n*.private.json\n'); f.commit();
  f.write('secrets.private.json', JSON.stringify({ refresh_token: fakeGrant() }));
  f.write('.private/exports.json', JSON.stringify({ records: 'private owner content' }));
  const result = packageSource(f);
  const bytes = fs.readFileSync(f.output), names = auditZip(bytes);
  assert.deepEqual([...names].sort(), ['.gitignore', 'README.md']);
  assert.equal(bytes.includes(Buffer.from(fakeGrant())), false);
  assert.equal(result.commit, f.git('rev-parse', 'HEAD').toString().trim());
  const second = path.join(f.base, 'second.zip'); packageSource({ ...f, output: second });
  assert.deepEqual(fs.readFileSync(second), bytes);
});
test('dirty, staged and untracked work block publication', t => {
  const f = fixture(t);
  f.write('README.md', 'modified');
  assert.throws(() => packageSource(f), /clean committed/);
  f.git('add', 'README.md');
  assert.throws(() => packageSource(f), /clean committed/);
  f.git('reset', '--hard', '-q', 'HEAD'); f.write('untracked.txt', 'untracked');
  assert.throws(() => packageSource(f), /clean committed/);
  assert.equal(fs.existsSync(f.output), false);
});
test('tracked private files and secret contents fail without publishing or echoing values', t => {
  const f = fixture(t), secret = fakeGoogle();
  f.write('public.txt', secret); f.commit();
  const run = spawnSync(process.execPath, [script('package-source.mjs'), '--output', f.output], { cwd: f.repo, encoding: 'utf8' });
  assert.equal(run.status, 1); assert.match(run.stderr, /Google token: "public.txt"/);
  assert.equal((run.stdout + run.stderr).includes(secret), false); assert.equal(fs.existsSync(f.output), false);
  f.write('public.txt', 'safe'); f.write('connection.private.json', '{}'); f.commit();
  assert.throws(() => packageSource(f), /Private release filename/); assert.equal(fs.existsSync(f.output), false);
});
test('existing source archive is never overwritten', t => {
  const f = fixture(t); fs.writeFileSync(f.output, 'existing owner output');
  assert.throws(() => packageSource(f), /already exists/);
  assert.equal(fs.readFileSync(f.output, 'utf8'), 'existing owner output');
});
test('tracked symlinks and submodules are rejected', t => {
  const f = fixture(t);
  fs.symlinkSync('README.md', path.join(f.repo, 'link')); f.commit();
  assert.throws(() => packageSource(f), /Symlink or submodule/);
  f.git('rm', 'link'); f.commit();
  const oid = f.git('rev-parse', 'HEAD').toString().trim();
  f.git('update-index', '--add', '--cacheinfo', `160000,${oid},module`); f.git('commit', '-qm', 'Synthetic submodule'); fs.mkdirSync(path.join(f.repo, 'module'));
  assert.throws(() => packageSource(f), /Symlink or submodule/);
});
test('index audit scans staged bytes, not edited workspace substitutes', t => {
  const f = fixture(t); f.write('public.txt', fakeGrant()); f.git('add', 'public.txt'); f.write('public.txt', 'safe workspace substitution');
  assert.throws(() => auditSource(f), /Google token/);
});
test('history audit catches deleted historical credentials and uses redacted diagnostics', t => {
  const f = fixture(t), secret = fakeGitHub(); f.write('obsolete.txt', secret); f.commit(); f.git('rm', 'obsolete.txt'); f.commit();
  assert.equal(auditSource({ ...f, head: true }).files, 1);
  assert.throws(() => auditSource({ ...f, history: true }), error => error.message === 'service token: "obsolete.txt"' && !error.message.includes(secret));
});
test('complete public history audit passes and shallow history fails closed', t => {
  const f = fixture(t); f.write('another.txt', 'public fixture'); f.commit();
  assert.equal(auditSource({ ...f, history: true }).commits, 2);
  fs.writeFileSync(path.join(f.repo, '.git/shallow'), f.git('rev-parse', 'HEAD'));
  assert.throws(() => auditSource({ ...f, history: true }), /complete Git checkout/);
});
test('ZIP integrity, central/local mismatch and duplicate paths fail closed', () => {
  const valid = sourceZip([entry()]); assert.equal(auditZip(valid).size, 1);
  const corrupt = Buffer.from(valid); corrupt[30 + Buffer.byteLength('public.txt')] ^= 1;
  assert.throws(() => auditZip(corrupt), /integrity mismatch/);
  const mismatch = Buffer.from(valid); mismatch[30] = 'x'.charCodeAt(0);
  assert.throws(() => auditZip(mismatch), /path or data mismatch/);
  assert.throws(() => auditZip(sourceZip([entry(), entry()])), /Duplicate/);
  assert.throws(() => auditZip(Buffer.concat([valid, Buffer.from('trailing')])), /envelope/);
});
test('ZIP traversal, symlinks, oversized expansion and encryption are rejected before decompression', () => {
  assert.throws(() => auditZip(sourceZip([entry('../escape')])), /Unsafe release path/);
  const zip = sourceZip([entry()]), cd = zip.readUInt32LE(zip.length - 6);
  const symlink = Buffer.from(zip); symlink.writeUInt32LE((0o120777 << 16) >>> 0, cd + 38);
  assert.throws(() => auditZip(symlink), /Unsupported or oversized/);
  const bomb = Buffer.from(zip); bomb.writeUInt32LE(LIMITS.file + 1, cd + 24);
  assert.throws(() => auditZip(bomb), /Unsupported or oversized/);
  const encrypted = Buffer.from(zip); encrypted.writeUInt16LE(0x801, cd + 8);
  assert.throws(() => auditZip(encrypted), /Unsupported or oversized/);
});
function nativeFixture(f) {
  const bundle = path.join(f.base, 'CloudNest.app');
  for (const [name, bytes] of [['Contents/Info.plist', '<plist/>'], ['Contents/MacOS/CloudNest', '\0compiled fixture'], ['Contents/Helpers/CloudNestUpdateHelper', '\0compiled helper fixture'], ['Contents/Resources/CloudNest.icns', '\0icon fixture'], ['Contents/_CodeSignature/CodeResources', '<plist/>']]) {
    fs.mkdirSync(path.dirname(path.join(bundle, name)), { recursive: true }); fs.writeFileSync(path.join(bundle, name), bytes);
  }
  return bundle;
}
test('native package allows exactly signed app members and excludes adjacent build data', t => {
  const f = fixture(t), bundle = nativeFixture(f); fs.writeFileSync(path.join(f.base, 'owner-token.private.txt'), fakeGoogle());
  assert.equal(auditNativeBundle(bundle).length, 5);
  const output = path.join(f.base, 'app.zip'); packageNativeZip(bundle, output);
  assert.equal(auditZip(fs.readFileSync(output), { allowBinary: true }).size, 5);
  fs.writeFileSync(path.join(bundle, 'Contents/Resources/connection.private.json'), '{}');
  assert.throws(() => auditNativeBundle(bundle), /Unexpected app resource/);
});
test('native bundle missing files, resource symlinks and embedded credentials are blocked', t => {
  const f = fixture(t), bundle = nativeFixture(f), icon = path.join(bundle, 'Contents/Resources/CloudNest.icns');
  fs.unlinkSync(icon); assert.throws(() => auditNativeBundle(bundle), /missing required resources/);
  fs.symlinkSync(path.join(bundle, 'Contents/Info.plist'), icon); assert.throws(() => auditNativeBundle(bundle));
  fs.unlinkSync(icon); fs.writeFileSync(icon, fakeGoogle());
  assert.throws(() => auditNativeBundle(bundle), /Google token/);
});
test('ignore rules protect generated bundles, exports and keys while retaining templates', t => {
  const f = fixture(t); f.write('.gitignore', fs.readFileSync(script('../.gitignore'))); f.commit();
  for (const name of ['connection.private.json', 'secrets.json', 'exports/records.json', 'vault-signing-key.txt', 'credentials.yaml', 'oauth-downloaded.json', 'owner-token.private.txt', 'api-key.json', 'key.pem', 'source.zip']) assert.doesNotThrow(() => f.git('check-ignore', name));
  for (const name of ['brain/.dev.vars.example', 'brain/wrangler.example.jsonc', 'oauth.example.json', '.env.example']) assert.throws(() => f.git('check-ignore', name));
});

test('known private values in diagnostic paths are redacted', () => {
  const secret = 'q'.repeat(48);
  assert.throws(() => auditEntry(`folder/${secret}.private.json`, Buffer.from('{}'), { knownSecrets: [Buffer.from(secret)] }), error => error.message.includes('[REDACTED]') && !error.message.includes(secret));
});
test('ZIP portable path collisions cannot overwrite extracted entries', () => {
  for (const names of [['a.txt', 'A.txt'], ['folder', 'folder/file.txt'], ['folder/file.txt', 'folder'], ['caf\u00e9.txt', 'cafe\u0301.txt']]) assert.throws(() => auditZip(sourceZip(names.map(name => entry(name)))), /Conflicting portable ZIP path/);
});
test('DMG stage accepts only reviewed app, readme and fixed Applications link', t => {
  const f = fixture(t), stage = path.join(f.base, 'stage'); fs.mkdirSync(stage);
  fs.renameSync(nativeFixture(f), path.join(stage, 'CloudNest.app'));
  fs.symlinkSync('/Applications', path.join(stage, 'Applications')); fs.writeFileSync(path.join(stage, 'READ ME.txt'), 'Local preview.');
  assert.equal(auditDmgStage(stage).length, 5);
  fs.writeFileSync(path.join(stage, 'secrets.private.json'), '{}');
  assert.throws(() => auditDmgStage(stage), /Unexpected DMG stage resource/);
  fs.unlinkSync(path.join(stage, 'secrets.private.json')); fs.unlinkSync(path.join(stage, 'Applications')); fs.symlinkSync('/tmp', path.join(stage, 'Applications'));
  assert.throws(() => auditDmgStage(stage), /Invalid DMG Applications link/);
});

const publicClientFixture = () => ({ schemaVersion: 1, clientID: '123456789012-syntheticfixture.apps.googleusercontent.com' });
test('public OAuth metadata permits only normalized public fields in native packages', t => {
  const f = fixture(t), bundle = nativeFixture(f), input = path.join(f.base, 'public-client.json');
  fs.writeFileSync(input, JSON.stringify(publicClientFixture(), null, 2));
  stagePublicGoogleClient(input, bundle);
  assert.equal(auditNativeBundle(bundle).length, 6);
  assert.equal(fs.readFileSync(path.join(bundle, 'Contents/Resources/CloudNestGoogleClient.json'), 'utf8'), JSON.stringify(publicClientFixture()) + '\n');
  assert.throws(() => stagePublicGoogleClient(input, bundle));
  fs.unlinkSync(path.join(bundle, 'Contents/Info.plist'));
  assert.throws(() => auditNativeBundle(bundle), /missing required/);
});
test('public OAuth metadata rejects downloaded secrets, overrides and malformed schema', () => {
  for (const value of [null, [], { installed: { client_id: 'fixture', client_secret: 'fixture' } },
    { ...publicClientFixture(), client_secret: 'fixture' }, { ...publicClientFixture(), endpoint: 'https://example.invalid' },
    { ...publicClientFixture(), schemaVersion: true }, { ...publicClientFixture(), clientID: 'invalid' },
    { ...publicClientFixture(), clientID: 'x'.repeat(5000) }]) {
    assert.throws(() => publicGoogleClient(Buffer.from(JSON.stringify(value))), /Invalid public Google/);
  }
  assert.throws(() => publicGoogleClient(Buffer.from([0xff])), /Invalid public Google/);
});
test('public OAuth staging rejects symlink inputs and resource directories', t => {
  const f = fixture(t), bundle = nativeFixture(f), input = path.join(f.base, 'public-client.json');
  fs.writeFileSync(input, JSON.stringify(publicClientFixture()));
  const link = path.join(f.base, 'client-link'); fs.symlinkSync(input, link);
  assert.throws(() => stagePublicGoogleClient(link, bundle));
  const resource = path.join(bundle, 'Contents/Resources');
  fs.renameSync(resource, path.join(f.base, 'resources')); fs.symlinkSync(path.join(f.base, 'resources'), resource);
  assert.throws(() => stagePublicGoogleClient(input, bundle), /Invalid public client resource directory/);
});

test('synthetic protected-home fixtures are scoped to tests while real home paths stay blocked', () => {
  const fixturePath = ['/Users', 'fixture', 'Library', 'models'].join('/') + '/';
  const actualPath = ['/Users', 'synthetic-other-owner', 'Documents'].join('/') + '/';
  assert.doesNotThrow(() => auditEntry('mac/Tests/PolicyTests.swift', Buffer.from(fixturePath)));
  assert.throws(() => auditEntry('mac/Core/Policy.swift', Buffer.from(fixturePath)), /personal home path/);
  assert.throws(() => auditEntry('mac/Tests/PolicyTests.swift', Buffer.from(actualPath)), /personal home path/);
});

const publisherFixture = () => ({schemaVersion:1,publicKey:Buffer.alloc(32).toString('base64'),teamID:'FIXTURE001',feedURL:'https://github.com/Anshmaan29/CloudNest/releases/latest/download/update.json'});
test('native publisher metadata is public-only and bundled on an explicit allowlist', t => {
  const f=fixture(t), bundle=nativeFixture(f), input=path.join(f.base,'publisher.json');
  fs.writeFileSync(input,JSON.stringify(publisherFixture())); stageReleasePublisher(input,bundle);
  assert.equal(auditNativeBundle(bundle).length,6); assert.throws(()=>stageReleasePublisher(input,bundle));
  assert.deepEqual(JSON.parse(publicReleasePublisher(Buffer.from(JSON.stringify(publisherFixture())))),publisherFixture());
});
test('publisher staging rejects private keys, endpoint overrides and invalid trust anchors', () => {
  for(const value of [{...publisherFixture(),privateKey:'fixture'}, {...publisherFixture(),schemaVersion:true}, {...publisherFixture(),teamID:'invalid'}, {...publisherFixture(),publicKey:'invalid'}, {...publisherFixture(),feedURL:'https://attacker.example/update.json'}, {...publisherFixture(),feedURL:'https://github.com/Other/Repo/releases/latest/download/update.json'}, {...publisherFixture(),feedURL:'https://github.com/Anshmaan29/CloudNest/releases/latest/download/update.json?token=fixture'}]) assert.throws(()=>publicReleasePublisher(Buffer.from(JSON.stringify(value))), /Invalid public release/);
});


test('native bundle allows a bounded stapled ticket and requires its signed update helper', t => {
  const f=fixture(t), bundle=nativeFixture(f), ticket=path.join(bundle,'Contents/CodeResources');
  fs.writeFileSync(ticket,Buffer.from('fixture stapled ticket'));
  assert.equal(auditNativeBundle(bundle).length,6);
  fs.writeFileSync(ticket,Buffer.alloc(1024*1024+1));assert.throws(()=>auditNativeBundle(bundle));
  fs.unlinkSync(ticket);fs.unlinkSync(path.join(bundle,'Contents/Helpers/CloudNestUpdateHelper'));
  assert.throws(()=>auditNativeBundle(bundle),/missing required resources/);
});
