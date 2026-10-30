import { readFile, stat } from 'node:fs/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const [address, tokenFile, query = 'verification'] = process.argv.slice(2);
if (!address || !tokenFile) throw new Error('Usage: node scripts/probe-mcp.mjs HTTPS_MCP_URL PRIVATE_TOKEN_FILE QUERY');
const endpoint = new URL(address);
if (endpoint.protocol !== 'https:' && endpoint.hostname !== '127.0.0.1') throw new Error('Use HTTPS (or local 127.0.0.1).');
const info = await stat(tokenFile);
if (info.mode & 0o077) throw new Error('Token file must have private permissions (chmod 600).');
const token = (await readFile(tokenFile, 'utf8')).trim();
if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Expected the generated 256-bit token.');
const client = new Client({ name: 'cloudnest-live-probe', version: '0.1.0' });
try {
  await client.connect(new StreamableHTTPClientTransport(endpoint, { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  const result = await client.callTool({ name: 'memory_search', arguments: { query, project: 'cloudnest' } });
  if (result.isError) throw new Error('Memory retrieval failed.');
  const records = JSON.parse(result.content[0].text).memories;
  if (!records.length) throw new Error('Authenticated, but no disposable test memory matched.');
  console.log(`Authenticated MCP search passed: ${records.length} record(s). External AI validation is still separate.`);
} catch {
  console.error('MCP probe did not pass. Check deployment, grant expiry, protocol and disposable test data. No credentials were printed.');
  process.exitCode = 1;
} finally { await client.close(); }
