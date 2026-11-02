import type { ErasureEnv } from './erasure';
import { assertErasureAvailable } from './erasure';
import { BrainError,boundedJSON,sha256,uuid } from '../memory/record';
interface Plan {id:string;state:string;cutoff:string;retention_days:number;high_water:number;expected:number;digest:string;deleted:number;busy_token:string|null;busy_until:number;created_at:string;completed_at:string|null}
const available="NOT EXISTS(SELECT 1 FROM brain_config WHERE key IN('erasure_lock','account_erased'))";
const summary=(p:Plan)=>({id:p.id,state:p.state,cutoff:p.cutoff,days:p.retention_days,expected:p.expected,deleted:p.deleted,digest:p.state==='review'?p.digest:null,createdAt:p.created_at,completedAt:p.completed_at});
const fields=(input:Record<string,unknown>,keys:string[])=>{if(Object.keys(input).some(k=>!keys.includes(k)))throw new BrainError(400,'Unexpected audit retention field');};
async function plan(env:ErasureEnv,id:unknown){if(!uuid(id))throw new BrainError(400,'Invalid audit retention plan');const p=await env.DB.prepare('SELECT * FROM brain_audit_prunes WHERE id=?').bind(id).first<Plan>();if(!p)throw new BrainError(404,'Audit retention plan not found');return p;}
export async function previewAuditRetention(env:ErasureEnv,input:Record<string,unknown>){
 await assertErasureAvailable(env);fields(input,['requestId','days']);if(!uuid(input.requestId)||!Number.isSafeInteger(input.days)||(input.days as number)<1||(input.days as number)>3650)throw new BrainError(400,'Choose a retention age from 1 to 3650 days and a UUID requestId');
 const existing=await env.DB.prepare('SELECT * FROM brain_audit_prunes WHERE id=?').bind(input.requestId).first<Plan>();if(existing){if(existing.retention_days!==input.days)throw new BrainError(409,'This review ID belongs to a different retention age');return summary(existing);}
 const cutoff=new Date(Date.now()-(input.days as number)*86400000).toISOString(),scope=await env.DB.prepare('SELECT coalesce(max(id),0) AS high,count(*) AS n FROM audit WHERE created_at<?').bind(cutoff).first<{high:number;n:number}>();if(!scope||!Number.isSafeInteger(scope.high)||!Number.isSafeInteger(scope.n))throw new BrainError(503,'Audit review exceeds safe numeric limits');
 const digest=await sha256(JSON.stringify({id:input.requestId,cutoff,highWater:scope.high,count:scope.n}));
 const result=await env.DB.batch([
  env.DB.prepare(`INSERT INTO brain_config(key,value) SELECT 'audit_prune_lock',? WHERE ${available} AND NOT EXISTS(SELECT 1 FROM brain_config WHERE key='audit_prune_lock')`).bind(input.requestId),
  env.DB.prepare(`INSERT INTO brain_audit_prunes(id,state,cutoff,retention_days,high_water,expected,digest,created_at) SELECT ?,'review',?,?,?,?,?,? WHERE ${available} AND EXISTS(SELECT 1 FROM brain_config WHERE key='audit_prune_lock' AND value=?)`).bind(input.requestId,cutoff,input.days,scope.high,scope.n,digest,new Date().toISOString(),input.requestId)
 ]);if(result[0].meta.changes!==1)throw new BrainError(409,'Resume or cancel the existing audit retention review first');return summary(await plan(env,input.requestId));
}
export async function approveAuditRetention(env:ErasureEnv,id:string,input:Record<string,unknown>){
 await assertErasureAvailable(env);fields(input,['digest','confirmation']);const p=await plan(env,id);if(input.digest!==p.digest||input.confirmation!=='DELETE OLD ACCESS LOGS')throw new BrainError(400,'Review the cutoff/count and type DELETE OLD ACCESS LOGS');if(p.state==='deleting'||p.state==='complete')return summary(p);
 const result=await env.DB.prepare(`UPDATE brain_audit_prunes SET state='deleting' WHERE id=? AND state='review' AND ${available} AND EXISTS(SELECT 1 FROM brain_config WHERE key='audit_prune_lock' AND value=?)`).bind(id,id).run();if(result.meta.changes!==1)throw new BrainError(409,'Audit review changed');return summary(await plan(env,id));
}
export async function stepAuditRetention(env:ErasureEnv,id:string){
 await assertErasureAvailable(env);const p=await plan(env,id);if(p.state==='complete')return summary(p);if(p.state!=='deleting')throw new BrainError(409,'Approve this audit review first');
 const token=crypto.randomUUID(),now=Date.now(),claimed=await env.DB.prepare(`UPDATE brain_audit_prunes SET busy_token=?,busy_until=? WHERE id=? AND state='deleting' AND busy_until<? AND ${available} AND EXISTS(SELECT 1 FROM brain_config WHERE key='audit_prune_lock' AND value=?)`).bind(token,now+60000,id,now,id).run();if(claimed.meta.changes!==1)throw new BrainError(409,'An audit cleanup request is already running');
 const fence=`${available} AND EXISTS(SELECT 1 FROM brain_audit_prunes WHERE id=? AND busy_token=? AND busy_until>?)`;
 try{
  const statements=[
   env.DB.prepare(`INSERT INTO brain_audit_prune_items(job_id,audit_id) SELECT ?,id FROM audit WHERE id<=? AND created_at<? AND ${fence} ORDER BY id LIMIT 200`).bind(id,p.high_water,p.cutoff,id,token,Date.now()),
   env.DB.prepare(`DELETE FROM audit WHERE id IN(SELECT audit_id FROM brain_audit_prune_items WHERE job_id=?) AND ${fence}`).bind(id,id,token,Date.now()),
   env.DB.prepare(`UPDATE brain_audit_prunes SET deleted=deleted+(SELECT count(*) FROM brain_audit_prune_items WHERE job_id=?),state=CASE WHEN EXISTS(SELECT 1 FROM audit WHERE id<=? AND created_at<?) THEN 'deleting' ELSE 'complete' END,completed_at=CASE WHEN EXISTS(SELECT 1 FROM audit WHERE id<=? AND created_at<?) THEN NULL ELSE ? END WHERE id=? AND ${fence}`).bind(id,p.high_water,p.cutoff,p.high_water,p.cutoff,new Date().toISOString(),id,id,token,Date.now()),
   env.DB.prepare(`DELETE FROM brain_audit_prune_items WHERE job_id=? AND ${fence}`).bind(id,id,token,Date.now()),
   env.DB.prepare("DELETE FROM brain_config WHERE key='audit_prune_lock' AND value=? AND EXISTS(SELECT 1 FROM brain_audit_prunes WHERE id=? AND state='complete' AND busy_token=?)").bind(id,id,token)
  ];const results=await env.DB.batch(statements);if(results[2].meta.changes!==1)throw new BrainError(409,'Audit cleanup maintenance changed');return summary(await plan(env,id));
 }finally{await env.DB.prepare('UPDATE brain_audit_prunes SET busy_token=NULL,busy_until=0 WHERE id=? AND busy_token=?').bind(id,token).run();}
}
export async function cancelAuditRetention(env:ErasureEnv,id:string){
 await assertErasureAvailable(env);const p=await plan(env,id);if(p.state==='cancelled')return summary(p);if(p.state!=='review')throw new BrainError(409,'Approved audit removal is irreversible; finish its bounded steps');
 const result=await env.DB.batch([env.DB.prepare(`UPDATE brain_audit_prunes SET state='cancelled',completed_at=? WHERE id=? AND state='review' AND ${available}`).bind(new Date().toISOString(),id),env.DB.prepare("DELETE FROM brain_config WHERE key='audit_prune_lock' AND value=? AND EXISTS(SELECT 1 FROM brain_audit_prunes WHERE id=? AND state='cancelled')").bind(id,id)]);if(result[0].meta.changes!==1)throw new BrainError(409,'Audit review changed');return summary(await plan(env,id));
}
export async function auditRetentionStatus(env:ErasureEnv){await assertErasureAvailable(env);const p=await env.DB.prepare("SELECT * FROM brain_audit_prunes ORDER BY CASE WHEN state IN('review','deleting') THEN 0 ELSE 1 END,created_at DESC LIMIT 1").first<Plan>();return{plan:p?summary(p):null};}
/** Root must call after owner authorization/CSRF and ordinary availability gate. */
export async function handleAuditRetention(request:Request,env:ErasureEnv,path:string):Promise<Response|null>{
 if(path!=='/audit-retention'&&!path.startsWith('/audit-retention/'))return null;
 const response=(value:unknown)=>Response.json(value,{headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
 if(path==='/audit-retention'&&request.method==='GET')return response(await auditRetentionStatus(env));
 if(request.method!=='POST')throw new BrainError(404,'Audit retention route not found');const input=await boundedJSON(request,2048);
 if(path==='/audit-retention/preview')return response(await previewAuditRetention(env,input));const match=path.match(/^\/audit-retention\/([^/]+)\/(approve|step|cancel)$/);if(!match)throw new BrainError(404,'Audit retention route not found');if(match[2]!=='approve')fields(input,[]);
 return response(match[2]==='approve'?await approveAuditRetention(env,match[1],input):match[2]==='step'?await stepAuditRetention(env,match[1]):await cancelAuditRetention(env,match[1]));
}
