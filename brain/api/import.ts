import { BrainService } from './service';
import { BrainError,MemoryRecord,makeRecord,object,sha256,uuid } from '../memory/record';
interface Plan {records:{input:Record<string,unknown>,operationId:string,deleted:boolean}[];unresolvedReferences:{memoryId:string,target:string}[]}
interface Job {id:string;payload:string;next_index:number;total:number;request_hash:string|null;created_at:string}
const LEASE_MS=10*60*1000;

// Object key order is immaterial; array order and every supplied field remain
// part of the identity. Bound depth before hashing untrusted portable input.
function ordered(value:unknown,depth=0):unknown{
  if(depth>32)throw new BrainError(400,'Import JSON exceeds the nesting limit');
  if(Array.isArray(value))return value.map(v=>ordered(v,depth+1));
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,v])=>[k,ordered(v,depth+1)]));
  return value;
}
function makePlan(input:Record<string,unknown>):Plan{
  if(Object.keys(input).some(k=>k!=='memories')||!Array.isArray(input.memories)||input.memories.length<1||input.memories.length>20)throw new BrainError(400,'Import 1–20 records per portable batch');
  const mapping=new Map<string,string>(),raw=input.memories.map(object);for(const r of raw)if(r.id!==undefined){if(!uuid(r.id)||mapping.has(r.id))throw new BrainError(400,'Imported IDs must be unique UUIDs');mapping.set(r.id,crypto.randomUUID());}
  const unresolvedReferences:{memoryId:string,target:string}[]=[];
  const records=raw.map(r=>{
    const memoryID=typeof r.id==='string'?mapping.get(r.id)!:crypto.randomUUID();const relationships=r.relationships??[];if(!Array.isArray(relationships))throw new BrainError(400,'Invalid imported relationships');
    const relations=relationships.map(value=>{const rel=object(value);if(typeof rel.target!=='string')throw new BrainError(400,'Invalid imported relationship');const target=mapping.get(rel.target);if(!target)unresolvedReferences.push({memoryId:memoryID,target:rel.target});return{...rel,target:target??rel.target};});
    const cleaned={id:memoryID,project:r.project,title:r.title,body:r.body,source:r.source,category:r.category??'knowledge',visibility:'private',expiresAt:r.expiresAt??null,relationships:relations,confidence:'imported'};
    if(r.deleted!==undefined&&typeof r.deleted!=='boolean')throw new BrainError(400,'Invalid imported deletion state');const deleted=r.deleted===true;makeRecord(cleaned,null,deleted,true);return{input:cleaned,operationId:crypto.randomUUID(),deleted};
  });
  return{records,unresolvedReferences};
}
export async function listImports(service:BrainService):Promise<unknown>{
  const rows=(await service.env.DB.prepare('SELECT id,created_at AS createdAt,total,next_index AS nextIndex FROM brain_import_jobs ORDER BY (next_index<total) DESC,created_at DESC,id LIMIT 100').all<{id:string;createdAt:string;total:number;nextIndex:number}>()).results;
  await service.audit('owner_import_jobs');return{imports:rows.map(row=>({...row,complete:row.nextIndex>=row.total}))};
}
export async function importMemories(service:BrainService,input:Record<string,unknown>,idempotencyKey?:string):Promise<unknown>{
  await service.audit('owner_import_step');let id:string,requestHash:string|undefined;
  if(input.cursor!==undefined){
    if(Object.keys(input).length!==1||!uuid(input.cursor))throw new BrainError(400,'Invalid import cursor');id=input.cursor;
  }else{
    id=idempotencyKey??crypto.randomUUID();if(!uuid(id))throw new BrainError(400,'Use a UUID Idempotency-Key');
    requestHash=await sha256(JSON.stringify(ordered(input)));
    const existing=await service.env.DB.prepare('SELECT request_hash FROM brain_import_jobs WHERE id=?').bind(id).first<{request_hash:string|null}>();
    if(!existing){
      const plan=makePlan(input);
      // A racing creator must load the winner's durable IDs, never replace them.
      await service.env.DB.prepare('INSERT INTO brain_import_jobs(id,payload,created_at,request_hash,total) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING').bind(id,JSON.stringify(plan),new Date().toISOString(),requestHash,plan.records.length).run();
    }
  }
  const load=()=>service.env.DB.prepare('SELECT id,payload,next_index,total,request_hash,created_at FROM brain_import_jobs WHERE id=?').bind(id).first<Job>();
  let job=await load();if(!job)throw new BrainError(404,'Import job not found');
  if(requestHash!==undefined&&job.request_hash!==requestHash)throw new BrainError(409,'Import Idempotency-Key belongs to a different request; legacy jobs must resume by cursor');
  const plan=JSON.parse(job.payload) as Plan;
  if(!Array.isArray(plan.records)||plan.records.length!==job.total||job.total<1||job.total>20||!Number.isSafeInteger(job.next_index)||job.next_index<0||job.next_index>job.total)throw new BrainError(503,'Import recovery state is invalid');
  const total=job.total;
  const response=(memories:MemoryRecord[],processed:number)=>({jobId:id,memories,unresolvedReferences:plan.unresolvedReferences,complete:processed===total,cursor:processed===total?null:id,processed,total});
  if(job.next_index===total)return response([],total);
  const lease=crypto.randomUUID(),now=Date.now();
  const claim=await service.env.DB.prepare('UPDATE brain_import_jobs SET busy_token=?,busy_until=? WHERE id=? AND (busy_token IS NULL OR busy_until<=?)').bind(lease,now+LEASE_MS,id,now).run();
  if(claim.meta.changes!==1)throw new BrainError(409,'Import step is running; retry after it finishes or its ten-minute recovery lease expires');
  try{
    job=await load();if(!job)throw new BrainError(503,'Import recovery state disappeared');
    const memories:MemoryRecord[]=[],end=Math.min(total,job.next_index+2);
    for(let i=job.next_index;i<end;i++){
      const time=Date.now();const guard=await service.env.DB.prepare('UPDATE brain_import_jobs SET busy_until=? WHERE id=? AND busy_token=? AND busy_until>?').bind(time+LEASE_MS,id,lease,time).run();
      if(guard.meta.changes!==1)throw new BrainError(409,'Import recovery lease changed; refresh the job before retrying');
      const record=plan.records[i];const memory=await service.mutate(record.input,undefined,record.operationId,await sha256(JSON.stringify(['import',id,record.input])),record.deleted,true);
      const advanced=await service.env.DB.prepare('UPDATE brain_import_jobs SET next_index=? WHERE id=? AND busy_token=? AND next_index=?').bind(i+1,id,lease,i).run();
      if(advanced.meta.changes!==1)throw new BrainError(409,'Import progress changed; refresh the job before retrying');memories.push(memory);
    }
    return response(memories,end);
  }finally{
    // Isolate termination may skip finally; an expired lease remains recoverable.
    await service.env.DB.prepare('UPDATE brain_import_jobs SET busy_token=NULL,busy_until=0 WHERE id=? AND busy_token=?').bind(id,lease).run().catch(()=>{});
  }
}
