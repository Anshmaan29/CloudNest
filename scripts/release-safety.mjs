// Shared release boundaries. Diagnostics contain rule labels and escaped paths only.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { inflateRawSync } from 'node:zlib';

export const LIMITS = Object.freeze({ file: 16 * 1024 * 1024, total: 128 * 1024 * 1024, archive: 192 * 1024 * 1024, files: 10000 });
const redactions = new Set();
function diagnosticPath(name) {
  let value = String(name).replace(/(?:ya29\.[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|GOCSPX-[A-Za-z0-9_-]{20,})/g, '[REDACTED]');
  for (const secret of redactions) value = value.split(secret).join('[REDACTED]');
  return JSON.stringify(value);
}
export function blocked(rule, name) { throw new Error(`${rule}${name === undefined ? '' : `: ${diagnosticPath(name)}`}`); }
export function readRegularFile(file, maximum, { privateMode = false } = {}) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.size > maximum || (privateMode && (before.mode & 0o077))) blocked('Unsafe bounded file input');
    const bytes = Buffer.alloc(before.size + 1); let length = 0;
    while (length < bytes.length) {
      const count = fs.readSync(fd, bytes, length, bytes.length - length, null);
      if (!count) break;
      length += count;
    }
    const after = fs.fstatSync(fd);
    if (length !== before.size || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) blocked('File changed during bounded read');
    return bytes.subarray(0, length);
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}
export function safeName(name) {
  if (typeof name !== 'string' || !name || Buffer.byteLength(name) > 512 || /[\\:\x00-\x1f\x7f]/.test(name) || name.startsWith('/') || name.split('/').some(part => !part || part === '.' || part === '..') || name.split('/').length > 64) blocked('Unsafe release path');
  return name;
}
const privateName = /(?:^|\/)(?:\.git(?:\/|$)|\.(?:netrc|npmrc)$|node_modules(?:\/|$)|\.build(?:\/|$)|\.wrangler(?:\/|$)|(?:build|dist|exports?|backups?|BrainSetup)(?:\/|$)|\.env(?:\.[^/]*)?$|\.dev\.vars(?:\.[^/]*)?$|[^/]*\.(?:private|local)\.[^/]+$|(?:credentials?|client[_-]?secrets?|secrets?|tokens?|vault[_-]?(?:signing[_-]?)?keys?|signing[_-]?keys?|api[_-]?(?:keys?|tokens?)|owner[_-]?tokens?|connections?|deployments?|authorizations?|google[_-]?(?:account|renewal)|setup)(?:[._-][^/]*)?\.(?:jsonc?|txt|url|ya?ml|toml)$|oauth[^/]*\.json$|[^/]*\.(?:p12|pfx|pem|key|keychain(?:-db)?|sqlite(?:-wal|-shm)?|db(?:-wal|-shm)?|zip|dmg|tar|tgz|gz|7z)$|id_(?:rsa|dsa|ecdsa|ed25519)(?:\.pub)?$)/i;
const exampleName = /(?:^|\/)(?:\.env\.example|\.dev\.vars\.example|[A-Za-z0-9_-]+\.example\.(?:jsonc?|ya?ml|toml))$/;
const rules = [
  ['private key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/],
  ['Google token', /(?:ya29\.[A-Za-z0-9_-]{20,}|1\/\/[A-Za-z0-9_-]{30,}|GOCSPX-[A-Za-z0-9_-]{20,})/],
  ['service token', /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[A-Z0-9]{16})/],
  ['personal home path', /\/(?:Users|home)\/[A-Za-z0-9_.-]+\//],
  ['downloaded OAuth client', /"client_id"\s*:\s*"\d{6,}-[^"\s]+\.apps\.googleusercontent\.com"/],
  ['configured database', /"database_id"\s*:\s*"(?!00000000-0000-0000-0000-000000000000")[a-f0-9-]{36}"/i],
  ['configured account', /"account_id"\s*:\s*"[a-f0-9]{32}"/i],
  ['configured credential', /["'](?:GOOGLE_CLIENT_SECRET|GOOGLE_REFRESH_TOKEN|VAULT_SIGNING_KEY|OWNER_TOKEN|CLOUDFLARE_API_TOKEN|AWS_SECRET_ACCESS_KEY|OPENAI_API_KEY|api_key|ownerToken|refresh_token|access_token|client_secret|private_key)["']\s*:\s*["'][A-Za-z0-9_\/.+=-]{20,}["']/i],
  ['environment credential', /^(?:GOOGLE_CLIENT_SECRET|GOOGLE_REFRESH_TOKEN|VAULT_SIGNING_KEY|OWNER_TOKEN|CLOUDFLARE_API_TOKEN|AWS_SECRET_ACCESS_KEY|OPENAI_API_KEY)[ \t]*=[ \t]*["']?[A-Za-z0-9_\/.+=-]{20,}/im],
];
export function auditEntry(name, bytes, { knownSecrets = [], allowBinary = false, compiledBinary = false } = {}) {
  for (const secret of knownSecrets) redactions.add(secret.toString('utf8'));
  safeName(name);
  if (privateName.test(name) && !exampleName.test(name)) blocked('Private release filename', name);
  if (bytes.length > LIMITS.file) blocked('Release file exceeds size limit', name);
  const source = bytes.toString('utf8');
  for (const [label, pattern] of rules) if (!(compiledBinary && bytes.includes(0) && label === 'personal home path') && pattern.test(source)) blocked(label, name);
  for (const secret of knownSecrets) if (bytes.includes(secret)) blocked('Known private value', name);
  if (!allowBinary && (bytes.includes(0) || !Buffer.from(source).equals(bytes))) blocked('Unexpected binary source file', name);
}
export function git(repo, args, maxBuffer = LIMITS.total) {
  try { return execFileSync('git', args, { cwd: repo, maxBuffer, stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch { blocked('Git snapshot could not be read safely'); }
}
export function readTree(repo, ref = 'HEAD') {
  const raw = git(repo, ['ls-tree', '-rz', '--full-tree', ref]);
  const listing = raw.toString('utf8');
  if (!Buffer.from(listing).equals(raw)) blocked('Git paths must be valid UTF-8');
  return listing.split('\0').filter(Boolean).map(line => {
    const match = /^(\d{6}) (blob|commit) ([a-f0-9]{40,64})\t([\s\S]+)$/.exec(line);
    if (!match) blocked('Unsupported Git tree entry');
    return { mode: match[1], type: match[2], oid: match[3], name: safeName(match[4]) };
  });
}
export function blob(repo, oid, name) {
  const size = Number(git(repo, ['cat-file', '-s', oid], 100).toString());
  if (!Number.isSafeInteger(size) || size < 0 || size > LIMITS.file) blocked('Release file exceeds size limit', name);
  return git(repo, ['cat-file', 'blob', oid], LIMITS.file + 1);
}
export function auditTree(repo, entries, options = {}) {
  if (entries.length > LIMITS.files) blocked('Too many release files');
  let total = 0;
  return entries.map(entry => {
    if (entry.type !== 'blob' || !['100644', '100755'].includes(entry.mode)) blocked('Symlink or submodule forbidden', entry.name);
    const bytes = blob(repo, entry.oid, entry.name);
    total += bytes.length;
    if (total > LIMITS.total) blocked('Release snapshot exceeds size limit');
    auditEntry(entry.name, bytes, options);
    return { ...entry, bytes };
  });
}
export function readKnownSecrets(file) {
  if (!file) return [];
  // Opt-in JSON string array, never follow a symlink or print input/errors.
  try {
    const values = JSON.parse(readRegularFile(file, 131072, { privateMode: true }).toString('utf8'));
    if (!Array.isArray(values) || values.length > 256 || values.some(value => typeof value !== 'string' || value.length < 8 || value.length > 16384)) blocked('Invalid private comparison input');
    for (const value of values) redactions.add(value);
    return values.map(value => Buffer.from(value));
  } catch { blocked('Invalid private comparison input'); }
}

const crcTable = Array.from({ length: 256 }, (_, n) => { for (let i = 0; i < 8; i++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1; return n >>> 0; });
export function crc32(bytes) { let n = 0xffffffff; for (const byte of bytes) n = crcTable[(n ^ byte) & 255] ^ (n >>> 8); return (n ^ 0xffffffff) >>> 0; }
// STORE-only, deterministic ZIP: no extractor, shell interpolation or recursive directory copy.
export function sourceZip(entries) {
  const locals = [], central = []; let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name), bytes = entry.bytes, crc = crc32(bytes);
    const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6); local.writeUInt16LE(33, 12); local.writeUInt32LE(crc, 14); local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(bytes.length, 22); local.writeUInt16LE(name.length, 26);
    const cd = Buffer.alloc(46); cd.writeUInt32LE(0x02014b50); cd.writeUInt16LE(0x314, 4); cd.writeUInt16LE(20, 6); cd.writeUInt16LE(0x800, 8); cd.writeUInt16LE(33, 14); cd.writeUInt32LE(crc, 16); cd.writeUInt32LE(bytes.length, 20); cd.writeUInt32LE(bytes.length, 24); cd.writeUInt16LE(name.length, 28); cd.writeUInt32LE(((entry.mode === '100755' ? 0o100755 : 0o100644) << 16) >>> 0, 38); cd.writeUInt32LE(offset, 42);
    locals.push(local, name, bytes); central.push(cd, name); offset += local.length + name.length + bytes.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
// Audits headers and bounded decompressed bytes. Never extracts archive paths.
export function auditZip(zip, options = {}) {
  if (zip.length < 22 || zip.length > LIMITS.archive) blocked('Invalid archive size');
  const end = zip.length - 22;
  if (zip.readUInt32LE(end) !== 0x06054b50 || zip.readUInt16LE(end + 4) || zip.readUInt16LE(end + 6) || zip.readUInt16LE(end + 20)) blocked('Unsupported ZIP envelope');
  const count = zip.readUInt16LE(end + 10), start = zip.readUInt32LE(end + 16), size = zip.readUInt32LE(end + 12);
  if (!count || count > LIMITS.files || zip.readUInt16LE(end + 8) !== count || start + size !== end) blocked('Invalid ZIP directory');
  const names = new Set(), portableNames = new Set(), parentNames = new Set(); let cursor = start, localEnd = 0, total = 0;
  for (let i = 0; i < count; i++) {
    if (cursor + 46 > end || zip.readUInt32LE(cursor) !== 0x02014b50) blocked('Invalid ZIP entry');
    const flags = zip.readUInt16LE(cursor + 8), method = zip.readUInt16LE(cursor + 10), crc = zip.readUInt32LE(cursor + 16), packed = zip.readUInt32LE(cursor + 20), unpacked = zip.readUInt32LE(cursor + 24), length = zip.readUInt16LE(cursor + 28), extra = zip.readUInt16LE(cursor + 30), comment = zip.readUInt16LE(cursor + 32), external = zip.readUInt32LE(cursor + 38), offset = zip.readUInt32LE(cursor + 42);
    if (cursor + 46 + length + extra + comment > end || flags !== 0x800 || ![0, 8].includes(method) || extra || comment || zip.readUInt16LE(cursor + 34) || unpacked > LIMITS.file || packed > LIMITS.file || (external >>> 16 & 0o170000) !== 0o100000) blocked('Unsupported or oversized ZIP entry');
    const nameBytes = zip.subarray(cursor + 46, cursor + 46 + length), name = safeName(nameBytes.toString('utf8'));
    if (!Buffer.from(name).equals(nameBytes) || names.has(name)) blocked('Duplicate or invalid ZIP path');
    const portable = name.normalize('NFC').toLowerCase();
    const parents = portable.split('/').slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join('/'));
    if (portableNames.has(portable) || parentNames.has(portable) || parents.some(parent => portableNames.has(parent))) blocked('Conflicting portable ZIP path');
    portableNames.add(portable); for (const parent of parents) parentNames.add(parent); names.add(name); total += unpacked;
    if (total > LIMITS.total || offset !== localEnd || offset + 30 > start || zip.readUInt32LE(offset) !== 0x04034b50) blocked('Invalid ZIP bounds');
    if (zip.readUInt16LE(offset + 6) !== flags || zip.readUInt16LE(offset + 8) !== method || zip.readUInt32LE(offset + 14) !== crc || zip.readUInt32LE(offset + 18) !== packed || zip.readUInt32LE(offset + 22) !== unpacked || zip.readUInt16LE(offset + 26) !== length || zip.readUInt16LE(offset + 28)) blocked('ZIP header mismatch');
    const dataStart = offset + 30 + length; localEnd = dataStart + packed;
    if (localEnd > start || !zip.subarray(offset + 30, dataStart).equals(nameBytes)) blocked('ZIP path or data mismatch');
    let bytes;
    try { bytes = method === 0 ? zip.subarray(dataStart, localEnd) : inflateRawSync(zip.subarray(dataStart, localEnd), { maxOutputLength: Math.min(LIMITS.file, unpacked + 1) }); }
    catch { blocked('Invalid compressed ZIP data', name); }
    if (bytes.length !== unpacked || crc32(bytes) !== crc) blocked('ZIP content integrity mismatch', name);
    auditEntry(name, bytes, options); cursor += 46 + length;
  }
  if (cursor !== end || localEnd !== start) blocked('Unexpected ZIP trailing data');
  return names;
}
export function cliError(error) { console.error(`Release blocked: ${error instanceof Error && !error.code ? error.message : 'Operation failed safely'}`); process.exitCode = 1; }
export function isMain(url) { return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(url); }
