import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
import {auth} from '@modelcontextprotocol/sdk/client/auth.js';
import {Client as MCPClient} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
const {unstable_splitSqlQuery:split}=wrangler;
const issuer='https://brain.example',callback='https://client.example/callback',owner=randomBytes(32).toString('hex');
const hash=s=>createHash('sha256').update(s).digest('hex');
let script,runtime,db;
before(async()=>{script=(await build({entryPoints:['brain/worker/index.ts'],bundle:true,write:false,format:'esm',target:'es2022'})).outputFiles[0].text;});
async function start(extra={}){
  runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',host:'127.0.0.1',port:0,cf:false,d1Databases:{DB:'oauth-test'},
    // Every Google/network transport is explicitly forbidden in these OAuth tests.
    outboundService:()=>{throw new Error('OAuth must not fetch any client URL or external provider');},
    serviceBindings:{ASSETS:async()=>new Response('public shell',{headers:{'Content-Type':'text/html'}})},
    bindings:{PUBLIC_ORIGIN:issuer,ALLOWED_ORIGINS:issuer,OWNER_TOKEN_SHA256:hash(owner),CLIENTS_JSON:'[]',BRAIN_ENABLED:'true',VAULT_SIGNING_KEY:randomBytes(32).toString('hex'),GOOGLE_CLIENT_ID:'fixture.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fixture-not-a-live-client',GOOGLE_REFRESH_TOKEN:'fixture-not-a-live-refresh-token',...extra}}));
  await runtime.ready;db=await runtime.getD1Database('DB');
  for(const file of ['0001_feasibility.sql','0002_canonical.sql','0003_oauth.sql'])await db.batch(split(await readFile('brain/migrations/'+file,'utf8')).map(s=>db.prepare(s)));
  await db.prepare("INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at,canonical_drive_id) VALUES('approved','project','Approved fixture','Approved memory only','fixture:oauth',1,'approved',?,'fixture-drive-id'),('private','project','Private fixture','Never disclose','fixture:oauth',1,'private',?,'fixture-private-id'),('outside','other','Other project','Never cross project','fixture:oauth',1,'approved',?,'fixture-other-id')").bind(new Date().toISOString(),new Date().toISOString(),new Date().toISOString()).run();
}
beforeEach(()=>start());afterEach(async()=>{await runtime?.dispose();});
const req=(path,init={})=>runtime.dispatchFetch(path.startsWith('http')?path:issuer+path,{redirect:'manual',...init});
const api=(path,method='GET',body,token=owner,origin=issuer)=>req('/api/v1'+path,{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Origin:origin},...(body===undefined?{}:{body:JSON.stringify(body)})});
async function success(response){const data=await response.json();assert.ok(response.ok,JSON.stringify({status:response.status,data}));return data;}
async function register(extra={}){return success(await req('/oauth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Unverified test client',redirect_uris:[callback],token_endpoint_auth_method:'none',...extra})}));}
function pkce(){const verifier=randomBytes(32).toString('base64url');return{verifier,challenge:createHash('sha256').update(verifier).digest('base64url')};}
async function consent(client,extra={}){
  const key=pkce(),params=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:client.redirect_uris[0],resource:issuer+'/mcp',code_challenge:key.challenge,code_challenge_method:'S256',scope:'memory:read',state:randomBytes(16).toString('hex'),...extra});
  const response=await req('/oauth/authorize?'+params);assert.equal(response.status,302);const target=new URL(response.headers.get('Location'));
  return{...key,id:target.hash.slice('#authorize='.length),params,response,target};
}
async function approved(client,permissions=[],scope='memory:read'){
  const pending=await consent(client,{scope});const result=await success(await api('/oauth/requests/'+pending.id+'/approve','POST',{projects:['project'],permissions}));
  return{...pending,...result,code:new URL(result.redirectUrl).searchParams.get('code')};
}
const exchange=(client,flow,extra={})=>req('/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'authorization_code',client_id:client.client_id,code:flow.code,redirect_uri:client.redirect_uris[0],code_verifier:flow.verifier,resource:issuer+'/mcp',...extra})});
const refresh=(client,token,extra={})=>req('/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',client_id:client.client_id,refresh_token:token,resource:issuer+'/mcp',...extra})});
const mcp=(token,method='tools/call',params={name:'memory_recent',arguments:{}},origin)=>req('/mcp',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream',...(origin?{Origin:origin}:{})},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});

test('OAuth discovery and challenge bind the configured issuer and exact resource',async()=>{
  const resource=await success(await req('/.well-known/oauth-protected-resource/mcp'));assert.equal(resource.resource,issuer+'/mcp');assert.deepEqual(resource.authorization_servers,[issuer]);
  const server=await success(await req('/.well-known/oauth-authorization-server'));assert.equal(server.issuer,issuer);assert.deepEqual(server.code_challenge_methods_supported,['S256']);assert.equal(server.client_id_metadata_document_supported,false);
  const missing=await req('/mcp');assert.equal(missing.status,401);assert.match(missing.headers.get('WWW-Authenticate'),/oauth-protected-resource\/mcp/);
  assert.equal((await req('https://attacker.example/.well-known/oauth-authorization-server')).status,403);
});
test('OAuth never derives discovery or audience from an unconfigured Host',async()=>{
  await runtime.dispose();await start({PUBLIC_ORIGIN:''});assert.equal((await req('/.well-known/oauth-authorization-server')).status,503);assert.equal((await req('/oauth/register',{method:'POST'})).status,503);
});
test('public registration accepts HTTPS and loopback redirects without fetching metadata',async()=>{
  const client=await register({redirect_uris:[callback,'http://127.0.0.1:4567/callback','http://[::1]:4567/callback','http://localhost:4567/callback'],logo_uri:'https://169.254.169.254/metadata'});
  assert.equal(client.token_endpoint_auth_method,'none');assert.ok(client.client_id);assert.equal(client.client_secret,undefined);
  const row=await db.prepare('SELECT * FROM oauth_clients WHERE id=?').bind(client.client_id).first();assert.equal(row.name,'Unverified test client');
});
test('redirects reject plaintext remote hosts, userinfo, fragments, wildcards and malformed input',async()=>{
  for(const uri of ['http://remote.example/callback','https://user:password@client.example/callback','https://client.example/callback#fragment','https://*.example/callback','file:///tmp/return','https://client.example/\ncallback','https://client.example\\@attacker.example/callback']){
    const response=await req('/oauth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({redirect_uris:[uri]})});assert.equal(response.status,400,uri);
  }
});
test('authorization requires S256 and exact registered redirect/resource and never auto-approves',async()=>{
  const client=await register();for(const override of [{code_challenge_method:'plain'},{resource:issuer+'/other'},{scope:'memory:write'}]){
    const flow=await consent(client,override);assert.equal(flow.target.origin,new URL(callback).origin);assert.ok(flow.target.searchParams.get('error'));assert.equal(flow.target.searchParams.get('code'),null);
  }
  const key=pkce(),params=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:'https://evil.example/callback',resource:issuer+'/mcp',code_challenge:key.challenge,code_challenge_method:'S256'});
  const bad=await req('/oauth/authorize?'+params);assert.equal(bad.status,400);assert.equal(bad.headers.get('Location'),null);
  const pending=await consent(client);assert.equal(pending.target.origin,issuer);const row=await db.prepare('SELECT * FROM oauth_requests WHERE id=?').bind(pending.id).first();assert.equal(row.status,'pending');assert.equal(row.code_hash,null);assert.equal((await db.prepare('SELECT count(*) n FROM oauth_grants').first()).n,0);
});
test('owner consent issues one project-scoped code, then real MCP reads only approved authorized data',async()=>{
  const client=await register(),flow=await approved(client),callbackURL=new URL(flow.redirectUrl);assert.equal(callbackURL.searchParams.get('state'),flow.params.get('state'));assert.equal(callbackURL.searchParams.get('iss'),issuer);assert.ok(flow.code);
  const token=await success(await exchange(client,flow));assert.equal(token.scope,'memory:read');assert.equal(token.expires_in,300);
  const data=await success(await mcp(token.access_token));assert.deepEqual(JSON.parse(data.result.content[0].text).memories.map(m=>m.id),['approved']);
  assert.equal((await api('/oauth/grants','GET',undefined,token.access_token)).status,401);
  const grants=(await success(await api('/oauth/grants'))).grants;assert.equal(grants[0].id,flow.grantId);assert.equal(grants[0].clientId,client.client_id);assert.ok(grants[0].lastSeen);assert.deepEqual(grants[0].permissions,[]);
  const all=(await success(await api('/clients'))).clients;assert.equal(all.find(c=>c.id===flow.grantId).oauth,true);
});
test('OAuth consent works before Google is configured and does not enable canonical mode',async()=>{
  await runtime.dispose();await start({BRAIN_ENABLED:'false',GOOGLE_REFRESH_TOKEN:''});const client=await register(),flow=await approved(client),token=await success(await exchange(client,flow));assert.equal((await mcp(token.access_token)).status,200);assert.equal((await success(await req('/health'))).canonicalConfigured,false);assert.equal((await success(await req('/health'))).readyForPersonalData,false);
});
test('only hashes of authorization codes and access/refresh credentials are persisted',async()=>{
  const client=await register(),flow=await approved(client),token=await success(await exchange(client,flow));
  const request=await db.prepare('SELECT * FROM oauth_requests WHERE id=?').bind(flow.id).first();assert.equal(request.code_hash,hash(flow.code));
  const a=await db.prepare('SELECT * FROM oauth_access').first(),r=await db.prepare('SELECT * FROM oauth_refresh').first();assert.equal(a.hash,hash(token.access_token));assert.equal(r.hash,hash(token.refresh_token));
  const audit=JSON.stringify((await db.prepare('SELECT * FROM audit').all()).results);for(const raw of [owner,flow.code,flow.verifier,token.access_token,token.refresh_token])assert.ok(!audit.includes(raw));
});
test('owner approval is explicit, rejects hostile origins and never expands requested scopes',async()=>{
  const client=await register(),pending=await consent(client);const path='/oauth/requests/'+pending.id+'/approve';
  assert.equal((await api(path,'POST',{projects:['project']},owner,'https://evil.example')).status,403);
  assert.equal((await api(path,'POST',{projects:['project']},'not-owner'.repeat(8))).status,401);
  assert.equal((await api(path,'POST',{projects:['project'],permissions:['propose']})).status,400);
  assert.equal((await api(path,'POST',{projects:[]})).status,400);assert.equal((await api(path,'POST',{projects:['../private']})).status,400);
});
test('denied and expired consent cannot produce usable authorization codes',async()=>{
  const client=await register(),pending=await consent(client),denied=await success(await api('/oauth/requests/'+pending.id+'/deny','POST',{}));assert.equal(new URL(denied.redirectUrl).searchParams.get('error'),'access_denied');assert.equal((await api('/oauth/requests/'+pending.id+'/approve','POST',{projects:['project']})).status,409);
  const expired=await consent(client);await db.prepare('UPDATE oauth_requests SET expires_at=0 WHERE id=?').bind(expired.id).run();assert.equal((await api('/oauth/requests/'+expired.id+'/approve','POST',{projects:['project']})).status,409);
});
test('concurrent owner approvals create exactly one grant and one callback code',async()=>{
  const client=await register(),pending=await consent(client),responses=await Promise.all([api('/oauth/requests/'+pending.id+'/approve','POST',{projects:['project']}),api('/oauth/requests/'+pending.id+'/approve','POST',{projects:['other']})]);assert.deepEqual(responses.map(r=>r.status).sort(),[200,409]);assert.equal((await db.prepare('SELECT count(*) n FROM oauth_grants').first()).n,1);
});
test('wrong verifier/client/redirect/resource cannot consume an authorization code',async()=>{
  const client=await register(),flow=await approved(client),other=await register();for(const override of [{code_verifier:'x'.repeat(43)},{client_id:other.client_id},{redirect_uri:'https://evil.example/callback'},{resource:issuer+'/other'}])assert.equal((await exchange(client,flow,override)).status,400);
  assert.equal((await exchange(client,flow)).status,200);
});
test('expired codes and access tokens fail closed',async()=>{
  const client=await register(),flow=await approved(client);await db.prepare('UPDATE oauth_requests SET code_expires_at=0 WHERE id=?').bind(flow.id).run();assert.equal((await exchange(client,flow)).status,400);
  const next=await approved(client),token=await success(await exchange(client,next));await db.prepare('UPDATE oauth_access SET expires_at=0').run();assert.equal((await mcp(token.access_token)).status,401);
});
test('code reuse and concurrent exchanges revoke the resulting token family',async()=>{
  const client=await register(),flow=await approved(client),responses=await Promise.all([exchange(client,flow),exchange(client,flow)]);assert.deepEqual(responses.map(r=>r.status).sort(),[200,400]);const token=await responses.find(r=>r.ok).json();assert.equal((await mcp(token.access_token)).status,401);
  const next=await approved(client),issued=await success(await exchange(client,next));assert.equal((await exchange(client,next)).status,400);assert.equal((await mcp(issued.access_token)).status,401);
});
test('rotating refresh tokens work once and replay revokes all descendant access tokens',async()=>{
  const client=await register(),flow=await approved(client),first=await success(await exchange(client,flow)),second=await success(await refresh(client,first.refresh_token));assert.notEqual(second.refresh_token,first.refresh_token);assert.equal((await mcp(second.access_token)).status,200);
  assert.equal((await refresh(client,first.refresh_token)).status,400);assert.equal((await mcp(first.access_token)).status,401);assert.equal((await mcp(second.access_token)).status,401);assert.equal((await refresh(client,second.refresh_token)).status,400);
});
test('concurrent refresh exchanges detect replay and revoke the complete grant',async()=>{
  const client=await register(),flow=await approved(client),first=await success(await exchange(client,flow)),responses=await Promise.all([refresh(client,first.refresh_token),refresh(client,first.refresh_token)]);assert.deepEqual(responses.map(r=>r.status).sort(),[200,400]);const issued=await responses.find(r=>r.ok).json();assert.equal((await mcp(issued.access_token)).status,401);
});
test('propose is opt-in, enters Inbox only, and refresh scope narrowing cannot be reversed',async()=>{
  const client=await register(),flow=await approved(client,['propose'],'memory:read memory:propose'),first=await success(await exchange(client,flow));
  const tools=await success(await mcp(first.access_token,'tools/list',{}));assert.ok(tools.result.tools.some(t=>t.name==='memory_propose'));
  const result=await success(await mcp(first.access_token,'tools/call',{name:'memory_propose',arguments:{project:'project',title:'Needs approval',body:'Proposal only',source:'fixture:oauth'}}));assert.ok(!result.result.isError);assert.equal((await db.prepare("SELECT count(*) n FROM brain_inbox WHERE status='pending'").first()).n,1);assert.equal((await db.prepare('SELECT count(*) n FROM brain_heads').first()).n,0);
  const narrow=await success(await refresh(client,first.refresh_token,{scope:'memory:read'}));assert.equal(narrow.scope,'memory:read');const limited=await success(await mcp(narrow.access_token,'tools/list',{}));assert.ok(!limited.result.tools.some(t=>t.name==='memory_propose'));assert.equal((await refresh(client,narrow.refresh_token,{scope:'memory:read memory:propose'})).status,400);
});
test('requesting propose without owner opt-in still yields read-only tokens',async()=>{
  const client=await register(),flow=await approved(client,[],'memory:read memory:propose'),token=await success(await exchange(client,flow));assert.equal(token.scope,'memory:read');const tools=await success(await mcp(token.access_token,'tools/list',{}));assert.ok(!tools.result.tools.some(t=>t.name==='memory_propose'));
});
test('owner/client revocation and replacement consent invalidate earlier grants',async()=>{
  const client=await register(),flow=await approved(client),first=await success(await exchange(client,flow));assert.equal((await api('/oauth/grants/'+flow.grantId+'/revoke','POST',{})).status,200);assert.equal((await mcp(first.access_token)).status,401);
  const next=await approved(client),second=await success(await exchange(client,next));const replacement=await approved(client);assert.equal((await mcp(second.access_token)).status,401);const third=await success(await exchange(client,replacement));
  const revoke=token=>req('/oauth/revoke',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:client.client_id,token})});assert.equal((await revoke(third.refresh_token)).status,200);assert.equal((await mcp(third.access_token)).status,401);assert.equal((await revoke('unknown-token')).status,200);
});
test('CORS accepts only origins bound to the approved OAuth client and token',async()=>{
  const client=await register(),flow=await approved(client),token=await success(await exchange(client,flow));assert.equal((await mcp(token.access_token,'tools/list',{},'https://evil.example')).status,403);
  const origin=new URL(callback).origin,allowed=await mcp(token.access_token,'tools/list',{},origin);assert.equal(allowed.status,200);assert.equal(allowed.headers.get('Access-Control-Allow-Origin'),origin);
  const preflight=await req('/mcp',{method:'OPTIONS',headers:{Origin:origin,'Access-Control-Request-Method':'POST'}});assert.equal(preflight.status,204);assert.equal(preflight.headers.get('Access-Control-Allow-Origin'),origin);assert.equal((await req('/mcp',{method:'OPTIONS',headers:{Origin:'https://evil.example'}})).status,403);
  const other=await register({redirect_uris:['https://other-client.example/callback']});await approved(other);assert.equal((await mcp(token.access_token,'tools/list',{},'https://other-client.example')).status,403);
  await db.prepare('UPDATE oauth_access SET expires_at=0 WHERE hash=?').bind(hash(token.access_token)).run();const expired=await mcp(token.access_token,'tools/list',{},origin);assert.equal(expired.status,401);assert.equal(expired.headers.get('Access-Control-Allow-Origin'),origin);assert.match(expired.headers.get('WWW-Authenticate'),/resource_metadata/);
  const invalid=await req('/oauth/token',{method:'POST',headers:{Origin:origin,'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',client_id:client.client_id,resource:issuer+'/mcp',refresh_token:'invalid'})});assert.equal(invalid.status,400);assert.equal(invalid.headers.get('Access-Control-Allow-Origin'),origin);
});
test('token and registration size/duplicate/rate limits are enforced on the server',async()=>{
  assert.equal((await req('/oauth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({redirect_uris:[callback],client_name:'x'.repeat(9000)})})).status,400);
  const body='grant_type=authorization_code&client_id=a&client_id=b&resource='+encodeURIComponent(issuer+'/mcp');assert.equal((await req('/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body})).status,400);
  assert.equal((await req('/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'x='.padEnd(17000,'x')})).status,413);
  await db.prepare('DELETE FROM brain_rate_limits').run();for(let i=0;i<10;i++)await register();assert.equal((await req('/oauth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({redirect_uris:[callback]})})).status,429);
});
test('audit failure rolls back approval and prevents credential issuance',async()=>{
  const client=await register(),flow=await consent(client);await db.prepare('DROP TABLE audit').run();assert.equal((await api('/oauth/requests/'+flow.id+'/approve','POST',{projects:['project']})).status,503);assert.equal((await db.prepare('SELECT status FROM oauth_requests WHERE id=?').bind(flow.id).first()).status,'pending');assert.equal((await db.prepare('SELECT count(*) n FROM oauth_grants').first()).n,0);
});
test('static asset whitelist serves only public shell paths with strict CSP',async()=>{
  for(const path of ['/','/console.js','/console.css','/chunks/graph-ABC.js']){const response=await req(path);assert.equal(response.status,200);assert.match(response.headers.get('Content-Security-Policy'),/frame-ancestors 'none'/);assert.match(response.headers.get('Content-Security-Policy'),/script-src 'self'/);assert.equal(response.headers.get('Referrer-Policy'),'no-referrer');assert.equal(response.headers.get('Cache-Control'),'no-store');}
  for(const path of ['/secrets.json','/index.html','/chunks/private.json','/chunks/a/b.js'])assert.equal((await req(path)).status,404);assert.equal((await req('/api/v1/memories')).status,401);
});
test('official MCP SDK performs discovery, DCR, PKCE exchange, approved read and automatic refresh',async()=>{
  let information,saved,verifier,authorization;
  const provider={redirectUrl:callback,clientMetadata:{client_name:'Official SDK fixture',redirect_uris:[callback],token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code'],scope:'memory:read'},
    state:()=>randomBytes(16).toString('hex'),clientInformation:()=>information,saveClientInformation:v=>{information=v;},tokens:()=>saved,saveTokens:v=>{saved=v;},saveCodeVerifier:v=>{verifier=v;},codeVerifier:()=>verifier,redirectToAuthorization:url=>{authorization=url;}};
  const fetchFn=(url,init)=>runtime.dispatchFetch(String(url),{...init,redirect:'manual'}),serverUrl=new URL(issuer+'/mcp');
  assert.equal(await auth(provider,{serverUrl,fetchFn}),'REDIRECT');assert.ok(authorization);assert.ok(verifier);
  const request=await req(String(authorization)),id=new URL(request.headers.get('Location')).hash.slice('#authorize='.length);const ownerDecision=await success(await api('/oauth/requests/'+id+'/approve','POST',{projects:['project']})),code=new URL(ownerDecision.redirectUrl).searchParams.get('code');
  assert.equal(await auth(provider,{serverUrl,authorizationCode:code,fetchFn}),'AUTHORIZED');assert.equal(saved.scope,'memory:read');
  const client=new MCPClient({name:'cloudnest-oauth-test',version:'1.0.0'}),transport=new StreamableHTTPClientTransport(serverUrl,{authProvider:provider,fetch:fetchFn});
  try{await client.connect(transport);const first=await client.callTool({name:'memory_recent',arguments:{}});assert.deepEqual(JSON.parse(first.content[0].text).memories.map(m=>m.id),['approved']);
    const old=saved.refresh_token;await db.prepare('UPDATE oauth_access SET expires_at=0').run();const after=await client.callTool({name:'memory_recent',arguments:{}});assert.equal(after.isError,undefined);assert.notEqual(saved.refresh_token,old);assert.deepEqual(JSON.parse(after.content[0].text).memories.map(m=>m.id),['approved']);
  }finally{await client.close();}
});
test('bounded housekeeping preserves active replay evidence and eventually frees expired client capacity',async()=>{
  const client=await register(),flow=await approved(client),first=await success(await exchange(client,flow));await success(await refresh(client,first.refresh_token));
  await db.prepare('UPDATE oauth_access SET expires_at=0 WHERE hash=?').bind(hash(first.access_token)).run();await register();assert.equal(await db.prepare('SELECT hash FROM oauth_access WHERE hash=?').bind(hash(first.access_token)).first(),null);assert.ok(await db.prepare('SELECT hash FROM oauth_refresh WHERE hash=?').bind(hash(first.refresh_token)).first());assert.equal((await refresh(client,first.refresh_token)).status,400);
  const old=Date.now()-8*86400000;await db.batch([db.prepare('UPDATE oauth_grants SET expires_at=?').bind(old),db.prepare('UPDATE oauth_refresh SET expires_at=?').bind(old),db.prepare('UPDATE oauth_access SET expires_at=?').bind(old),db.prepare('UPDATE oauth_requests SET expires_at=?').bind(old),db.prepare('UPDATE oauth_clients SET created_at=?,last_used_at=?').bind(old,old)]);
  await register();assert.equal(await db.prepare('SELECT id FROM oauth_clients WHERE id=?').bind(client.client_id).first(),null);assert.equal((await db.prepare('SELECT count(*) n FROM oauth_grants').first()).n,0);assert.ok((await db.prepare('SELECT count(*) n FROM audit').first()).n>0);
});
test('rotation budget requires renewed owner consent without counting every stored refresh row',async()=>{
  const client=await register(),flow=await approved(client),token=await success(await exchange(client,flow));await db.prepare('UPDATE oauth_grants SET rotation_count=10000 WHERE id=?').bind(flow.grantId).run();assert.equal((await refresh(client,token.refresh_token)).status,400);assert.equal((await mcp(token.access_token)).status,401);
});
test('refresh replay keeps the family revoked even if the audit sink fails and is later repaired',async()=>{
  const client=await register(),flow=await approved(client),first=await success(await exchange(client,flow)),second=await success(await refresh(client,first.refresh_token));await db.prepare('DROP TABLE audit').run();assert.equal((await refresh(client,first.refresh_token)).status,503);
  const grant=await db.prepare('SELECT revoked,revocation_reason FROM oauth_grants WHERE id=?').bind(flow.grantId).first();assert.equal(grant.revoked,1);assert.equal(grant.revocation_reason,'oauth_refresh_replay_revoked');
  await db.prepare("CREATE TABLE audit(id INTEGER PRIMARY KEY,client_id TEXT NOT NULL,action TEXT NOT NULL,memory_id TEXT,created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))").run();assert.equal((await mcp(second.access_token)).status,401);
});
