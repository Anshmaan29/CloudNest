import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createHash,randomBytes} from 'node:crypto';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
const origin='https://brain.example.test',owner=randomBytes(32).toString('hex'),token=randomBytes(32).toString('hex');
const hash=x=>createHash('sha256').update(x).digest('hex');
let script,runtime,db;
before(async()=>{script=(await build({entryPoints:['brain/worker/index.ts'],bundle:true,write:false,format:'esm',target:'es2022'})).outputFiles[0].text;});
beforeEach(async()=>{
 runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',cf:false,d1Databases:{DB:'router-auth'},bindings:{BRAIN_ENABLED:'true',PUBLIC_ORIGIN:origin,ALLOWED_ORIGINS:'',OWNER_TOKEN_SHA256:hash(owner),CLIENTS_JSON:'[]',VAULT_SIGNING_KEY:hash('fixture-vault-key'),GOOGLE_CLIENT_ID:'synthetic.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fixture-secret',GOOGLE_REFRESH_TOKEN:'fixture-refresh'}}));
 db=await runtime.getD1Database('DB');
 for(const name of (await readdir('brain/migrations')).filter(x=>x.endsWith('.sql')).sort())await db.batch(wrangler.unstable_splitSqlQuery(await readFile('brain/migrations/'+name,'utf8')).map(sql=>db.prepare(sql)));
});
afterEach(async()=>runtime?.dispose());
const call=(path,init={})=>runtime.dispatchFetch(origin+'/api/v1'+path,init);
async function seedSession(){
 const now=Date.now();
 await db.prepare('INSERT INTO brain_browser_passkeys(id,epoch,public_key,counter,label,transports,created_at) VALUES(?,?,?,?,?,?,?)').bind('fixture-key',hash(owner),'unused',0,'Fixture','[]',now).run();
 await db.prepare('INSERT INTO brain_browser_sessions VALUES(?,?,?,?,?,?,?)').bind('fixture-session',hash(token),hash(owner),'fixture-key',now,now+60000,now+60000).run();
}
test('production router exposes bootstrap without owner secret but protects ordinary REST',async()=>{
 const response=await call('/auth/session',{headers:{Origin:origin,'Sec-Fetch-Site':'same-origin'}});
 assert.equal(response.status,200);assert.equal((await response.json()).authenticated,false);
 assert.match(response.headers.get('Set-Cookie'),/HttpOnly; Secure; SameSite=Strict/);
 assert.equal((await call('/status')).status,401);
 assert.equal((await call('/conversation-imports')).status,401);
 assert.equal((await call('/conversation-imports',{headers:{Authorization:'Bearer '+owner}})).status,200);
 assert.equal((await call('/status',{headers:{Authorization:'Bearer '+owner}})).status,200);
 assert.equal((await call('/auth/session',{headers:{Origin:'https://hostile.example'}})).status,403);
});
test('production REST accepts sessions, requires CSRF for writes, and cannot downgrade invalid Bearer',async()=>{
 await seedSession();const headers={Cookie:'__Host-cloudnest_session='+token,Origin:origin,'Sec-Fetch-Site':'same-origin','Content-Type':'application/json'};
 assert.equal((await call('/status',{headers})).status,200);
 assert.equal((await call('/archives/publish',{method:'POST',headers,body:'{}'})).status,403);
 // Passing authentication reaches request validation, which rejects this empty publication.
 assert.equal((await call('/archives/publish',{method:'POST',headers:{...headers,'X-CloudNest-CSRF':hash('CloudNest browser CSRF v1\n'+token)},body:'{}'})).status,400);
 assert.equal((await call('/status',{headers:{...headers,Authorization:'Bearer '+randomBytes(32).toString('hex')}})).status,401);
 const mcp=await runtime.dispatchFetch(origin+'/mcp',{method:'POST',headers:{Cookie:headers.Cookie,'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})});
 assert.equal(mcp.status,401);
 await db.prepare('UPDATE brain_browser_passkeys SET revoked=1').run();
 assert.equal((await call('/status',{headers})).status,401);
});

test('erasure maintenance gates ordinary REST MCP OAuth and passkey sessions while recovery remains available',async()=>{
 await seedSession();
 await db.prepare("INSERT INTO brain_config(key,value) VALUES('erasure_lock','fixture-review')").run();
 const headers={Authorization:'Bearer '+owner,Origin:origin,'Content-Type':'application/json'};
 for(const path of ['/status','/auth/session','/conversation-imports','/clients'])assert.equal((await call(path,{headers})).status,503,path);
 for(const path of ['/mcp','/oauth/register','/.well-known/oauth-authorization-server'])assert.equal((await runtime.dispatchFetch(origin+path,{headers})).status,503,path);
 assert.equal((await call('/account-erasure',{headers})).status,200);
 assert.equal((await call('/account-erasure',{headers:{Cookie:'__Host-cloudnest_session='+token,Origin:origin}})).status,401);
 await db.prepare("DELETE FROM brain_config WHERE key='erasure_lock'").run();
 assert.equal((await call('/status',{headers})).status,200);
 await db.prepare("INSERT INTO brain_config(key,value) VALUES('account_erased','fixture-receipt')").run();
 assert.equal((await call('/status',{headers})).status,410);assert.equal((await runtime.dispatchFetch(origin+'/mcp',{headers})).status,410);
 assert.equal((await call('/account-erasure',{headers})).status,200);
});
