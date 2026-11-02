import type { VaultEnv } from '../memory/drive-vault';
import { BrainError,boundedBytes,boundedJSON,sha256,uuid } from '../memory/record';
export interface ErasureEnv extends VaultEnv { CLIENTS_JSON?:string }
interface Job {id:string;state:string;folder_id:string|null;cursor:string|null;inventory_digest:string|null;scanned:number;objects:number;bytes:number;deleted:number;preserved:number;busy_token:string|null;busy_until:number;created_at:string;approved_at:string|null;completed_at:string|null}
interface FileInfo {id:string;mimeType?:string;size?:string;sha256Checksum?:string;trashed?:boolean;parents?:string[];appProperties?:Record<string,string>;owners?:{me?:boolean}[];capabilities?:{canDelete?:boolean}}
interface Item {drive_id:string;kind:string;content_hash:string;bytes:number;markers:string;deleted:number}
const drive='https://www.googleapis.com/drive/v3/';
const confirmation='ERASE CLOUDNEST BRAIN';
const fields='id,mimeType,size,sha256Checksum,trashed,parents,appProperties,owners(me),capabilities(canDelete)';
const states=new Set(['scanning','review','deleting','verifying','purging','complete','cancelled']);
const writeLocks="'reindex_lock','vault_rotation_lock','erasure_lock','account_erased'";
/** Call before all ordinary owner/MCP/OAuth operations. Erasure recovery itself
 * remains a separate owner-Recovery-Bearer-only path, even after session revocation. */
export async function assertErasureAvailable(env:Pick<VaultEnv,'DB'>):Promise<void>{
 const gate=await env.DB.prepare("SELECT key FROM brain_config WHERE key IN('erasure_lock','account_erased')").first<{key:string}>();
 if(gate)throw new BrainError(gate.key==='account_erased'?410:503,gate.key==='account_erased'?'This Brain account has been permanently disabled. Use erasure recovery for its receipt.':'Account erasure review or deletion is active. Resume or cancel it through owner recovery.');
}
async function owner(request:Request,env:ErasureEnv){
 const header=request.headers.get('Authorization'),expected=env.OWNER_TOKEN_SHA256??'';
 if(!header?.startsWith('Bearer ')||header.length<40||header.length>1024||!/^[a-f0-9]{64}$/.test(expected))throw new BrainError(401,'Use the owner recovery connection for permanent erasure');
 const actual=await sha256(header.slice(7));let difference=0;for(let i=0;i<64;i++)difference|=actual.charCodeAt(i)^expected.charCodeAt(i);if(difference)throw new BrainError(401,'Use the owner recovery connection for permanent erasure');
}
function id(value:unknown):asserts value is string {if(typeof value!=='string'||!/^[A-Za-z0-9_-]{1,128}$/.test(value))throw new BrainError(409,'Invalid app-owned Drive identity');}
function keys(input:Record<string,unknown>,allowed:string[]){if(Object.keys(input).some(k=>!allowed.includes(k)))throw new BrainError(400,'Unexpected erasure request field');}
function owned(info:FileInfo){return info.owners?.some(o=>o.me===true)===true&&info.capabilities?.canDelete===true;}
function recognized(info:FileInfo,folder:string):Omit<Item,'deleted'>|null {
 id(info.id);if(!info.parents?.includes(folder))throw new BrainError(409,'A vault item has changed parents');
 const p=info.appProperties??{},isMemory=uuid(p.cloudnestMemory),isReceipt=uuid(p.cloudnestCommit),isCheckpoint=p.cloudnestCheckpoint==='brain-v1';
 if(!isMemory&&!isReceipt&&!isCheckpoint){if(['cloudnestMemory','cloudnestCommit','cloudnestCheckpoint','cloudnestRevision'].some(k=>k in p))throw new BrainError(409,'A canonical ownership marker is malformed');return null;}
 if(!owned(info))throw new BrainError(409,'A canonical object is not owned/deletable by this Google account');
 if(Number(isMemory)+Number(isReceipt)+Number(isCheckpoint)!==1||(!isCheckpoint&&!uuid(p.cloudnestRevision)))throw new BrainError(409,'Canonical ownership markers conflict');
 const kind=isMemory?'memory':isReceipt?'receipt':'checkpoint',mime=isMemory?'text/markdown':'application/json',size=Number(info.size);
 if(info.mimeType!==mime||!Number.isSafeInteger(size)||size<1||size>100000||!/^[a-f0-9]{64}$/.test(info.sha256Checksum??''))throw new BrainError(409,'Canonical metadata is invalid; repair the vault before erasing');
 const markers=JSON.stringify(Object.fromEntries(Object.entries(p).sort(([a],[b])=>a.localeCompare(b))));
 return{drive_id:info.id,kind,content_hash:info.sha256Checksum!,bytes:size,markers};
}
class ErasureDrive {
 private token?:string;
 constructor(private env:ErasureEnv){}
 private async access(){
  if(this.token)return this.token;
  if(!this.env.GOOGLE_CLIENT_ID||!this.env.GOOGLE_CLIENT_SECRET||!this.env.GOOGLE_REFRESH_TOKEN)throw new BrainError(503,'Restore the dedicated Google Brain grant before continuing erasure');
  const response=await fetch('https://oauth2.googleapis.com/token',{method:'POST',redirect:'manual',signal:AbortSignal.timeout(15000),headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:this.env.GOOGLE_CLIENT_ID,client_secret:this.env.GOOGLE_CLIENT_SECRET,refresh_token:this.env.GOOGLE_REFRESH_TOKEN,grant_type:'refresh_token'})});
  if(!response.ok)throw new BrainError(503,'Brain Google authorization is unavailable; no credentials were disclosed');
  const value=JSON.parse(new TextDecoder().decode(await boundedBytes(response.body,16384))) as {access_token?:unknown};if(typeof value.access_token!=='string'||!value.access_token||value.access_token.length>8192)throw new BrainError(503,'Brain Google authorization response is invalid');return this.token=value.access_token;
 }
 private endpoint(path:string,query:Record<string,string>={}){const url=new URL(path,drive);for(const [k,v]of Object.entries(query))url.searchParams.set(k,v);return url;}
 async request(url:URL,init:RequestInit={}){
  if(url.origin!=='https://www.googleapis.com')throw new BrainError(503,'Unexpected erasure endpoint');
  const response=await fetch(url,{...init,redirect:'manual',signal:AbortSignal.timeout(15000),headers:{...Object.fromEntries(new Headers(init.headers)),Authorization:'Bearer '+await this.access()}});
  if(![200,204,404].includes(response.status))throw new BrainError(response.status===429?429:503,'Drive erasure did not complete. Resume the same job; uncertain deletions are rechecked.');return response;
 }
 async metadata(fileID:string):Promise<{info:FileInfo;etag:string|null}|null>{id(fileID);const response=await this.request(this.endpoint('files/'+fileID,{fields}));if(response.status===404)return null;return{info:JSON.parse(new TextDecoder().decode(await boundedBytes(response.body,131072))) as FileInfo,etag:response.headers.get('ETag')};}
 async root(folder:string){const result=await this.metadata(folder);if(!result||result.info.id!==folder||result.info.mimeType!=='application/vnd.google-apps.folder'||result.info.appProperties?.cloudnestRole!=='brain-v1'||!owned(result.info))throw new BrainError(409,'The configured Brain folder is unavailable or its ownership changed');return result.info;}
 async list(folder:string,cursor:string|null){await this.root(folder);const response=await this.request(this.endpoint('files',{q:`'${folder}' in parents`,fields:`files(${fields}),nextPageToken,incompleteSearch`,pageSize:'20',spaces:'drive',...(cursor?{pageToken:cursor}:{})}));const value=JSON.parse(new TextDecoder().decode(await boundedBytes(response.body,262144))) as {files:FileInfo[];nextPageToken?:string;incompleteSearch?:boolean};if(!Array.isArray(value.files)||value.files.length>20||value.incompleteSearch||value.nextPageToken&&(value.nextPageToken.length>4096||value.nextPageToken===cursor))throw new BrainError(503,'Drive inventory is incomplete; erasure approval remains unavailable');return value;}
 async remove(item:Item,folder:string){
  const current=await this.metadata(item.drive_id);if(!current)return; // Lost acknowledgement or deletion by the owner.
  const checked=recognized(current.info,folder);if(!checked||checked.kind!==item.kind||checked.content_hash!==item.content_hash||checked.bytes!==item.bytes||checked.markers!==item.markers)throw new BrainError(409,'A reviewed canonical object changed; it has not been deleted');
  // Canonical objects are immutable. If a provider ETag is available, send its
  // conditional header too; no claim is made that this fences other Drive editors.
  await this.request(this.endpoint('files/'+item.drive_id),{method:'DELETE',headers:current.etag?{'If-Match':current.etag}:{}});
  if(await this.metadata(item.drive_id))throw new BrainError(503,'Drive deletion was not verified. Resume the same job.');
 }
}
async function row(env:ErasureEnv,jobID:string){if(!uuid(jobID))throw new BrainError(400,'Invalid erasure job');const job=await env.DB.prepare('SELECT * FROM brain_erasure_jobs WHERE id=?').bind(jobID).first<Job>();if(!job||!states.has(job.state))throw new BrainError(404,'Erasure job not found');return job;}
function summary(job:Job){return{id:job.id,state:job.state,scanned:job.scanned,objects:job.objects,bytes:job.bytes,deleted:job.deleted,preserved:job.preserved,digest:job.state==='review'?job.inventory_digest:null,createdAt:job.created_at,approvedAt:job.approved_at,completedAt:job.completed_at,recoverable:!job.approved_at,externalCleanupRequired:job.state==='complete'};}
const owns="EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND busy_token=? AND busy_until>?)";
async function lease<T>(env:ErasureEnv,jobID:string,work:(job:Job,token:string)=>Promise<T>):Promise<T>{
 const token=crypto.randomUUID(),now=Date.now();const locked=await env.DB.prepare("UPDATE brain_erasure_jobs SET busy_token=?,busy_until=? WHERE id=? AND state NOT IN('complete','cancelled') AND busy_until<? AND EXISTS(SELECT 1 FROM brain_config WHERE key='erasure_lock' AND value=?)").bind(token,now+600000,jobID,now,jobID).run();
 if(locked.meta.changes!==1)throw new BrainError(409,'Erasure request is running or no longer owns maintenance. Retry its status later.');
 try{return await work(await row(env,jobID),token);}finally{await env.DB.prepare('UPDATE brain_erasure_jobs SET busy_token=NULL,busy_until=0 WHERE id=? AND busy_token=?').bind(jobID,token).run();}
}
export async function prepareAccountErasure(env:ErasureEnv,input:Record<string,unknown>){
 keys(input,['requestId']);if(!uuid(input.requestId))throw new BrainError(400,'Use a UUID requestId');
 const existing=await env.DB.prepare('SELECT id FROM brain_erasure_jobs WHERE id=?').bind(input.requestId).first();if(existing)return summary(await row(env,input.requestId));
 const folder=await env.DB.prepare("SELECT value FROM brain_config WHERE key='drive_folder'").first<{value:string}>();if(folder)id(folder.value);
 if(!folder&&(await env.DB.prepare('SELECT 1 FROM brain_revisions LIMIT 1').first()))throw new BrainError(409,'Restore the configured vault binding before reviewing permanent erasure');
 const result=await env.DB.batch([
  env.DB.prepare(`INSERT INTO brain_config(key,value) SELECT 'erasure_lock',? WHERE NOT EXISTS(SELECT 1 FROM brain_config WHERE key IN(${writeLocks})) AND NOT EXISTS(SELECT 1 FROM brain_intents) AND NOT EXISTS(SELECT 1 FROM brain_import_jobs WHERE next_index<total)`).bind(input.requestId),
  env.DB.prepare("INSERT INTO brain_erasure_jobs(id,state,folder_id,created_at) SELECT ?,'scanning',?,? WHERE EXISTS(SELECT 1 FROM brain_config WHERE key='erasure_lock' AND value=?)").bind(input.requestId,folder?.value??null,new Date().toISOString(),input.requestId)
 ]);
 if(result[0].meta.changes!==1)throw new BrainError(409,'Finish pending writes/imports or existing maintenance before erasure');return summary(await row(env,input.requestId));
}
export async function scanAccountErasure(env:ErasureEnv,jobID:string){return lease(env,jobID,async(job,token)=>{
 if(job.state!=='scanning')return summary(job);const items:Omit<Item,'deleted'>[]=[];let scanned=0,preserved=0,next:string|null=null;
 if(job.folder_id){const page=await new ErasureDrive(env).list(job.folder_id,job.cursor);for(const file of page.files){scanned++;const item=recognized(file,job.folder_id);if(item)items.push(item);else preserved++;}next=page.nextPageToken??null;}
 if(job.scanned+scanned>100000)throw new BrainError(503,'Erasure inventory exceeds 100000 objects; no deletion was approved');
 const pageDigest=await sha256(JSON.stringify([jobID,job.inventory_digest,items,next]));
 const conflict=job.approved_at!==null?"kind=excluded.kind,content_hash=excluded.content_hash,bytes=excluded.bytes,markers=excluded.markers,deleted=0":"kind=CASE WHEN content_hash=excluded.content_hash AND bytes=excluded.bytes AND markers=excluded.markers THEN kind ELSE 'conflict' END";
 const statements=items.map(item=>env.DB.prepare(`INSERT INTO brain_erasure_items(job_id,drive_id,kind,content_hash,bytes,markers) SELECT ?,?,?,?,?,? WHERE ${owns} ON CONFLICT(job_id,drive_id) DO UPDATE SET ${conflict}`).bind(jobID,item.drive_id,item.kind,item.content_hash,item.bytes,item.markers,jobID,token,Date.now()));
 statements.push(env.DB.prepare(`UPDATE brain_erasure_jobs SET cursor=?,inventory_digest=?,scanned=scanned+?,preserved=preserved+? WHERE id=? AND busy_token=? AND busy_until>?`).bind(next,pageDigest,scanned,preserved,jobID,token,Date.now()));await env.DB.batch(statements);
 if(!next){const totals=await env.DB.prepare("SELECT count(*) AS n,coalesce(sum(bytes),0) AS bytes,sum(CASE WHEN kind='conflict' THEN 1 ELSE 0 END) AS conflicts FROM brain_erasure_items WHERE job_id=?").bind(jobID).first<{n:number;bytes:number;conflicts:number}>();if(!totals||totals.n>100000||totals.conflicts)throw new BrainError(409,'Erasure inventory changed while scanning');await env.DB.prepare("UPDATE brain_erasure_jobs SET state='review',objects=?,bytes=? WHERE id=? AND busy_token=? AND busy_until>?").bind(totals.n,totals.bytes,jobID,token,Date.now()).run();}
 return summary(await row(env,jobID));
});}
export async function approveAccountErasure(env:ErasureEnv,jobID:string,input:Record<string,unknown>){
 keys(input,['digest','confirmation']);const job=await row(env,jobID);if(job.approved_at&&job.state!=='review'){if(input.digest!==job.inventory_digest||input.confirmation!==confirmation)throw new BrainError(409,'Erasure approval differs from the existing job');return summary(job);}
 if(job.state!=='review'||input.digest!==job.inventory_digest||input.confirmation!==confirmation)throw new BrainError(400,'Review the completed inventory and type the exact erasure confirmation');
 if(job.folder_id)await new ErasureDrive(env).root(job.folder_id);
 const now=new Date().toISOString();const result=await env.DB.batch([
  env.DB.prepare("UPDATE brain_erasure_jobs SET state='deleting',approved_at=? WHERE id=? AND state='review' AND busy_token IS NULL AND EXISTS(SELECT 1 FROM brain_config WHERE key='erasure_lock' AND value=?)").bind(now,jobID,jobID),
  env.DB.prepare("INSERT INTO brain_config(key,value) SELECT 'account_erased','disabled' WHERE EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND approved_at=?) ON CONFLICT(key) DO NOTHING").bind(jobID,now),
  ...['oauth_access','oauth_refresh','oauth_requests','oauth_grants','oauth_clients','brain_clients','brain_client_revocations','brain_browser_sessions','brain_browser_challenges','brain_browser_passkeys','brain_browser_owners'].map(table=>env.DB.prepare(`DELETE FROM ${table} WHERE EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND approved_at=?)`).bind(jobID,now))
 ]);if(result[0].meta.changes!==1)throw new BrainError(409,'Erasure approval ownership changed; read job status');return summary(await row(env,jobID));
}
const userTables=['brain_audit_prune_items','brain_audit_prunes','brain_conversation_sources','brain_conversation_imports','brain_restore_requests','brain_archives','brain_import_jobs','brain_inbox','memories','brain_heads','brain_revisions','brain_intents','brain_reindex_rows','brain_reindex_receipts','brain_reindex_untrusted','brain_reindex_retired','brain_reindex_checkpoints','brain_reindex_checkpoint_receipts','brain_reindex_jobs','brain_vault_rotation_rows','brain_vault_rotation_receipts','brain_vault_rotation_heads','brain_vault_rotation_roots','brain_vault_rotations','oauth_access','oauth_refresh','oauth_requests','oauth_grants','oauth_clients','brain_clients','brain_client_revocations','brain_browser_sessions','brain_browser_challenges','brain_browser_passkeys','brain_browser_owners','brain_rate_limits','audit'];
export async function resumeAccountErasure(env:ErasureEnv,jobID:string){
 const previous=await row(env,jobID);if(previous.state==='complete')return summary(previous);
 return lease(env,jobID,async(job,token)=>{
  if(!job.approved_at||!['deleting','verifying','purging'].includes(job.state))throw new BrainError(409,'Erasure has not been approved');const vault=new ErasureDrive(env);
  if(job.state==='deleting'){
   const items=(await env.DB.prepare('SELECT drive_id,kind,content_hash,bytes,markers,deleted FROM brain_erasure_items WHERE job_id=? AND deleted=0 ORDER BY drive_id LIMIT 5').bind(jobID).all<Item>()).results;
   if(items.length&&!job.folder_id)throw new BrainError(409,'Erasure lost its frozen folder binding');
   if(job.folder_id)await vault.root(job.folder_id);
   for(const item of items){if(!await env.DB.prepare(`SELECT 1 FROM brain_erasure_jobs WHERE id=? AND busy_token=? AND busy_until>?`).bind(jobID,token,Date.now()).first())throw new BrainError(409,'Erasure request lease expired');await vault.remove(item,job.folder_id!);await env.DB.prepare(`UPDATE brain_erasure_items SET deleted=1 WHERE job_id=? AND drive_id=? AND ${owns}`).bind(jobID,item.drive_id,jobID,token,Date.now()).run();}
   const remaining=(await env.DB.prepare('SELECT count(*) AS n FROM brain_erasure_items WHERE job_id=? AND deleted=0').bind(jobID).first<{n:number}>())?.n??0;
   await env.DB.prepare("UPDATE brain_erasure_jobs SET deleted=(SELECT count(*) FROM brain_erasure_items WHERE job_id=? AND deleted=1),state=CASE WHEN ?=0 THEN 'verifying' ELSE state END,cursor=NULL WHERE id=? AND busy_token=? AND busy_until>?").bind(jobID,remaining,jobID,token,Date.now()).run();return summary(await row(env,jobID));
  }
  if(job.state==='verifying'){
   let next:string|null=null;if(job.folder_id){const page=await vault.list(job.folder_id,job.cursor);if(page.files.some(file=>recognized(file,job.folder_id!)!==null))throw new BrainError(409,'A canonical object remains or was added after review. Account stays disabled; operator recovery is required.');next=page.nextPageToken??null;}
   await env.DB.prepare("UPDATE brain_erasure_jobs SET cursor=?,state=? WHERE id=? AND busy_token=? AND busy_until>?").bind(next,next?'verifying':'purging',jobID,token,Date.now()).run();return summary(await row(env,jobID));
  }
  const fenced=`EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND busy_token=? AND busy_until>? AND state='purging')`;
  const statements=userTables.map(table=>env.DB.prepare(`DELETE FROM ${table} WHERE ${fenced}`).bind(jobID,token,Date.now()));
  statements.push(env.DB.prepare(`DELETE FROM brain_config WHERE key NOT IN('account_erased','erasure_lock') AND ${fenced}`).bind(jobID,token,Date.now()),env.DB.prepare(`DELETE FROM brain_erasure_items WHERE ${fenced}`).bind(jobID,token,Date.now()),env.DB.prepare(`DELETE FROM brain_erasure_jobs WHERE id<>? AND ${fenced}`).bind(jobID,jobID,token,Date.now()),env.DB.prepare("UPDATE brain_erasure_jobs SET state='complete',folder_id=NULL,cursor=NULL,inventory_digest=NULL,completed_at=? WHERE id=? AND busy_token=? AND busy_until>? AND state='purging'").bind(new Date().toISOString(),jobID,token,Date.now()),env.DB.prepare("DELETE FROM brain_config WHERE key='erasure_lock' AND value=? AND EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND state='complete')").bind(jobID,jobID));
  const results=await env.DB.batch(statements);if(results.at(-2)?.meta.changes!==1)throw new BrainError(409,'Erasure finalization lease changed');return summary(await row(env,jobID));
 });
}
/** Refresh changed/new owned objects after partial deletion. Previously approved
 * identities remain in inventory so uncertain 404 deletions are still accounted.
 * No further delete is allowed until the new exact digest is explicitly approved. */
export async function reviewAccountErasureAgain(env:ErasureEnv,jobID:string){
 const nonce=crypto.randomUUID();const result=await env.DB.batch([
  env.DB.prepare("UPDATE brain_erasure_jobs SET state='scanning',cursor=NULL,inventory_digest=NULL,scanned=0,preserved=0,busy_token=? WHERE id=? AND approved_at IS NOT NULL AND state IN('deleting','verifying') AND busy_token IS NULL AND EXISTS(SELECT 1 FROM brain_config WHERE key='erasure_lock' AND value=?)").bind(nonce,jobID,jobID),
  env.DB.prepare("UPDATE brain_erasure_jobs SET busy_token=NULL WHERE id=? AND busy_token=?").bind(jobID,nonce)
 ]);if(result[0].meta.changes!==1)throw new BrainError(409,'Wait for the current request before re-reviewing a partially erased account');return summary(await row(env,jobID));
}
export async function cancelAccountErasure(env:ErasureEnv,jobID:string){
 const job=await row(env,jobID);if(job.state==='cancelled')return summary(job);if(job.approved_at)throw new BrainError(409,'Permanent erasure was approved and cannot be cancelled or undone');
 const result=await env.DB.batch([env.DB.prepare("UPDATE brain_erasure_jobs SET state='cancelled',folder_id=NULL,cursor=NULL,inventory_digest=NULL,completed_at=? WHERE id=? AND approved_at IS NULL AND busy_token IS NULL").bind(new Date().toISOString(),jobID),env.DB.prepare("DELETE FROM brain_erasure_items WHERE job_id=? AND EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND state='cancelled')").bind(jobID,jobID),env.DB.prepare("DELETE FROM brain_config WHERE key='erasure_lock' AND value=? AND EXISTS(SELECT 1 FROM brain_erasure_jobs WHERE id=? AND state='cancelled')").bind(jobID,jobID)]);if(result[0].meta.changes!==1)throw new BrainError(409,'Erasure request is running; wait before cancelling');return summary(await row(env,jobID));
}
export async function erasureStatus(env:ErasureEnv){const job=await env.DB.prepare("SELECT * FROM brain_erasure_jobs ORDER BY CASE WHEN state NOT IN('complete','cancelled') THEN 0 ELSE 1 END,created_at DESC LIMIT 1").first<Job>();return{job:job?summary(job):null,accountDisabled:!!await env.DB.prepare("SELECT 1 FROM brain_config WHERE key='account_erased'").first()};}
/** Root router calls this before ordinary service availability gates, after its
 * existing HTTPS/host/Origin boundaries. No MCP tool may call these operations. */
export async function handleAccountErasure(request:Request,env:ErasureEnv,path:string):Promise<Response|null>{
 if(path!=='/account-erasure'&&!path.startsWith('/account-erasure/'))return null;await owner(request,env);
 const response=(value:unknown)=>Response.json(value,{headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'}});
 if(path==='/account-erasure'&&request.method==='GET')return response(await erasureStatus(env));
 if(request.method!=='POST')throw new BrainError(404,'Erasure route not found');
 const input=await boundedJSON(request,4096);if(path==='/account-erasure/prepare')return response(await prepareAccountErasure(env,input));
 const match=path.match(/^\/account-erasure\/([^/]+)\/(scan|approve|resume|cancel|rescan)$/);if(!match)throw new BrainError(404,'Erasure route not found');
 if(match[2]!=='approve')keys(input,[]);
 return response(match[2]==='scan'?await scanAccountErasure(env,match[1]):match[2]==='approve'?await approveAccountErasure(env,match[1],input):match[2]==='resume'?await resumeAccountErasure(env,match[1]):match[2]==='rescan'?await reviewAccountErasureAgain(env,match[1]):await cancelAccountErasure(env,match[1]));
}
