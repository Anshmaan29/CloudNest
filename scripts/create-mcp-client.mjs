import { randomBytes, createHash } from 'node:crypto';
import { mkdir, realpath, writeFile } from 'node:fs/promises';
import { resolve, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const destination = process.argv[2];
if (!destination || !isAbsolute(destination)) throw new Error('Supply an absolute private directory outside the repository.');
const repo = await realpath(fileURLToPath(new URL('..', import.meta.url)));
// Resolve the parent before creating anything, including symlinked parents.
const parent = await realpath(resolve(destination, '..'));
const directory = resolve(parent, destination.split('/').filter(Boolean).at(-1));
const rel = relative(repo, directory);
if (!(rel === '..' || rel.startsWith('../') || isAbsolute(rel))) throw new Error('Credentials must stay outside the repository.');
await mkdir(directory, { mode: 0o700 }); // Refuse to reuse an existing directory.
const token = randomBytes(32).toString('hex');
const grant = [{ id: 'phase0-reader', sha256: createHash('sha256').update(token).digest('hex'), projects: ['cloudnest'], expiresAt: new Date(Date.now() + 30 * 86400000).toISOString() }];
await writeFile(resolve(directory, 'token.txt'), token + '\n', { mode: 0o600, flag: 'wx' });
await writeFile(resolve(directory, 'clients.json'), JSON.stringify(grant, null, 2), { mode: 0o600, flag: 'wx' });
console.log(`Created private token.txt and clients.json in ${directory}. No token was printed.`);
