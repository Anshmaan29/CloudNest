import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
const {unstable_splitSqlQuery:split}=wrangler;
const hash=x=>createHash('sha256').update(x).digest('hex');
const owner=randomBytes(32).toString('hex'),reader=randomBytes(32).toString('hex');let script,runtime,db,base,outbound;
before(async()=>{script=(await build({entryPoints:['brain/worker/index.ts'],bundle:true,write:false,format:'esm',target:'es2022'})).outputFiles[0].text;});
beforeEach(async()=>{
  outbound=[];runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',host:'127.0.0.1',port:0,cf:false,d1Databases:{DB:'archive-test'},outboundService:r=>{outbound.push(r.url);throw new Error('Archive metadata must never contact Drive or external hosts');},bindings:{CLIENTS_JSON:JSON.stringify([{id:'reader',sha256:hash(reader),projects:['project'],expiresAt:'2099-01-01T00:00:00Z'}]),ALLOWED_ORIGINS:'',PUBLIC_ORIGIN:'',BRAIN_ENABLED:'true',VAULT_SIGNING_KEY:randomBytes(32).toString('hex'),OWNER_TOKEN_SHA256:hash(owner),GOOGLE_CLIENT_ID:'fixture.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fixture-client-secret',GOOGLE_REFRESH_TOKEN:'fixture-refresh-token'}}));
  base=await runtime.ready;db=await runtime.getD1Database('DB');
  for(const name of ['0001_feasibility.sql','0002_canonical.sql','0003_oauth.sql','0004_import_recovery.sql','0006_archive_catalog.sql'])await db.batch(split(await readFile('brain/migrations/'+name,'utf8')).map(s=>db.prepare(s)));
});
afterEach(async()=>{assert.deepEqual(outbound,[]);await runtime?.dispose();});
const fixture=(extra={})=>({id:randomUUID(),name:'Disposable archive.bin',kind:'file',bytes:123,sha256:hash('fixture'),driveFileId:'fixture-storage-file',manifestFileId:'fixture-manifest-file',checkedAt:new Date().toISOString(),localState:'original',...extra});
async function api(path,method='GET',body,token=owner){return fetch(new URL('/api/v1'+path,base),{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});}
async function ok(path,method='GET',body){const r=await api(path,method,body);const value=await r.json();assert.ok(r.ok,JSON.stringify({status:r.status,value}));return value;}
async function publish(archives,visibility='approved',project='project'){return ok('/archives/publish','POST',{project,visibility,archives});}
async function rpc(method,params={}){const r=await fetch(new URL('/mcp',base),{method:'POST',headers:{Authorization:'Bearer '+reader,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});return r.json();}
async function tool(name,args={}){const r=await rpc('tools/call',{name,arguments:args});assert.ok(!r.error&&!r.result.isError,JSON.stringify(r));return JSON.parse(r.result.content[0].text);}

test('owner publication is private by default, bounded and path/token-free',async()=>{
  const file=fixture();const result=await ok('/archives/publish','POST',{project:'project',archives:[file]});assert.equal(result.archives[0].visibility,'private');
  assert.equal((await api('/archives','GET',undefined,reader)).status,401);
  for(const extra of [{sourcePath:'/not/accepted'},{sessionURL:'https://example.invalid/capability'},{token:'not accepted'},{body:'not accepted'}])assert.equal((await api('/archives/publish','POST',{project:'project',archives:[fixture(extra)]})).status,400);
  assert.equal((await api('/archives/publish','POST',{project:'project',archives:Array.from({length:21},()=>fixture())})).status,400);
  const huge=await fetch(new URL('/api/v1/archives/publish',base),{method:'POST',headers:{Authorization:'Bearer '+owner,'Content-Type':'application/json'},body:' '.repeat(65537)});assert.equal(huge.status,400);
  assert.equal((await api('/archives/publish','POST',{project:'project',archives:[fixture({checkedAt:'2000-01-01T00:00:00Z'})]})).status,400);
  assert.deepEqual((await tool('files_find')).archives,[]);
});
test('MCP authorization precedes the result budget; private and other projects stay hidden',async()=>{
  await publish(Array.from({length:20},()=>fixture({id:'00000000-0000-4000-8000-'+Math.floor(Math.random()*1e10).toString().padStart(12,'0')})),'private');
  const other=fixture();await publish([other],'approved','other');const visible=fixture();await publish([visible]);
  const list=await rpc('tools/list');for(const name of ['files_find','files_status'])assert.equal(list.result.tools.find(t=>t.name===name).annotations.readOnlyHint,true);
  assert.deepEqual((await tool('files_find')).archives.map(a=>a.id),[visible.id]);
  assert.deepEqual((await tool('files_status',{id:other.id})).archives,[]);
  assert.deepEqual((await tool('files_find',{project:'other'})).archives,[]);
  assert.equal((await tool('files_status',{id:visible.id})).archives[0].sha256,visible.sha256);
  assert.ok((await db.prepare("SELECT count(*) n FROM audit WHERE client_id='reader' AND action='archive_retrieved' AND memory_id=?").bind(visible.id).first()).n>0);
});
test('Drive links are strict authenticated viewer links and folder groups point to manifests',async()=>{
  const folder=fixture({kind:'folder',name:'Project',driveTarget:'manifest',driveFileId:'fixture-manifest-file',fileCount:2});const result=(await publish([folder])).archives[0];
  assert.equal(result.driveURL,'https://drive.google.com/file/d/fixture-manifest-file/view');assert.equal(result.driveURL,result.manifestURL);
  const realFolder=fixture({kind:'folder',driveTarget:'folder'});assert.match((await publish([realFolder])).archives[0].driveURL,/^https:\/\/drive.google.com\/drive\/folders\/[A-Za-z0-9_-]+$/);
  for(const id of ['../escape','id?access_token=value','https://example.invalid/x','a/b','x#fragment'])assert.equal((await api('/archives/publish','POST',{project:'project',archives:[fixture({driveFileId:id})]})).status,400);
});
test('archive search paginates deterministically and unpublish removes metadata without cloud calls',async()=>{
  const records=[fixture(),fixture(),fixture()];await publish(records);const first=await ok('/archives?limit=2');assert.equal(first.archives.length,2);assert.ok(first.cursor);
  const second=await ok('/archives?limit=2&cursor='+first.cursor);assert.equal(second.archives.length,1);assert.equal(new Set([...first.archives,...second.archives].map(a=>a.id)).size,3);
  await ok('/archives/'+records[0].id,'DELETE');assert.equal((await api('/archives/'+records[0].id)).status,404);assert.deepEqual((await tool('files_status',{id:records[0].id})).archives,[]);
});
test('restore queue is owner-only, deduplicated, bounded and requires an explicit terminal acknowledgment',async()=>{
  const archive=fixture();await publish([archive],'private');
  assert.equal((await api('/restore-requests','POST',{archiveId:archive.id},reader)).status,401);
  assert.equal((await api('/restore-requests','POST',{archiveId:randomUUID()})).status,404);
  assert.equal((await api('/restore-requests','POST',{archiveId:archive.id,destination:'/not/accepted'})).status,400);
  const first=(await ok('/restore-requests','POST',{archiveId:archive.id})).request;
  assert.equal((await ok('/restore-requests','POST',{archiveId:archive.id})).request.id,first.id);assert.equal((await ok('/restore-requests')).requests.length,1);
  assert.equal((await ok('/restore-requests/'+first.id+'/ack','POST',{status:'completed'})).request.status,'completed');
  assert.equal((await ok('/restore-requests/'+first.id+'/ack','POST',{status:'completed'})).request.status,'completed');
  assert.equal((await api('/restore-requests/'+first.id+'/ack','POST',{status:'dismissed'})).status,409);
  await db.batch(Array.from({length:100},()=>db.prepare("INSERT INTO brain_restore_requests(id,archive_id,status,created_at) VALUES(?,?,'pending',?)").bind(randomUUID(),randomUUID(),new Date().toISOString())));
  assert.equal((await api('/restore-requests','POST',{archiveId:archive.id})).status,429);assert.equal((await ok('/restore-requests')).requests.length,100);
});
test('unpublish dismisses pending intent; audits fail closed for publication and client reads',async()=>{
  const archive=fixture();await publish([archive]);await ok('/restore-requests','POST',{archiveId:archive.id});await ok('/archives/'+archive.id,'DELETE');assert.deepEqual((await ok('/restore-requests')).requests,[]);
  const visible=fixture();await publish([visible]);await db.exec("CREATE TRIGGER reject_archive_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'fixture audit unavailable'); END;");
  assert.equal((await api('/archives/publish','POST',{project:'project',visibility:'approved',archives:[fixture()]})).status,503);
  const reply=await rpc('tools/call',{name:'files_status',arguments:{id:visible.id}});assert.equal(reply.result.isError,true);assert.ok(!JSON.stringify(reply).includes(visible.name));
});
test('graph shares one budget and emits only explicit approved memory-to-archive relationships and real read events',async()=>{
  const file=fixture(),privateFile=fixture();await publish([file]);await publish([privateFile],'private');
  const memory=randomUUID(),revision=randomUUID(),now=new Date().toISOString();const payload={title:'Decision',category:'decision',source:'fixture',relationships:[{target:file.id,type:'references'},{target:privateFile.id,type:'references'}],expiresAt:null};
  await db.prepare("INSERT INTO brain_heads(memory_id,revision,project,visibility,deleted,payload,updated_at) VALUES(?,?,'project','approved',0,?,?)").bind(memory,revision,JSON.stringify(payload),now).run();
  await tool('files_status',{id:file.id});const graph=await ok('/graph?limit=10');assert.ok(graph.nodes.some(n=>n.id===file.id&&n.nodeKind==='archive'));assert.ok(!graph.nodes.some(n=>n.id===privateFile.id));assert.deepEqual(graph.edges,[{source:memory,target:file.id,type:'references'}]);assert.ok(graph.events.some(e=>e.memoryId===file.id&&e.clientId==='reader'&&e.action==='archive_retrieved'));
  const bounded=await ok('/graph?limit=1');assert.equal(bounded.nodes.length,1);assert.equal(bounded.nodeBudget,1);assert.equal(bounded.truncated,true);assert.equal(bounded.edges.length,0);
});
