import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash,createHmac,randomBytes,randomUUID} from 'node:crypto';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
const {unstable_splitSqlQuery:splitSqlQuery}=wrangler;
const hash=x=>createHash('sha256').update(x).digest('hex');
let script,runtime,db,base,drive;
const vaultKey=randomBytes(32).toString('hex'),nextVaultKey=randomBytes(32).toString('hex');
const owner=randomBytes(32).toString('hex'),reader=randomBytes(32).toString('hex'),proposer=randomBytes(32).toString('hex');
class FakeDrive {
  get revisionCount(){return [...this.objects.values()].filter(v=>v.appProperties.cloudnestMemory).length;}
  get receiptCount(){return [...this.objects.values()].filter(v=>v.appProperties.cloudnestCommit).length;}
  objects=new Map(); onDownload=null; folders=new Map(); calls=[]; failNextUpload=false; loseNextAcknowledgement=false; corruptNextUpload=false;
  json(body,status=200){return Response.json(body,{status});}
  info(id,value){return{id,size:String(Buffer.byteLength(value.content)),sha256Checksum:hash(value.content),trashed:false,parents:value.parents,appProperties:value.appProperties};}
  async fetch(request){
    const url=new URL(request.url);this.calls.push([request.method,url.pathname]);
    if(url.hostname==='oauth2.googleapis.com'){assert.equal(request.method,'POST');return this.json({access_token:'fixture-only-access-token',expires_in:3600});}
    assert.equal(url.hostname,'www.googleapis.com');assert.equal(request.headers.get('Authorization'),'Bearer fixture-only-access-token');
    if(url.pathname==='/drive/v3/files/generateIds')return this.json({ids:['revision-'+randomUUID()]});
    if(url.pathname==='/drive/v3/files'&&request.method==='GET'){
      const q=url.searchParams.get('q')??'';assert.ok(!q.includes("has { key='cloudnestMemory' }"));
      if(q.includes("value='brain-v1'"))return this.json({files:[...this.folders.keys()].map(id=>({id})),incompleteSearch:false});
      const folder=q.match(/'([^']+)' in parents/)?.[1];assert.ok(this.folders.has(folder),'Only app-owned Brain folder may be listed');
      const items=[...this.objects].filter(([,v])=>v.parents.includes(folder)).sort(([a],[b])=>a.localeCompare(b));
      const offset=Number(url.searchParams.get('pageToken')??0);const files=items.slice(offset,offset+100).map(([id,v])=>this.info(id,v));
      return this.json({files,...(offset+100<items.length?{nextPageToken:String(offset+100)}:{}),incompleteSearch:false});
    }
    if(url.pathname==='/drive/v3/files'&&request.method==='POST'){
      const data=await request.json();assert.equal(data.appProperties.cloudnestRole,'brain-v1');const id=data.id;assert.ok(id);if(this.folders.has(id))return this.json({error:'already created'},409);this.folders.set(id,data);return this.json({id});
    }
    if(url.pathname==='/upload/drive/v3/files'&&request.method==='POST'){
      if(this.failNextUpload){this.failNextUpload=false;return this.json({error:'fixture outage'},503);}
      const boundary=request.headers.get('Content-Type').split('boundary=')[1];const parts=(await request.text()).split('--'+boundary);
      const metadata=JSON.parse(parts[1].split('\r\n\r\n')[1]);const segment=parts[2];let content=segment.slice(segment.indexOf('\r\n\r\n')+4,-2);
      assert.ok(!this.objects.has(metadata.id),'Never overwrite canonical revisions');
      if(this.corruptNextUpload){this.corruptNextUpload=false;content+='CORRUPTED';}
      this.objects.set(metadata.id,{...metadata,content});
      if(this.loseNextAcknowledgement){this.loseNextAcknowledgement=false;return this.json({error:'fixture lost acknowledgement'},503);}
      return this.json({id:metadata.id});
    }
    const id=url.pathname.match(/^\/drive\/v3\/files\/([^/]+)$/)?.[1];const value=this.objects.get(id);
    if(!value){const folder=this.folders.get(id);if(folder)return this.json({id,mimeType:'application/vnd.google-apps.folder',trashed:false,appProperties:folder.appProperties});return this.json({error:'missing'},404);}
    if(url.searchParams.get('alt')==='media'){if(this.onDownload){const callback=this.onDownload;this.onDownload=null;await callback();}return new Response(value.content,{headers:{'Content-Type':'text/markdown'}});}
    return this.json(this.info(id,value));
  }
  inject(record){
    const {body,...metadata}=record;const content='<!-- CloudNest canonical memory v1 -->\n```json\n'+JSON.stringify(metadata,null,2)+'\n```\n\n'+body;
    const id='injected-'+randomUUID();this.objects.set(id,{content,parents:[[...this.folders.keys()][0]],appProperties:{cloudnestMemory:record.id,cloudnestRevision:record.revision}});const receipt={format:'cloudnest-commit-v1',memoryID:record.id,revision:record.revision,version:record.version,canonicalID:id,sha256:hash(content)};receipt.signature=createHmac('sha256',Buffer.from(vaultKey,'hex')).update(JSON.stringify(receipt)).digest('hex');this.objects.set('receipt-'+randomUUID(),{content:JSON.stringify(receipt),parents:[[...this.folders.keys()][0]],appProperties:{cloudnestCommit:record.id,cloudnestRevision:record.revision}});return id;
  }
}
before(async()=>{script=(await build({stdin:{resolveDir:process.cwd(),contents:`
import worker from './brain/worker/index.ts';
import {BrainService} from './brain/api/service.ts';
import {rotateVault,rotationProgress} from './brain/api/vault-rotation.ts';
export default {async fetch(request,environment,context){
  const env={...environment};
  if(request.headers.get('X-Fixture-Key-Mode')==='new-only'){env.VAULT_SIGNING_KEY=env.VAULT_NEXT_SIGNING_KEY;delete env.VAULT_NEXT_SIGNING_KEY;}
  if(request.headers.get('X-Fixture-Key-Mode')==='old-only')delete env.VAULT_NEXT_SIGNING_KEY;
  const url=new URL(request.url);
  if(url.pathname==='/api/v1/_test/vault')try{return Response.json(request.method==='GET'?await rotationProgress(new BrainService(env)):await rotateVault(new BrainService(env),(await request.json()).cursor));}catch(e){return Response.json({error:e.message},{status:e.status??503});}
  return worker.fetch(request,env,context);
}};`},bundle:true,write:false,format:'esm',target:'es2022'})).outputFiles[0].text;});
beforeEach(async()=>{
  drive=new FakeDrive();const grants=[{id:'reader',sha256:hash(reader),projects:['project'],expiresAt:'2099-01-01T00:00:00Z'},{id:'proposer',sha256:hash(proposer),projects:['project'],permissions:['propose'],expiresAt:'2099-01-01T00:00:00Z'}];
  runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',host:'127.0.0.1',port:0,cf:false,d1Databases:{DB:'canonical-test'},outboundService:r=>drive.fetch(r),bindings:{CLIENTS_JSON:JSON.stringify(grants),ALLOWED_ORIGINS:'',PUBLIC_ORIGIN:'',BRAIN_ENABLED:'true',VAULT_SIGNING_KEY:vaultKey,VAULT_NEXT_SIGNING_KEY:nextVaultKey,OWNER_TOKEN_SHA256:hash(owner),GOOGLE_CLIENT_ID:'fixture.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fixture-client-secret',GOOGLE_REFRESH_TOKEN:'fixture-refresh-token'}}));
  base=await runtime.ready;db=await runtime.getD1Database('DB');
  for(const file of ['0001_feasibility.sql','0002_canonical.sql','0004_import_recovery.sql','0006_archive_catalog.sql','0007_vault_rotation.sql'])await db.batch(splitSqlQuery(await readFile('brain/migrations/'+file,'utf8')).map(s=>db.prepare(s)));
});
afterEach(async()=>{await runtime?.dispose();});
const input=(extra={})=>({project:'project',title:'Verified knowledge',body:'Keep originals until remote integrity verification.',source:'fixture:canonical',category:'decision',...extra});
async function api(path,method='GET',body,extra={},token=owner){
  return fetch(new URL('/api/v1'+path,base),{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...extra},...(body===undefined?{}:{body:JSON.stringify(body)})});
}
async function ok(path,method='GET',body,extra={}){const response=await api(path,method,body,extra);const data=await response.json();assert.ok(response.ok,JSON.stringify({status:response.status,data}));return data;}
async function create(extra={}){return(await ok('/memories','POST',input(extra),{'Idempotency-Key':randomUUID()})).memory;}
async function mcp(name,args={},token=reader){const response=await fetch(new URL('/mcp',base),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})});return{response,value:await response.json()};}
async function memories(id,token=reader){const {value}=await mcp('memory_read',{id},token);assert.ok(value.result&&!value.result.isError,JSON.stringify(value));return JSON.parse(value.result.content[0].text).memories;}
async function rebuild(){let response=await ok('/reindex','POST',{});let calls=1;while(!response.complete){assert.ok(response.cursor);response=await ok('/reindex','POST',{cursor:response.cursor});assert.ok(++calls<30);}return{...response,calls};}

test('canonical create stores portable verified Markdown and retrieves through scoped MCP',async()=>{
 const memory=await create();assert.equal(drive.revisionCount,1);assert.equal((await memories(memory.id))[0].id,memory.id);
 const object=[...drive.objects.values()][0];assert.ok(object.content.startsWith('<!-- CloudNest canonical memory v1 -->'));assert.ok(object.content.includes(memory.body));
 assert.equal((await ok('/memories/'+memory.id)).memory.revision,memory.revision);
 const state=await ok('/status');assert.equal(state.configured,true);assert.equal(state.pending,0);
});
test('optimistic revision conflicts never silently overwrite canonical data',async()=>{
 const first=await create();const corrected=(await ok('/memories/'+first.id,'PATCH',{expectedRevision:first.revision,body:'Corrected user-approved fact.'})).memory;
 assert.equal(corrected.version,2);assert.equal(corrected.parentRevision,first.revision);assert.equal(drive.revisionCount,2);
 assert.equal((await api('/memories/'+first.id,'PATCH',{expectedRevision:first.revision,body:'stale'})).status,409);
 assert.equal((await ok('/memories/'+first.id)).memory.body,'Corrected user-approved fact.');assert.equal(drive.revisionCount,2);
});
test('simultaneous updates produce one committed successor and one conflict',async()=>{
 const m=await create();const replies=await Promise.all([api('/memories/'+m.id,'PATCH',{expectedRevision:m.revision,body:'branch A'}),api('/memories/'+m.id,'PATCH',{expectedRevision:m.revision,body:'branch B'})]);
 assert.deepEqual(replies.map(r=>r.status).sort(),[200,409]);assert.equal(drive.revisionCount,2);
});
test('lost Drive acknowledgement resumes the same preallocated immutable ID',async()=>{
 const key=randomUUID();drive.loseNextAcknowledgement=true;
 assert.equal((await api('/memories','POST',input(),{'Idempotency-Key':key})).status,503);assert.equal(drive.revisionCount,1);
 const pending=(await ok('/operations')).operations;assert.equal(pending.length,1);assert.equal(pending[0].operationId,key);
 const memory=(await ok('/operations/'+key+'/resume','POST',{})).memory;assert.equal(drive.revisionCount,1);assert.equal((await memories(memory.id)).length,1);
 const retry=(await ok('/memories','POST',input(),{'Idempotency-Key':key})).memory;assert.equal(retry.revision,memory.revision);
 assert.equal((await api('/memories','POST',input({body:'different'}),{'Idempotency-Key':key})).status,409);
});
test('incomplete private correction and deletion suppress stale reads before cloud recovery',async()=>{
 const m=await create();const key=randomUUID();drive.failNextUpload=true;
 assert.equal((await api('/memories/'+m.id,'PATCH',{expectedRevision:m.revision,visibility:'private'},{'Idempotency-Key':key})).status,503);
 assert.deepEqual(await memories(m.id),[]);assert.equal((await api('/memories/'+m.id)).status,409);
 const privateMemory=(await ok('/operations/'+key+'/resume','POST',{})).memory;assert.equal(privateMemory.visibility,'private');assert.deepEqual(await memories(m.id),[]);
 const deleted=(await ok('/memories/'+m.id,'DELETE',{expectedRevision:privateMemory.revision})).memory;assert.equal(deleted.deleted,true);assert.equal((await api('/memories/'+m.id)).status,404);
 assert.equal((await ok('/deleted')).memories[0].id,m.id);
 const restored=(await ok('/memories/'+m.id+'/restore','POST',{expectedRevision:deleted.revision,revision:m.revision})).memory;
 assert.equal(restored.body,m.body);assert.equal(restored.version,4);assert.equal((await memories(m.id)).length,1);
});
test('corrupt canonical bytes never commit the search index',async()=>{
 drive.corruptNextUpload=true;assert.equal((await api('/memories','POST',input())).status,503);
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_heads').first()).n,0);
 assert.equal((await ok('/operations')).operations.length,1);assert.equal((await ok('/memories')).memories.length,0);
});
test('AI propose permission is explicit and proposals require owner approval',async()=>{
 const denied=await mcp('memory_propose',input());assert.equal(denied.value.error.code,-32602);
 const proposed=await mcp('memory_propose',input(),proposer);assert.ok(proposed.value.result&&!proposed.value.result.isError);const p=JSON.parse(proposed.value.result.content[0].text).proposal;
 assert.equal(drive.revisionCount,0);assert.deepEqual(await memories(p.id),[]);assert.equal((await ok('/inbox')).proposals.length,1);
 const approved=(await ok('/inbox/'+p.id+'/approve','POST',{})).memory;assert.equal(approved.id,p.id);assert.equal((await memories(p.id)).length,1);
 const rejected=JSON.parse((await mcp('memory_propose',input({title:'Reject this'}),proposer)).value.result.content[0].text).proposal;
 await ok('/inbox/'+rejected.id+'/reject','POST',{});assert.equal((await ok('/inbox')).proposals.length,0);
 assert.equal((await api('/inbox/'+rejected.id+'/approve','POST',{})).status,409);
 assert.equal((await mcp('memory_propose',input({project:'unauthorized'}),proposer)).value.result.isError,true);
});
test('private memories stay out of MCP, context packs and graph while owner can manage them',async()=>{
 const pub=await create(),privateMemory=await create({visibility:'private',title:'Private sentinel',body:'SECRET_PRIVATE_SENTINEL'});
 assert.deepEqual(await memories(privateMemory.id),[]);assert.equal((await ok('/memories/'+privateMemory.id)).memory.body,'SECRET_PRIVATE_SENTINEL');
 assert.ok(!JSON.stringify(await ok('/context?project=project')).includes('SECRET_PRIVATE_SENTINEL'));
 const graph=await ok('/graph?project=project');assert.deepEqual(graph.nodes.map(n=>n.id),[pub.id]);assert.ok(!JSON.stringify(graph).includes(privateMemory.id));
});
test('export/import preserve Unicode and remap internal relationships with reported external references',async()=>{
 const a=await create({body:'日本語 résumé 🧠'}),b=await create({relationships:[{target:a.id,type:'references'},{target:randomUUID(),type:'related'}]});
 const exported=await ok('/export');assert.ok(exported.markdown.some(m=>m.text.includes('日本語 résumé 🧠')));
 const result=await ok('/import','POST',{memories:exported.memories});assert.equal(result.complete,true);assert.equal(result.memories.length,2);assert.equal(result.unresolvedReferences.length,1);
 const importedA=result.memories.find(m=>m.body===a.body),importedB=result.memories.find(m=>m.relationships.length);assert.notEqual(importedA.id,a.id);assert.equal(importedB.relationships[0].target,importedA.id);assert.equal(importedA.confidence,'imported');
});
test('multi-step imports use durable operation IDs and expose resumable progress',async()=>{
 const list=Array.from({length:5},(_,i)=>input({id:randomUUID(),body:'import '+i}));let result=await ok('/import','POST',{memories:list});assert.equal(result.complete,false);assert.equal(result.processed,2);const cursor=result.cursor;
 const second=await ok('/import','POST',{cursor});assert.equal(second.processed,4);const done=await ok('/import','POST',{cursor});assert.equal(done.complete,true);assert.equal(done.processed,5);
 assert.equal(drive.revisionCount,5);const replay=await ok('/import','POST',{cursor});assert.equal(replay.memories.length,0);assert.equal(drive.revisionCount,5);
});
test('reindex rebuilds index, deletion and idempotency receipts from canonical revisions',async()=>{
 const key=randomUUID();const a=(await ok('/memories','POST',input(),{'Idempotency-Key':key})).memory;const b=await create({body:'remove me'});await ok('/memories/'+b.id,'DELETE',{expectedRevision:b.revision});
 await db.batch(['DELETE FROM memories','DELETE FROM brain_heads','DELETE FROM brain_revisions',"DELETE FROM brain_config WHERE key='drive_folder'"].map(s=>db.prepare(s)));
 const result=await rebuild();assert.equal(result.indexed,1);assert.deepEqual(result.conflicts,[]);assert.equal((await memories(a.id)).length,1);assert.deepEqual(await memories(b.id),[]);
 const retry=(await ok('/memories','POST',input(),{'Idempotency-Key':key})).memory;assert.equal(retry.id,a.id);assert.equal(drive.revisionCount,3);
});
test('reindex detects branches and never chooses an arbitrary latest timestamp',async()=>{
 const m=await create();for(const body of ['branch one','branch two'])drive.inject({...m,body,parentRevision:m.revision,revision:randomUUID(),operationId:randomUUID(),requestHash:hash(body),version:2,updatedAt:new Date().toISOString()});
 const result=await rebuild();assert.deepEqual(result.conflicts,[m.id]);assert.equal(result.indexed,0);assert.deepEqual(await memories(m.id),[]);
});
test('chunked reindex hides reads and resumes within a bounded visible page',async()=>{
 const m=await create();for(let i=0;i<24;i++)drive.inject({...m,id:randomUUID(),revision:randomUUID(),operationId:randomUUID(),requestHash:hash(String(i)),body:'item '+i});
 const first=await ok('/reindex','POST',{});assert.equal(first.complete,false);assert.ok(first.cursor);assert.equal((await api('/memories')).status,503);assert.deepEqual(await memories(m.id),[]);
 const status=await ok('/status');assert.equal(status.reindexJob,first.cursor);let done=await ok('/reindex','POST',{cursor:first.cursor});while(!done.complete)done=await ok('/reindex','POST',{cursor:done.cursor});assert.equal(done.complete,true);assert.equal(done.indexed,25);
});
test('owner auth, origin, input limits, read-only clients and rate limiting fail closed',async()=>{
 assert.equal((await api('/memories','GET',undefined,{},reader)).status,401);
 assert.equal((await api('/memories','GET',undefined,{Origin:'https://untrusted.example'})).status,403);
 assert.equal((await api('/memories','POST',input({body:'x'.repeat(70000)}))).status,400);
 assert.equal((await api('/memories','POST',input({visibility:'public'}))).status,400);
 assert.equal((await api('/memories','POST',input({relationships:[{target:'../escape',type:'references'}]}))).status,400);
 await db.prepare('INSERT INTO brain_rate_limits(identity,minute,count) VALUES(?,?,?) ON CONFLICT(identity,minute) DO UPDATE SET count=excluded.count').bind('owner',Math.floor(Date.now()/60000),240).run();assert.equal((await api('/memories')).status,429);
});
test('managed client credentials are returned once, hashed at rest and revocable individually',async()=>{
 const issued=await ok('/clients','POST',{id:'coding-agent',projects:['project'],expiresAt:new Date(Date.now()+86400000).toISOString()});assert.match(issued.token,/^[a-f0-9]{64}$/);
 const saved=await db.prepare('SELECT * FROM brain_clients WHERE id=?').bind('coding-agent').first();assert.equal(saved.sha256,hash(issued.token));assert.ok(!JSON.stringify(saved).includes(issued.token));
 const m=await create();assert.equal((await memories(m.id,issued.token)).length,1);await ok('/clients/coding-agent/revoke','POST',{});assert.equal((await mcp('memory_read',{id:m.id},issued.token)).response.status,401);
 assert.equal((await memories(m.id)).length,1);assert.ok(!JSON.stringify(await ok('/clients')).includes(issued.token));
});
test('all returned graph edges derive from visible saved relationships and events are audited reads',async()=>{
 const a=await create(),b=await create({relationships:[{target:a.id,type:'references'}]});await memories(a.id);
 const graph=await ok('/graph?project=project');assert.equal(graph.edges.length,1);assert.deepEqual(graph.edges[0],{source:b.id,target:a.id,type:'references'});assert.ok(graph.events.some(e=>e.memoryId===a.id));
 const handoff=await ok('/handoff','POST',{project:'project',task:'Continue fixture task',progress:'Archive verified',unresolved:'No network access',nextAction:'Test restore',references:['fixture:source']});assert.ok(handoff.text.includes('Continue fixture task'));assert.ok(handoff.text.includes('untrusted context'));
});
test('failed authorization audit never returns owner or AI memory content',async()=>{
 const m=await create();await db.prepare('DROP TABLE audit').run();const response=await api('/memories/'+m.id);assert.equal(response.status,503);assert.ok(!(await response.text()).includes(m.body));
 const reply=await mcp('memory_read',{id:m.id});assert.equal(reply.value.result.isError,true);assert.ok(!JSON.stringify(reply.value).includes(m.body));
});
test('large graph owner reads cannot bury actual AI access events and source metadata',async()=>{
 const original=await create();await memories(original.id);
 const rows=Array.from({length:105},(_,i)=>({...original,id:randomUUID(),revision:randomUUID(),title:'Graph fixture '+i}));
 await db.batch(rows.map(m=>db.prepare('INSERT INTO brain_heads(memory_id,revision,project,visibility,deleted,payload,updated_at) VALUES(?,?,?,?,?,?,?)').bind(m.id,m.revision,m.project,m.visibility,0,JSON.stringify(m),m.updatedAt)));
 const graph=await ok('/graph?limit=200');assert.equal(graph.nodes.length,106);assert.ok(graph.clients.some(c=>c.id==='reader'));assert.ok(graph.events.some(e=>e.clientId==='reader'&&e.memoryId===original.id));assert.ok(graph.events.every(e=>e.clientId!=='owner'));assert.equal(graph.nodes.find(n=>n.id===original.id).source,original.source);
});

test('missing latest private revision cannot resurrect an older approved fact during rebuild',async()=>{
 const original=await create();const privateVersion=(await ok('/memories/'+original.id,'PATCH',{expectedRevision:original.revision,visibility:'private'})).memory;
 for(const[id,v]of drive.objects)if(v.appProperties.cloudnestMemory===original.id&&v.appProperties.cloudnestRevision===privateVersion.revision)drive.objects.delete(id);
 const rebuilt=await rebuild();assert.deepEqual(rebuilt.conflicts,[original.id]);assert.equal(rebuilt.indexed,0);assert.deepEqual(await memories(original.id),[]);
});
test('orphan canonical revision without commit receipt is quarantined rather than published',async()=>{
 const original=await create();const changed=(await ok('/memories/'+original.id,'PATCH',{expectedRevision:original.revision,body:'new content'})).memory;
 for(const[id,v]of drive.objects)if(v.appProperties.cloudnestCommit===original.id&&v.appProperties.cloudnestRevision===changed.revision)drive.objects.delete(id);
 const rebuilt=await rebuild();assert.deepEqual(rebuilt.conflicts,[original.id]);assert.deepEqual(await memories(original.id),[]);
});
test('approval survives provider failure and rejection cannot race a claimed approval',async()=>{
 const reply=await mcp('memory_propose',input(),proposer);const proposal=JSON.parse(reply.value.result.content[0].text).proposal;
 drive.failNextUpload=true;assert.equal((await api('/inbox/'+proposal.id+'/approve','POST',{})).status,503);
 const inbox=await ok('/inbox');assert.equal(inbox.proposals[0].status,'approving');assert.equal((await api('/inbox/'+proposal.id+'/reject','POST',{})).status,409);
 const resumed=await ok('/inbox/'+proposal.id+'/approve','POST',{});assert.equal(resumed.memory.id,proposal.id);assert.equal((await ok('/inbox')).proposals.length,0);assert.equal(drive.revisionCount,1);assert.equal(drive.receiptCount,1);
});
test('graph and context apply approved filtering before limits and graph never includes bodies',async()=>{
 const first=await create();const statements=[];
 for(let i=0;i<40;i++){
  const record={...first,id:randomUUID(),revision:randomUUID(),operationId:randomUUID(),title:'graph fixture '+i,body:i<25?'PRIVATE_SENTINEL':'approved graph content',visibility:i<25?'private':'approved',updatedAt:i<25?'2090-01-01T00:00:00.000Z':'2026-01-01T00:00:00.000Z'};
  statements.push(db.prepare('INSERT INTO brain_heads(memory_id,revision,project,visibility,deleted,payload,updated_at) VALUES(?,?,?,?,0,?,?)').bind(record.id,record.revision,record.project,record.visibility,JSON.stringify(record),record.updatedAt));
 }
 await db.batch(statements);const graph=await ok('/graph?project=project&limit=600');assert.equal(graph.nodes.length,16);assert.ok(!JSON.stringify(graph).includes('PRIVATE_SENTINEL'));assert.ok(graph.nodes.every(n=>!('body'in n)));
 const context=await ok('/context?project=project');assert.ok(context.memories.length>0);assert.ok(context.memories.every(m=>m.visibility==='approved'));assert.ok(!context.text.includes('PRIVATE_SENTINEL'));
});
test('history is pageable beyond ten revisions and old revisions can still be restored',async()=>{
 let latest=await create();const first=latest;for(let i=0;i<12;i++)latest=(await ok('/memories/'+latest.id,'PATCH',{expectedRevision:latest.revision,body:'revision '+i})).memory;
 const page=await ok('/memories/'+first.id+'/history');assert.equal(page.revisions.length,10);assert.ok(page.cursor);const older=await ok('/memories/'+first.id+'/history?beforeVersion='+page.cursor);assert.equal(older.revisions.length,3);assert.equal(older.revisions.at(-1).revision,first.revision);
 const restored=(await ok('/memories/'+first.id+'/restore','POST',{expectedRevision:latest.revision,revision:first.revision})).memory;assert.equal(restored.body,first.body);
});
test('tombstones remain deleted after portable import and appear in owner recovery list',async()=>{
 const first=await create();await ok('/memories/'+first.id,'DELETE',{expectedRevision:first.revision});const exported=await ok('/export');const imported=await ok('/import','POST',{memories:exported.memories});assert.equal(imported.memories[0].deleted,true);
 assert.equal((await ok('/deleted')).memories.length,2);assert.equal((await ok('/memories')).memories.length,0);
});
test('malformed Unicode and numerical confidence are rejected without a canonical write',async()=>{
 assert.equal((await api('/memories','POST',input({body:'\ud800'}))).status,400);assert.equal((await api('/memories','POST',input({confidence:0.98}))).status,400);assert.equal(drive.revisionCount,0);
});
test('missing audit blocks idempotent reply and pending-operation cloud recovery',async()=>{
 const key=randomUUID();const m=(await ok('/memories','POST',input(),{'Idempotency-Key':key})).memory;drive.failNextUpload=true;const pending=randomUUID();await api('/memories/'+m.id,'PATCH',{expectedRevision:m.revision,body:'pending'},{'Idempotency-Key':pending});
 await db.prepare('DROP TABLE audit').run();const before=drive.revisionCount;assert.equal((await api('/operations/'+pending+'/resume','POST',{})).status,503);assert.equal(drive.revisionCount,before);
 const response=await api('/memories','POST',input(),{'Idempotency-Key':key});assert.equal(response.status,503);assert.ok(!(await response.text()).includes(m.body));
});

test('concurrent first writes share one durable Brain folder identity',async()=>{
 const responses=await Promise.all([api('/memories','POST',input({title:'first'})),api('/memories','POST',input({title:'second'}))]);for(const response of responses)assert.equal(response.status,201,await response.text());
 assert.equal(drive.folders.size,1);assert.equal(drive.revisionCount,2);assert.equal(drive.receiptCount,2);assert.equal((await rebuild()).indexed,2);
});
test('changing the cached folder ownership marker blocks canonical writes',async()=>{
 await create();const folder=[...drive.folders.values()][0];folder.appProperties.cloudnestRole='storage-v1';
 assert.equal((await api('/memories','POST',input({title:'must not enter Storage'}))).status,503);assert.equal(drive.revisionCount,1);assert.equal((await ok('/operations')).operations.length,1);
});

test('untrusted imported visibility never grants clients automatic memory access',async()=>{
 const original=await create();const imported=await ok('/import','POST',{memories:[{...original,visibility:'approved'}]});assert.equal(imported.memories[0].visibility,'private');assert.deepEqual(await memories(imported.memories[0].id),[]);
});
test('a Drive editor cannot forge approval by changing both Markdown and its checksum receipt',async()=>{
 const original=await create({visibility:'private'});
 let changedHash;
 for(const value of drive.objects.values())if(value.appProperties.cloudnestMemory===original.id){value.content=value.content.replace('"visibility": "private"','"visibility": "approved"');changedHash=hash(value.content);}
 for(const value of drive.objects.values())if(value.appProperties.cloudnestCommit===original.id){const receipt=JSON.parse(value.content);receipt.sha256=changedHash;value.content=JSON.stringify(receipt);}
 const response=await api('/reindex','POST',{});assert.equal(response.status,409);assert.ok((await response.json()).error.includes('signature'));assert.deepEqual(await memories(original.id),[]);
});

async function rotateAll(extra={}){let progress=await ok('/_test/vault','POST',{},extra);let steps=1;while(!progress.complete){progress=await ok('/_test/vault','POST',{cursor:progress.cursor},extra);assert.ok(++steps<100);}return{...progress,steps};}
test('fresh-key checkpoints preserve every private, deleted and superseded revision after old key removal',async()=>{
 const first=await create();let head=first;
 for(let i=0;i<12;i++)head=(await ok('/memories/'+head.id,'PATCH',{expectedRevision:head.revision,body:'history '+i,visibility:i%2?'private':'approved'})).memory;
 const tombstone=await create({visibility:'private'});await ok('/memories/'+tombstone.id,'DELETE',{expectedRevision:tombstone.revision});
 const before=(await db.prepare('SELECT revision,payload,drive_id FROM brain_revisions ORDER BY revision').all()).results;
 const originals=new Map([...drive.objects].map(([id,v])=>[id,v.content]));
 const done=await rotateAll();assert.equal(done.revisions,15);assert.equal(done.signed,15);assert.equal(done.keyFingerprint,hash(nextVaultKey));assert.ok(done.steps>4);
 for(const[id,content]of originals)assert.equal(drive.objects.get(id).content,content,'Historical bytes remain immutable');
 const after=(await db.prepare('SELECT revision,payload,drive_id FROM brain_revisions ORDER BY revision').all()).results;assert.deepEqual(after,before);
 await db.batch(['DELETE FROM memories','DELETE FROM brain_heads','DELETE FROM brain_revisions'].map(s=>db.prepare(s)));
 let result=await ok('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});while(!result.complete)result=await ok('/reindex','POST',{cursor:result.cursor},{'X-Fixture-Key-Mode':'new-only'});
 assert.deepEqual(result.conflicts,[]);assert.deepEqual((await db.prepare('SELECT revision,payload,drive_id FROM brain_revisions ORDER BY revision').all()).results.map(r=>({...r,payload:JSON.parse(r.payload)})),before.map(r=>({...r,payload:JSON.parse(r.payload)})));
 const created=await ok('/memories','POST',input({title:'After rotation'}),{'X-Fixture-Key-Mode':'new-only'});assert.ok(created.memory);
 const receipt=[...drive.objects.values()].find(v=>v.appProperties.cloudnestCommit===created.memory.id);const parsed=JSON.parse(receipt.content),{signature,...unsigned}=parsed;assert.equal(signature,createHmac('sha256',Buffer.from(nextVaultKey,'hex')).update(JSON.stringify(unsigned)).digest('hex'));
});
test('rotation refuses pending writes and active imports before freezing the snapshot',async()=>{
 drive.failNextUpload=true;await api('/memories','POST',input());assert.equal((await api('/_test/vault','POST',{})).status,409);assert.equal((await db.prepare("SELECT value FROM brain_config WHERE key='reindex_lock'").first()),null);
});
test('missing historical receipt or canonical byte drift leaves rotation durably frozen',async()=>{
 const m=await create();for(const[id,v]of drive.objects)if(v.appProperties.cloudnestCommit===m.id)drive.objects.delete(id);
 const result=await api('/_test/vault','POST',{});assert.equal(result.status,409);assert.match((await result.json()).error,/missing/);
 const status=await ok('/_test/vault');assert.equal(status.state,'scanning');assert.equal((await api('/memories','POST',input())).status,409);assert.equal((await api('/reindex','POST',{})).status,409);assert.equal((await db.prepare("SELECT value FROM brain_config WHERE key='vault_active_key_sha256'").first()),null);
});
test('trusted D1 history, not a compromised-key forgery, anchors rotation',async()=>{
 const m=await create({visibility:'private'});
 for(const value of drive.objects.values())if(value.appProperties.cloudnestMemory===m.id)value.content=value.content.replace('"visibility": "private"','"visibility": "approved"');
 const corrupted=[...drive.objects].find(([,v])=>v.appProperties.cloudnestMemory===m.id)[1];
 for(const value of drive.objects.values())if(value.appProperties.cloudnestCommit===m.id){const r=JSON.parse(value.content);r.sha256=hash(corrupted.content);const{signature,...unsigned}=r;r.signature=createHmac('sha256',Buffer.from(vaultKey,'hex')).update(JSON.stringify(unsigned)).digest('hex');value.content=JSON.stringify(r);}
 const result=await api('/_test/vault','POST',{});assert.equal(result.status,409);assert.match((await result.json()).error,/snapshot/);assert.equal((await ok('/_test/vault')).signed,0);
});
test('lost checkpoint upload acknowledgement resumes one durable ID and a new request lease',async()=>{
 await create();let first=await ok('/_test/vault','POST',{});assert.equal(first.state,'signing');
 drive.loseNextAcknowledgement=true;assert.equal((await api('/_test/vault','POST',{cursor:first.cursor})).status,503);const count=drive.receiptCount;
 const retained=await db.prepare('SELECT receipt_id FROM brain_vault_rotation_rows WHERE job_id=?').bind(first.cursor).first();assert.ok(retained.receipt_id);
 // A replacement isolate has no process-local job state: durable rows and an
 // expired lease are sufficient to resume after a crash.
 await db.prepare('UPDATE brain_vault_rotations SET busy_token=?,busy_until=? WHERE id=?').bind(randomUUID(),Date.now()-1,first.cursor).run();
 let progress=await ok('/_test/vault','POST',{cursor:first.cursor});assert.equal(drive.receiptCount,count);while(!progress.complete)progress=await ok('/_test/vault','POST',{cursor:first.cursor});
 assert.equal(progress.complete,true);assert.equal(drive.receiptCount,2);assert.equal((await ok('/_test/vault','POST',{cursor:first.cursor})).complete,true);
});
test('post-snapshot D1 drift and post-signing Drive drift prevent activation',async()=>{
 const m=await create();let progress=await ok('/_test/vault','POST',{});assert.equal(progress.state,'signing');
 await db.prepare('UPDATE brain_revisions SET payload=replace(payload,?,?) WHERE revision=?').bind('Verified knowledge','Changed knowledge',m.revision).run();assert.equal((await api('/_test/vault','POST',{cursor:progress.cursor})).status,409);
 assert.equal((await db.prepare("SELECT value FROM brain_config WHERE key='vault_active_key_sha256'").first()),null);
});
test('a changed retired receipt is rejected after activation despite its valid compromised-key signature',async()=>{
 const m=await create();await rotateAll();
 for(const value of drive.objects.values())if(value.appProperties.cloudnestCommit===m.id&&JSON.parse(value.content).format==='cloudnest-commit-v1'){const r=JSON.parse(value.content);r.sha256='a'.repeat(64);const{signature,...unsigned}=r;r.signature=createHmac('sha256',Buffer.from(vaultKey,'hex')).update(JSON.stringify(unsigned)).digest('hex');value.content=JSON.stringify(r);}
 const result=await api('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});assert.equal(result.status,409);assert.match((await result.json()).error,/signature/);
});
test('activation never falls back to the compromised old key',async()=>{
 await create();await rotateAll();const result=await api('/memories','POST',input({title:'Old key must fail'}),{'X-Fixture-Key-Mode':'old-only'});assert.equal(result.status,503);assert.match((await result.json()).error,/Active vault signing key/);
});

test('an unfinished multi-step import prevents rotation without creating a maintenance lock',async()=>{
 const records=Array.from({length:5},(_,i)=>({...input(),id:randomUUID(),body:'pending import '+i}));const progress=await ok('/import','POST',{memories:records});assert.equal(progress.complete,false);
 assert.equal((await api('/_test/vault','POST',{})).status,409);assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key='reindex_lock'").first(),null);
});
test('a canonical checkpoint changed after upload blocks activation and keeps all content frozen',async()=>{
 const m=await create();let progress=await ok('/_test/vault','POST',{});progress=await ok('/_test/vault','POST',{cursor:progress.cursor});assert.equal(progress.state,'verifying');
 for(const value of drive.objects.values())if(value.appProperties.cloudnestCommit===m.id&&JSON.parse(value.content).format==='cloudnest-commit-v2')value.content=value.content.replace(/"signature":"[a-f0-9]{64}"/,'"signature":"'+'0'.repeat(64)+'"');
 const result=await api('/_test/vault','POST',{cursor:progress.cursor});assert.equal(result.status,409);assert.match((await result.json()).error,/checkpoint/);
 assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key='vault_active_key_sha256'").first(),null);assert.equal((await api('/memories')).status,503);
});
test('a removed latest private record and both receipts cannot resurrect the earlier approved revision',async()=>{
 const original=await create();const latest=(await ok('/memories/'+original.id,'PATCH',{expectedRevision:original.revision,visibility:'private'})).memory;await rotateAll();
 for(const[id,v]of drive.objects)if(v.appProperties.cloudnestRevision===latest.revision)drive.objects.delete(id);
 const result=await api('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});assert.equal(result.status,409);assert.match((await result.json()).error,/root checkpoint history/);
 assert.equal((await db.prepare('SELECT visibility FROM brain_heads WHERE memory_id=?').bind(original.id).first()).visibility,'private');
});
test('a removed active signed root cannot silently downgrade rebuild to individual receipts',async()=>{
 await create();await rotateAll();for(const[id,v]of drive.objects)if(v.appProperties.cloudnestCheckpoint)drive.objects.delete(id);
 const result=await api('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});assert.equal(result.status,409);assert.match((await result.json()).error,/root checkpoint/);
});
test('the dedicated durable rotation guard survives loss of the ordinary reindex lock',async()=>{
 await create();const progress=await ok('/_test/vault','POST',{});assert.equal(progress.complete,false);
 await db.prepare("DELETE FROM brain_config WHERE key='reindex_lock'").run();assert.equal((await api('/memories')).status,503);assert.equal((await api('/memories','POST',input())).status,409);assert.equal((await api('/reindex','POST',{})).status,409);
 const count=(await db.prepare('SELECT count(*) AS n FROM brain_import_jobs').first()).n;assert.equal((await api('/import','POST',{memories:[input()]})).status,503);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_import_jobs').first()).n,count);
});

test('postrotation private and tombstone updates remain a trusted minimum during later rebuild',async()=>{
 const original=await create();await rotateAll();const latest=(await ok('/memories/'+original.id,'DELETE',{expectedRevision:original.revision})).memory;
 for(const[id,v]of drive.objects)if(v.appProperties.cloudnestRevision===latest.revision)drive.objects.delete(id);
 const result=await api('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});assert.equal(result.status,409);assert.match((await result.json()).error,/post-checkpoint history/);assert.equal((await db.prepare('SELECT deleted FROM brain_heads WHERE memory_id=?').bind(original.id).first()).deleted,1);
});
test('a reindex request that loses its lease cannot delete the index or release maintenance',async()=>{
 const m=await create();drive.onDownload=async()=>{await db.prepare("UPDATE brain_reindex_jobs SET busy_token=?,busy_until=? WHERE state='scanning'").bind(randomUUID(),Date.now()+600000).run();};
 const result=await api('/reindex','POST',{});assert.equal(result.status,409);assert.match((await result.json()).error,/lease|ownership/);assert.ok(await db.prepare('SELECT revision FROM brain_heads WHERE memory_id=?').bind(m.id).first());assert.ok(await db.prepare("SELECT value FROM brain_config WHERE key='reindex_lock'").first());
});
test('a rotation scan that loses its lease cannot add stale receipt rows or advance the job',async()=>{
 const m=await create();drive.onDownload=async()=>{await db.prepare("UPDATE brain_vault_rotations SET busy_token=?,busy_until=? WHERE state='scanning'").bind(randomUUID(),Date.now()+600000).run();};
 const result=await api('/_test/vault','POST',{});assert.equal(result.status,409);assert.equal((await ok('/_test/vault')).state,'scanning');assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_vault_rotation_receipts').first()).n,0);assert.ok(await db.prepare('SELECT revision FROM brain_heads WHERE memory_id=?').bind(m.id).first());
});

test('a surviving trusted newer head prevents rollback even if its D1 revision row was lost',async()=>{
 const original=await create();await rotateAll();const latest=(await ok('/memories/'+original.id,'PATCH',{expectedRevision:original.revision,visibility:'private'})).memory;
 await db.prepare('DELETE FROM brain_revisions WHERE revision=?').bind(latest.revision).run();for(const[id,v]of drive.objects)if(v.appProperties.cloudnestRevision===latest.revision)drive.objects.delete(id);
 const result=await api('/reindex','POST',{}, {'X-Fixture-Key-Mode':'new-only'});assert.equal(result.status,409);assert.match((await result.json()).error,/post-checkpoint history/);assert.equal((await db.prepare('SELECT visibility FROM brain_heads WHERE memory_id=?').bind(original.id).first()).visibility,'private');
});

test('public vault rotation routes require owner authorization and reject read-only MCP grants',async()=>{
 for(const[path,method,body]of [['/vault/rotation','GET',undefined],['/vault/rotate','POST',{}]]){
  const missing=await fetch(new URL('/api/v1'+path,base),{method,headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});assert.equal(missing.status,401);
  for(const token of [reader,proposer,randomBytes(32).toString('hex')])assert.equal((await api(path,method,body,{},token)).status,401);
 }
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_vault_rotations').first()).n,0);assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock')").first(),null);assert.equal(drive.calls.length,0);
});
test('public vault rotation status before a job returns a safe uncached not-found response',async()=>{
 const response=await api('/vault/rotation');assert.equal(response.status,404);assert.equal(response.headers.get('Cache-Control'),'no-store');assert.match(response.headers.get('Content-Type'),/application\/json/);assert.deepEqual(await response.json(),{error:'Vault rotation not found'});assert.equal(drive.calls.length,0);
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_vault_rotations').first()).n,0);
});
test('public vault rotation route validates cursors and fields before starting maintenance',async()=>{
 for(const cursor of [null,false,12,'not-a-uuid','../operations',{}]){const response=await api('/vault/rotate','POST',{cursor});assert.equal(response.status,400);assert.match((await response.json()).error,/cursor/);}
 for(const body of [{confirm:true},{cursor:randomUUID(),key:nextVaultKey},{cursor:randomUUID(),operation:'rotate'},[]])assert.equal((await api('/vault/rotate','POST',body)).status,400);
 const unknown=await api('/vault/rotate','POST',{cursor:randomUUID()});assert.equal(unknown.status,404);assert.deepEqual(await unknown.json(),{error:'Vault rotation not found'});
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_vault_rotations').first()).n,0);assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock')").first(),null);assert.equal(drive.calls.length,0);
});
test('public vault rotation route enforces its 1024-byte JSON body boundary',async()=>{
 for(const cursor of ['x'.repeat(1100),'🧠'.repeat(260)]){const response=await api('/vault/rotate','POST',{cursor});assert.equal(response.status,400);assert.match((await response.json()).error,/too large/);}
 const headers={Authorization:'Bearer '+owner,'Content-Type':'application/json'};
 const malformed=await fetch(new URL('/api/v1/vault/rotate',base),{method:'POST',headers,body:'{"cursor":'});assert.equal(malformed.status,400);assert.deepEqual(await malformed.json(),{error:'Invalid JSON'});
 const nonJSON=await api('/vault/rotate','POST',{}, {'Content-Type':'text/plain'});assert.equal(nonJSON.status,400);assert.deepEqual(await nonJSON.json(),{error:'Use application/json'});
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_vault_rotations').first()).n,0);assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock')").first(),null);assert.equal(drive.calls.length,0);
});
test('owner can start, inspect and resume rotation through the public router',async()=>{
 await create({visibility:'private'});let progress=await ok('/vault/rotate','POST',{});assert.equal(progress.state,'signing');assert.equal(progress.complete,false);assert.equal(progress.revisions,1);assert.match(progress.cursor,/^[a-f0-9-]{36}$/);assert.equal(progress.keyFingerprint,hash(nextVaultKey));
 const status=await ok('/vault/rotation');assert.deepEqual(status,progress);assert.ok(!JSON.stringify(status).includes(nextVaultKey));assert.ok(!JSON.stringify(status).includes(vaultKey));
 while(!progress.complete)progress=await ok('/vault/rotate','POST',{cursor:progress.cursor});assert.equal(progress.signed,1);assert.equal(progress.state,'complete');assert.ok(progress.checkpointID);assert.match(progress.checkpointSHA256,/^[a-f0-9]{64}$/);assert.deepEqual(await ok('/vault/rotation'),progress);
 assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock')").first(),null);
});
test('direct MCP retrieval suppresses all canonical content under only the durable rotation lock',async()=>{
 const m=await create({title:'Rotation guard fixture',body:'ROTATION_LOCK_CONTENT_SENTINEL'});assert.equal((await memories(m.id)).length,1);
 await db.prepare("INSERT INTO brain_config(key,value) VALUES('vault_rotation_lock',?)").bind(randomUUID()).run();assert.equal(await db.prepare("SELECT value FROM brain_config WHERE key='reindex_lock'").first(),null);
 for(const[name,args]of [['memory_read',{id:m.id}],['memory_search',{query:'Rotation'}],['memory_recent',{project:'project'}],['project_context',{project:'project'}]]){
  const reply=await mcp(name,args);assert.ok(reply.value.result&&!reply.value.result.isError,JSON.stringify(reply.value));const content=JSON.parse(reply.value.result.content[0].text);assert.deepEqual(content.memories,[]);assert.ok(!JSON.stringify(reply.value).includes('ROTATION_LOCK_CONTENT_SENTINEL'));assert.ok(!JSON.stringify(reply.value).includes(m.id));
 }
 await db.prepare("DELETE FROM brain_config WHERE key='vault_rotation_lock'").run();assert.equal((await memories(m.id)).length,1);
});
