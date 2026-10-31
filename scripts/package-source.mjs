// Build from a clean committed Git allowlist; ignored/untracked workspace data is never copied.
import fs from 'node:fs';
import path from 'node:path';
import { auditTree, auditZip, blocked, cliError, git, isMain, readKnownSecrets, readTree, sourceZip } from './release-safety.mjs';

export function packageSource({ repo = process.cwd(), output, knownSecrets = [] } = {}) {
  if (!output) blocked('An explicit new source ZIP output path is required');
  const root = git(repo, ['rev-parse', '--show-toplevel'], 4096).toString().trim();
  const commit = git(root, ['rev-parse', '--verify', 'HEAD^{commit}'], 100).toString().trim();
  if (git(root, ['status', '--porcelain=v1', '--untracked-files=all']).length) blocked('Source packaging requires a clean committed working tree');
  const destination = path.resolve(output);
  if (fs.existsSync(destination)) blocked('Source ZIP output already exists');
  // Every path must be a regular tracked blob, audited before archive creation.
  const entries = auditTree(root, readTree(root, commit), { knownSecrets });
  const zip = sourceZip(entries);
  const names = auditZip(zip, { knownSecrets });
  if (names.size !== entries.length || entries.some(entry => !names.has(entry.name))) blocked('Archive differs from Git allowlist');
  // Recheck after the bounded reads: packaging always names one immutable commit.
  if (git(root, ['status', '--porcelain=v1', '--untracked-files=all']).length || git(root, ['rev-parse', 'HEAD'], 100).toString().trim() !== commit) blocked('Source tree changed during packaging');
  const directory = path.dirname(destination);
  fs.mkdirSync(directory, { recursive: true });
  const stage = fs.mkdtempSync(path.join(directory, '.source-release-'));
  try {
    fs.chmodSync(stage, 0o700);
    const temporary = path.join(stage, 'candidate.zip');
    fs.writeFileSync(temporary, zip, { mode: 0o600, flag: 'wx' });
    // Audit actual staged bytes before atomic no-overwrite publication.
    auditZip(fs.readFileSync(temporary), { knownSecrets });
    fs.linkSync(temporary, destination);
  } finally { fs.rmSync(stage, { recursive: true, force: true }); }
  return { commit, files: entries.length, bytes: zip.length };
}
if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2); let output, secretsFile;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--output' && args[i + 1]) output = args[++i];
      else if (args[i] === '--known-secrets' && args[i + 1]) secretsFile = args[++i];
      else blocked('Expected --output NEW.zip and optional --known-secrets PRIVATE.json');
    }
    const result = packageSource({ output, knownSecrets: readKnownSecrets(secretsFile) });
    console.log(`Audited source ZIP published from commit ${result.commit}: ${result.files} files, ${result.bytes} bytes.`);
  } catch (error) { cliError(error); }
}
