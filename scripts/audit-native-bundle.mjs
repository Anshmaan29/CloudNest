// Native distribution resource boundary; never recursively copy the build directory.
import fs from 'node:fs';
import path from 'node:path';
import { auditEntry, auditZip, blocked, cliError, isMain, LIMITS, readRegularFile, sourceZip } from './release-safety.mjs';

const members = new Set(['Contents/Info.plist', 'Contents/MacOS/CloudNest', 'Contents/Resources/CloudNest.icns', 'Contents/_CodeSignature/CodeResources']);
const directories = new Set(['', 'Contents', 'Contents/MacOS', 'Contents/Resources', 'Contents/_CodeSignature']);
export function auditNativeBundle(bundle) {
  const entries = [];
  function walk(relative) {
    const full = path.join(bundle, relative), before = fs.lstatSync(full);
    if (!before.isDirectory() || before.isSymbolicLink()) blocked('Unexpected app directory', relative || 'CloudNest.app');
    for (const name of fs.readdirSync(full)) {
      const member = relative ? `${relative}/${name}` : name;
      if (directories.has(member)) { walk(member); continue; }
      if (!members.has(member)) blocked('Unexpected app resource', member);
      const bytes = readRegularFile(path.join(bundle, member), LIMITS.file);
      auditEntry(member, bytes, { allowBinary: true, compiledBinary: member === 'Contents/MacOS/CloudNest' });
      entries.push({ name: `CloudNest.app/${member}`, bytes, mode: member === 'Contents/MacOS/CloudNest' ? '100755' : '100644' });
    }
    const after = fs.lstatSync(full);
    if (before.ino !== after.ino || before.dev !== after.dev || before.mtimeMs !== after.mtimeMs) blocked('App directory changed', relative || 'CloudNest.app');
  }
  walk('');
  if (entries.length !== members.size) blocked('App bundle is missing required resources');
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
    if (args[0] === '--dmg-stage' && args.length === 2) { auditDmgStage(args[1]); console.log('DMG stage resource allowlist audit passed.'); }
    else {
    if (args.length !== 1 && !(args.length === 3 && args[1] === '--zip')) blocked('Expected APP_PATH [--zip NEW_ZIP_PATH]');
    const count = args[1] ? packageNativeZip(args[0], args[2]) : auditNativeBundle(args[0]).length;
    console.log(`Native resource allowlist audit passed: ${count} regular files.`);
    }
  } catch (error) { cliError(error); }
}
