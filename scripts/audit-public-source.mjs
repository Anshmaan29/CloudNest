// Inspect the Git index, including files staged for the next public checkpoint.
// Report rule names and paths only; never echo a suspected secret's value.
import { execFileSync } from 'node:child_process';

const paths = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const forbiddenName = /(?:^|\/)(?:\.dev\.vars(?!\.example$)|\.env(?!\.example$)|client_secret[^/]*\.json$|credentials[^/]*\.json$|[^/]*\.local\.jsonc$|token\.txt$|catalog\.sqlite(?:-wal|-shm)?$)/i;
const rules = [
  ['private key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ['Google token', /(?:ya29\.[A-Za-z0-9_-]{20,}|1\/\/[A-Za-z0-9_-]{30,})/],
  ['service token', /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})/],
  ['personal home path', /\/Users\/[A-Za-z0-9_.-]+\//],
  ['downloaded OAuth client', /"client_id"\s*:\s*"\d{6,}-[^"\s]+\.apps\.googleusercontent\.com"/],
  ['configured database', /"database_id"\s*:\s*"(?!00000000-0000-0000-0000-000000000000")[a-f0-9-]{36}"/i],
  ['configured account', /"account_id"\s*:\s*"[a-f0-9]{32}"/i],
];
let failures = 0;
for (const path of paths) {
  if (forbiddenName.test(path)) { console.error(`Private configuration staged: ${path}`); failures++; continue; }
  const bytes = execFileSync('git', ['show', `:${path}`], { maxBuffer: 16 * 1024 * 1024 });
  const source = bytes.toString('utf8');
  for (const [label, pattern] of rules) if (pattern.test(source)) {
    console.error(`Public-source audit: ${label} in ${path}`); failures++;
  }
}
if (failures) { console.error(`Blocked ${failures} potential privacy leak(s). Review locally before publishing.`); process.exitCode = 1; }
else console.log(`Public-source audit passed for ${paths.length} staged files. This is a guard, not a complete secret detector.`);
