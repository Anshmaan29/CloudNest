// Audit the Git index (default), HEAD, or all reachable public history.
// Never inspect arbitrary workspace/private files or print matched values.
import { auditTree, blocked, cliError, git, isMain, readKnownSecrets, readTree } from './release-safety.mjs';

export function auditSource({ repo = process.cwd(), history = false, head = false, knownSecrets = [] } = {}) {
  let files = 0;
  if (history) {
    const shallow = git(repo, ['rev-parse', '--is-shallow-repository'], 100).toString().trim();
    if (shallow !== 'false') blocked('History audit requires a complete Git checkout');
    const commits = git(repo, ['rev-list', '--all'], 1024 * 1024).toString().trim().split('\n').filter(Boolean);
    if (!commits.length || commits.length > 5000) blocked('History exceeds audit commit limit');
    const seen = new Set(); let total = 0;
    for (const commit of commits) {
      const entries = readTree(repo, commit).filter(entry => {
        const identity = `${entry.mode}:${entry.oid}:${entry.name}`;
        if (seen.has(identity)) return false;
        seen.add(identity); return true;
      });
      if (seen.size > 50000) blocked('History exceeds audit entry limit');
      const audited = auditTree(repo, entries, { knownSecrets });
      total += audited.reduce((sum, entry) => sum + entry.bytes.length, 0);
      if (total > 1024 * 1024 * 1024) blocked('History exceeds audit byte limit');
      files += entries.length;
    }
    return { files, commits: commits.length };
  }
  const rawIndex = head ? undefined : git(repo, ['ls-files', '--stage', '-z']);
  const index = rawIndex?.toString('utf8');
  if (rawIndex && !Buffer.from(index).equals(rawIndex)) blocked('Git paths must be valid UTF-8');
  const entries = head ? readTree(repo) : index.split('\0').filter(Boolean).map(line => {
    const match = /^(\d{6}) ([a-f0-9]{40,64}) (\d)\t([\s\S]+)$/.exec(line);
    if (!match || match[3] !== '0') blocked('Unmerged or unsupported Git index');
    return { mode: match[1], type: 'blob', oid: match[2], name: match[4] };
  });
  auditTree(repo, entries, { knownSecrets });
  return { files: entries.length };
}
if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2); let history = false, head = false, secretsFile;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--history') history = true;
      else if (args[i] === '--head') head = true;
      else if (args[i] === '--known-secrets' && args[i + 1]) secretsFile = args[++i];
      else blocked('Unknown source audit option');
    }
    const result = auditSource({ history, head, knownSecrets: readKnownSecrets(secretsFile) });
    console.log(`Public-source audit passed for ${result.files} Git entries${history ? ` across ${result.commits} reachable commits` : ''}. Pattern checks do not guarantee absence of every secret.`);
  } catch (error) { cliError(error); }
}
