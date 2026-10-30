import { BrainService } from './service';
import { BrainError,MemoryRecord,makeRecord,object,sha256,uuid } from '../memory/record';
interface Plan {records:{input:Record<string,unknown>,operationId:string,deleted:boolean}[];unresolvedReferences:{memoryId:string,target:string}[]}
export async function importMemories(service:BrainService,input:Record<string,unknown>):Promise<unknown>{
  await service.audit('owner_import_step');
  let id:string,plan:Plan,next:number;
  if(input.cursor!==undefined){
    if(Object.keys(input).length!==1||!uuid(input.cursor))throw new BrainError(400,'Invalid import cursor');id=input.cursor;
    const job=await service.env.DB.prepare('SELECT payload,next_index FROM brain_import_jobs WHERE id=?').bind(id).first<{payload:string,next_index:number}>();if(!job)throw new BrainError(404,'Import job not found');plan=JSON.parse(job.payload);next=job.next_index;
  }else{
    if(Object.keys(input).some(k=>k!=='memories')||!Array.isArray(input.memories)||input.memories.length<1||input.memories.length>20)throw new BrainError(400,'Import 1–20 records per portable batch');
    const mapping=new Map<string,string>(),raw=input.memories.map(object);for(const r of raw)if(r.id!==undefined){if(!uuid(r.id)||mapping.has(r.id))throw new BrainError(400,'Imported IDs must be unique UUIDs');mapping.set(r.id,crypto.randomUUID());}
    const unresolvedReferences:{memoryId:string,target:string}[]=[];
    const records=raw.map(r=>{
      const memoryID=typeof r.id==='string'?mapping.get(r.id)!:crypto.randomUUID();const relationships=r.relationships??[];if(!Array.isArray(relationships))throw new BrainError(400,'Invalid imported relationships');
      const relations=relationships.map(value=>{const rel=object(value);if(typeof rel.target!=='string')throw new BrainError(400,'Invalid imported relationship');const target=mapping.get(rel.target);if(!target)unresolvedReferences.push({memoryId:memoryID,target:rel.target});return{...rel,target:target??rel.target};});
      const cleaned={id:memoryID,project:r.project,title:r.title,body:r.body,source:r.source,category:r.category??'knowledge',visibility:'private',expiresAt:r.expiresAt??null,relationships:relations,confidence:'imported'};
      if(r.deleted!==undefined&&typeof r.deleted!=='boolean')throw new BrainError(400,'Invalid imported deletion state');const deleted=r.deleted===true;makeRecord(cleaned,null,deleted,true);return{input:cleaned,operationId:crypto.randomUUID(),deleted};
    });
    id=crypto.randomUUID();plan={records,unresolvedReferences};next=0;
    await service.env.DB.prepare('INSERT INTO brain_import_jobs(id,payload,created_at) VALUES(?,?,?)').bind(id,JSON.stringify(plan),new Date().toISOString()).run();
  }
  const memories:MemoryRecord[]=[];const end=Math.min(plan.records.length,next+2);
  for(let i=next;i<end;i++){const r=plan.records[i];memories.push(await service.mutate(r.input,undefined,r.operationId,await sha256(JSON.stringify(['import',id,r.input])),r.deleted,true));}
  // Idempotent record operation IDs make concurrent/retried cursor requests safe.
  await service.env.DB.prepare('UPDATE brain_import_jobs SET next_index=MAX(next_index,?) WHERE id=?').bind(end,id).run();
  return{memories,unresolvedReferences:plan.unresolvedReferences,complete:end===plan.records.length,cursor:end===plan.records.length?null:id,processed:end,total:plan.records.length};
}
