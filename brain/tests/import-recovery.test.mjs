import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash,createHmac,randomBytes,randomUUID} from 'node:crypto';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
const {unstable_splitSqlQuery:split}=wrangler;
const hash=x=>createHash('sha256').update(x).digest('hex');
const owner=randomBytes(32).toString('hex'),reader=randomBytes(32).toString('hex'),vaultKey=randomBytes(32).toString('hex');
let script,runtime,db,base,directory,drive;
// Explicit Drive HTTP fixture; no live Google, cloud configuration or user data.
class FakeDrive {
  get revisionCount(){return [...this.objects.values()].filter(v=>v.appProperties.cloudnestMemory).length;}
  get receiptCount(){return [...this.objects.values()].filter(v=>v.appProperties.cloudnestCommit).length;}
  objects=new Map(); folders=new Map(); calls=[]; failNextUpload=false; loseNextAcknowledgement=false; corruptNextUpload=false;
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
    if(url.searchParams.get('alt')==='media')return new Response(value.content,{headers:{'Content-Type':'text/markdown'}});
    return this.json(this.info(id,value));
  }
  inject(record){
    const {body,...metadata}=record;const content='<!-- CloudNest canonical memory v1 -->\n```json\n'+JSON.stringify(metadata,null,2)+'\n```\n\n'+body;
    const id='injected-'+randomUUID();this.objects.set(id,{content,parents:[[...this.folders.keys()][0]],appProperties:{cloudnestMemory:record.id,cloudnestRevision:record.revision}});const receipt={format:'cloudnest-commit-v1',memoryID:record.id,revision:record.revision,version:record.version,canonicalID:id,sha256:hash(content)};receipt.signature=createHmac('sha256',Buffer.from(vaultKey,'hex')).update(JSON.stringify(receipt)).digest('hex');this.objects.set('receipt-'+randomUUID(),{content:JSON.stringify(receipt),parents:[[...this.folders.keys()][0]],appProperties:{cloudnestCommit:record.id,cloudnestRevision:record.revision}});return id;
  }
}
class GatedDrive extends FakeDrive {
  gate=null;uploadAttempts=0;failAtUpload=0;
  async fetch(request){if(new URL(request.url).pathname==='/upload/drive/v3/files'&&request.method==='POST'){if(++this.uploadAttempts===this.failAtUpload)return this.json({error:'fixture interrupted later record'},503);if(this.gate){const gate=this.gate;this.gate=null;gate.entered();await gate.wait;}}return super.fetch(request);}
}
before(async()=>{script=(await build({entryPoints:['brain/worker/index.ts'],bundle:true,write:false,format:'esm',target:'es2022'})).outputFiles[0].text;});
async function start(){
  runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',host:'127.0.0.1',port:0,cf:false,d1Databases:{DB:'import-test',LEGACY:'legacy-migration-test'},resourcePersistencePath:directory,outboundService:r=>drive.fetch(r),bindings:{CLIENTS_JSON:JSON.stringify([{id:'reader',sha256:hash(reader),projects:['project'],expiresAt:'2099-01-01T00:00:00Z'}]),ALLOWED_ORIGINS:'',PUBLIC_ORIGIN:'',BRAIN_ENABLED:'true',VAULT_SIGNING_KEY:vaultKey,OWNER_TOKEN_SHA256:hash(owner),GOOGLE_CLIENT_ID:'fixture.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fixture-client-secret',GOOGLE_REFRESH_TOKEN:'fixture-refresh-token'}}));
  base=await runtime.ready;db=await runtime.getD1Database('DB');
}
async function migrate(database,files=['0001_feasibility.sql','0002_canonical.sql','0003_oauth.sql','0004_import_recovery.sql']){for(const file of files)await database.batch(split(await readFile('brain/migrations/'+file,'utf8')).map(s=>database.prepare(s)));}
beforeEach(async()=>{directory=await mkdtemp(join(tmpdir(),'cloudnest-import-'));drive=new GatedDrive();await start();await migrate(db);});
afterEach(async()=>{await runtime?.dispose();await rm(directory,{recursive:true,force:true});});
const api=(path,method='GET',body,key,token=owner)=>fetch(new URL('/api/v1'+path,base),{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...(key?{'Idempotency-Key':key}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
async function ok(response){const value=await response.json();assert.ok(response.ok,JSON.stringify({status:response.status,value}));return value;}
function batch(count=5){return{memories:Array.from({length:count},(_,i)=>({id:randomUUID(),project:'project',title:'Import fixture '+i,body:'PRIVATE_IMPORT_MATERIAL_'+i,source:'fixture:import-recovery',category:'decision',visibility:'approved',relationships:[]}))};}
async function heads(){return(await db.prepare('SELECT payload FROM brain_heads ORDER BY memory_id').all()).results.map(r=>JSON.parse(r.payload));}
function gateUpload(){let entered,release;const whenEntered=new Promise(r=>{entered=r;}),wait=new Promise(r=>{release=r;});drive.gate={entered,wait};return{whenEntered,release};}

test('a lost initial response retries the same job key without new records or planned identities',async()=>{
  const input=batch(),key=randomUUID();const ignored=await api('/import','POST',input,key);assert.equal(ignored.status,201);await ignored.arrayBuffer();
  const original=await db.prepare('SELECT payload FROM brain_import_jobs WHERE id=?').bind(key).first();const planned=JSON.parse(original.payload).records.map(r=>r.input.id);
  const retry=await ok(await api('/import','POST',input,key));assert.equal(retry.jobId,key);assert.equal(retry.processed,4);assert.equal(retry.total,5);assert.equal(retry.cursor,key);
  const complete=await ok(await api('/import','POST',{cursor:key}));assert.equal(complete.processed,5);assert.equal(complete.complete,true);assert.equal(complete.cursor,null);
  const replay=await ok(await api('/import','POST',input,key));assert.deepEqual(replay.memories,[]);assert.equal(replay.processed,5);assert.equal(replay.complete,true);
  const saved=await heads();assert.deepEqual(saved.map(m=>m.id).sort(),planned.sort());assert.ok(saved.every(m=>m.visibility==='private'&&m.confidence==='imported'));assert.equal(drive.revisionCount,5);assert.equal(drive.receiptCount,5);assert.equal((await db.prepare('SELECT count(*) n FROM brain_import_jobs').first()).n,1);
});
test('request hashing rejects changed input but accepts reordered JSON object keys',async()=>{
  const input=batch(3),key=randomUUID();await ok(await api('/import','POST',input,key));
  const before=(await db.prepare('SELECT payload,next_index FROM brain_import_jobs WHERE id=?').bind(key).first());const changed=structuredClone(input);changed.memories[0].body='Changed import';assert.equal((await api('/import','POST',changed,key)).status,409);
  assert.deepEqual(await db.prepare('SELECT payload,next_index FROM brain_import_jobs WHERE id=?').bind(key).first(),before);
  const reordered={memories:input.memories.map(r=>Object.fromEntries(Object.entries(r).reverse()))};const complete=await ok(await api('/import','POST',reordered,key));assert.equal(complete.complete,true);assert.equal((await heads()).length,3);assert.equal((await api('/import','POST',input,'not-a-UUID')).status,400);
});
test('lost Drive acknowledgement resumes the same initial job and immutable file ID',async()=>{
  const input=batch(3),key=randomUUID();drive.loseNextAcknowledgement=true;assert.equal((await api('/import','POST',input,key)).status,503);assert.equal(drive.revisionCount,1);
  const original=await db.prepare('SELECT payload,next_index FROM brain_import_jobs WHERE id=?').bind(key).first();assert.equal(original.next_index,0);
  const retry=await ok(await api('/import','POST',input,key));assert.equal(retry.processed,2);await ok(await api('/import','POST',{cursor:key}));assert.equal(drive.revisionCount,3);assert.equal((await heads()).length,3);assert.equal((await db.prepare('SELECT payload FROM brain_import_jobs WHERE id=?').bind(key).first()).payload,original.payload);
});
test('progress for a committed record survives failure of the next record in the same step',async()=>{
  const input=batch(3),key=randomUUID();drive.failAtUpload=3;assert.equal((await api('/import','POST',input,key)).status,503);assert.equal((await heads()).length,1);assert.equal((await ok(await api('/imports'))).imports[0].nextIndex,1);
  const resumed=await ok(await api('/import','POST',{cursor:key}));assert.equal(resumed.processed,3);assert.equal(resumed.complete,true);assert.equal(resumed.memories.length,2);assert.equal((await heads()).length,3);assert.equal(drive.revisionCount,3);
});
test('metadata listing is owner-only, bounded, pending-first and never includes import content',async()=>{
  const pendingKey=randomUUID(),input=batch(3);await ok(await api('/import','POST',input,pendingKey));await ok(await api('/import','POST',batch(1),randomUUID()));
  await db.batch(Array.from({length:101},(_,i)=>db.prepare('INSERT INTO brain_import_jobs(id,payload,next_index,created_at,total) VALUES(?,?,1,?,1)').bind(randomUUID(),JSON.stringify({records:[{input:{body:'PRIVATE_IMPORT_MATERIAL_SENTINEL'}}]}),new Date(Date.now()+i*1000).toISOString())));
  const result=await ok(await api('/imports'));assert.equal(result.imports.length,100);assert.equal(result.imports[0].id,pendingKey);assert.equal(result.imports[0].nextIndex,2);assert.equal(result.imports[0].total,3);assert.equal(result.imports[0].complete,false);
  for(const job of result.imports)assert.deepEqual(Object.keys(job).sort(),['complete','createdAt','id','nextIndex','total']);assert.ok(!JSON.stringify(result).includes('PRIVATE_IMPORT_MATERIAL'));assert.equal((await api('/imports','GET',undefined,undefined,reader)).status,401);
  assert.ok(await db.prepare("SELECT id FROM audit WHERE action='owner_import_jobs'").first());await db.prepare('DROP TABLE audit').run();assert.equal((await api('/imports')).status,503);
});
test('concurrent initial requests retain one plan and one active upload step',async()=>{
  const input=batch(3),key=randomUUID(),gate=gateUpload(),first=api('/import','POST',input,key);await gate.whenEntered;
  try{assert.equal((await api('/import','POST',input,key)).status,409);assert.equal((await db.prepare('SELECT count(*) n FROM brain_import_jobs').first()).n,1);}finally{gate.release();}
  assert.equal((await first).status,201);await ok(await api('/import','POST',{cursor:key}));assert.equal((await heads()).length,3);assert.equal(drive.revisionCount,3);
});
test('concurrent cursor resumes cannot duplicate the same bounded step',async()=>{
  const input=batch(),key=randomUUID();await ok(await api('/import','POST',input,key));const gate=gateUpload(),first=api('/import','POST',{cursor:key});await gate.whenEntered;
  try{assert.equal((await api('/import','POST',{cursor:key})).status,409);}finally{gate.release();}
  assert.equal((await ok(await first)).processed,4);const done=await ok(await api('/import','POST',{cursor:key}));assert.equal(done.complete,true);assert.equal((await heads()).length,5);assert.equal(drive.revisionCount,5);
});
test('pending jobs and planned IDs survive an actual Worker runtime restart with persisted D1',async()=>{
  const input=batch(),key=randomUUID();await ok(await api('/import','POST',input,key));const before=await db.prepare('SELECT payload FROM brain_import_jobs WHERE id=?').bind(key).first();await db.prepare('UPDATE brain_import_jobs SET busy_token=?,busy_until=? WHERE id=?').bind(randomUUID(),Date.now()+600000,key).run();
  await runtime.dispose();await start();assert.equal((await ok(await api('/imports'))).imports[0].id,key);assert.equal((await api('/import','POST',{cursor:key})).status,409);
  // Simulate lease time elapsing without a ten-minute wall-clock sleep.
  await db.prepare('UPDATE brain_import_jobs SET busy_until=0 WHERE id=?').bind(key).run();let result=await ok(await api('/import','POST',{cursor:key}));while(!result.complete)result=await ok(await api('/import','POST',{cursor:key}));
  assert.equal(result.processed,5);assert.equal((await db.prepare('SELECT payload FROM brain_import_jobs WHERE id=?').bind(key).first()).payload,before.payload);assert.equal((await heads()).length,5);assert.equal(drive.revisionCount,5);
});
test('append migration preserves legacy jobs and legacy cursor recovery',async()=>{
  const legacy=await runtime.getD1Database('LEGACY');await migrate(legacy,['0001_feasibility.sql','0002_canonical.sql']);const key=randomUUID(),payload=JSON.stringify({records:[{},{},{}],unresolvedReferences:[]});await legacy.prepare('INSERT INTO brain_import_jobs(id,payload,next_index,created_at) VALUES(?,?,1,?)').bind(key,payload,new Date().toISOString()).run();await migrate(legacy,['0004_import_recovery.sql']);const old=await legacy.prepare('SELECT payload,next_index,total,request_hash FROM brain_import_jobs WHERE id=?').bind(key).first();assert.equal(old.payload,payload);assert.equal(old.next_index,1);assert.equal(old.total,3);assert.equal(old.request_hash,null);
  const input=batch(3),current=randomUUID();await ok(await api('/import','POST',input,current));await db.prepare('UPDATE brain_import_jobs SET request_hash=NULL WHERE id=?').bind(current).run();assert.equal((await api('/import','POST',input,current)).status,409);const resumed=await ok(await api('/import','POST',{cursor:current}));assert.equal(resumed.complete,true);assert.equal((await heads()).length,3);
});
