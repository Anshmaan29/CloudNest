// Native distribution resource boundary; never recursively copy the build directory.
import fs from 'node:fs';
import path from 'node:path';
import { auditEntry, auditZip, blocked, cliError, isMain, LIMITS, readRegularFile, sourceZip } from './release-safety.mjs';

const members = new Set(['Contents/Info.plist', 'Contents/MacOS/CloudNest', 'Contents/Resources/CloudNest.icns', 'Contents/_CodeSignature/CodeResources']);
const publicClientMember = 'Contents/Resources/CloudNestGoogleClient.json';
const publisherMember = 'Contents/Resources/CloudNestReleasePublisher.json';
const directories = new Set(['', 'Contents', 'Contents/MacOS', 'Contents/Resources', 'Contents/_CodeSignature']);
export function publicGoogleClient(bytes) {
  let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { blocked('Invalid public Google client metadata'); }
  if (bytes.length > 4096 || !value || Array.isArray(value) ||
      Object.keys(value).sort().join(',') !== 'clientID,schemaVersion' || value.schemaVersion !== 1 ||
      typeof value.clientID !== 'string' || value.clientID.length > 200 ||
      !/^[0-9]{6,30}(?:-[A-Za-z0-9_-]{6,128})?\.apps\.googleusercontent\.com$/.test(value.clientID)) blocked('Invalid public Google client metadata');
  // Canonicalize only the two public fields; downloaded installed-client JSON,
  // endpoint overrides and secret material are never copied to the application.
  return Buffer.from(JSON.stringify({ schemaVersion: 1, clientID: value.clientID }) + '\n');
}
export function stagePublicGoogleClient(input, bundle) {
  const bytes = publicGoogleClient(readRegularFile(input, 4096));
  const resourceDirectory = path.join(bundle, 'Contents/Resources');
  const info = fs.lstatSync(resourceDirectory);
  if (!info.isDirectory() || info.isSymbolicLink()) blocked('Invalid public client resource directory');
  fs.writeFileSync(path.join(bundle, publicClientMember), bytes, { flag: 'wx', mode: 0o644 });
}
export function publicReleasePublisher(bytes) {
  let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { blocked('Invalid public release publisher metadata'); }
  if (bytes.length > 4096 || !value || Array.isArray(value) || Object.keys(value).sort().join(',') !== 'feedURL,publicKey,schemaVersion,teamID' || value.schemaVersion !== 1 ||
      typeof value.publicKey !== 'string' || Buffer.from(value.publicKey, 'base64').length !== 32 || Buffer.from(value.publicKey, 'base64').toString('base64') !== value.publicKey ||
      typeof value.teamID !== 'string' || !/^[A-Z0-9]{10}$/.test(value.teamID) || typeof value.feedURL !== 'string') blocked('Invalid public release publisher metadata');
  let url; try { url = new URL(value.feedURL); } catch { blocked('Invalid public release publisher metadata'); }
  if (url.origin !== 'https://github.com' || url.username || url.password || url.search || url.hash || value.feedURL.includes('%') ||
      !/^\/Anshmaan29\/CloudNest\/releases\/(latest\/download\/[A-Za-z0-9._-]+|download\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)$/.test(url.pathname)) blocked('Invalid public release publisher metadata');
  return Buffer.from(JSON.stringify({schemaVersion:1,publicKey:value.publicKey,teamID:value.teamID,feedURL:value.feedURL}) + '\n');
}
export function stageReleasePublisher(input, bundle) {
  const bytes = publicReleasePublisher(readRegularFile(input, 4096));
  const directory = path.join(bundle, 'Contents/Resources'), info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) blocked('Invalid publisher resource directory');
  fs.writeFileSync(path.join(bundle, publisherMember), bytes, {flag:'wx',mode:0o644});
}
export function auditNativeBundle(bundle) {
  const entries = [];
  function walk(relative) {
    const full = path.join(bundle, relative), before = fs.lstatSync(full);
    if (!before.isDirectory() || before.isSymbolicLink()) blocked('Unexpected app directory', relative || 'CloudNest.app');
    for (const name of fs.readdirSync(full)) {
      const member = relative ? `${relative}/${name}` : name;
      if (directories.has(member)) { walk(member); continue; }
      if (!members.has(member) && member !== publicClientMember && member !== publisherMember) blocked('Unexpected app resource', member);
      const bytes = readRegularFile(path.join(bundle, member), LIMITS.file);
      if (member === publicClientMember) publicGoogleClient(bytes);
      if (member === publisherMember) publicReleasePublisher(bytes);
      auditEntry(member, bytes, { allowBinary: true, compiledBinary: member === 'Contents/MacOS/CloudNest' });
      entries.push({ name: `CloudNest.app/${member}`, bytes, mode: member === 'Contents/MacOS/CloudNest' ? '100755' : '100644' });
    }
    const after = fs.lstatSync(full);
    if (before.ino !== after.ino || before.dev !== after.dev || before.mtimeMs !== after.mtimeMs) blocked('App directory changed', relative || 'CloudNest.app');
  }
  walk('');
  if ([...members].some(member => !entries.some(entry => entry.name === `CloudNest.app/${member}`))) blocked('App bundle is missing required resources');
  return entries.sort((a, b) => a.name.localeCompare(b.name, 'en'));
}
export function auditDmgStage(stage) {
  const root = fs.lstatSync(stage);
  if (!root.isDirectory() || root.isSymbolicLink()) blocked('Invalid DMG stage');
  const names = fs.readdirSync(stage).sort();
  if (names.join('\0') !== ['Applications', 'CloudNest.app', 'READ ME.txt'].join('\0')) blocked('Unexpected DMG stage resource');
  const link = path.join(stage, 'Applications');
  if (!fs.lstatSync(link).isSymbolicLink() || fs.readlinkSync(link) !== '/Applications') blocked('Invalid DMG Applications link');
  auditEntry('READ ME.txt', readRegularFile(path.join(stage, 'READ ME.txt'), 65536));
  return auditNativeBundle(path.join(stage, 'CloudNest.app'));
}
export function packageNativeZip(bundle, output) {
  const entries = auditNativeBundle(bundle);
  const zip = sourceZip(entries);
  auditZip(zip, { allowBinary: true, compiledBinary: true });
  if (fs.existsSync(output)) blocked('Native ZIP output already exists');
  const stage = fs.mkdtempSync(path.join(path.dirname(path.resolve(output)), '.native-release-'));
  try {
    const temporary = path.join(stage, 'candidate.zip');
    fs.writeFileSync(temporary, zip, { mode: 0o600, flag: 'wx' });
    auditZip(fs.readFileSync(temporary), { allowBinary: true, compiledBinary: true });
    fs.linkSync(temporary, output);
  } finally { fs.rmSync(stage, { recursive: true, force: true }); }
  return entries.length;
}
if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args[0] === '--stage-public-client' && args.length === 3) { stagePublicGoogleClient(args[1], args[2]); console.log('Validated public Google client metadata staged.'); }
    else if (args[0] === '--stage-release-publisher' && args.length === 3) { stageReleasePublisher(args[1], args[2]); console.log('Validated public release publisher metadata staged.'); }
    else if (args[0] === '--dmg-stage' && args.length === 2) { auditDmgStage(args[1]); console.log('DMG stage resource allowlist audit passed.'); }
    else {
    if (args.length !== 1 && !(args.length === 3 && args[1] === '--zip')) blocked('Expected APP_PATH [--zip NEW_ZIP_PATH]');
    const count = args[1] ? packageNativeZip(args[0], args[2]) : auditNativeBundle(args[0]).length;
    console.log(`Native resource allowlist audit passed: ${count} regular files.`);
    }
  } catch (error) { cliError(error); }
}
