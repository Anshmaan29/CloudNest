import { BrainService } from './service';
import { VaultCursor, Checkpoint, checkpointDigest } from '../memory/drive-vault';
import { BrainError, uuid } from '../memory/record';
interface Job {id:string;state:string;cursor:string|null;scanned:number;busy_token:string|null;busy_until:number;created_at:string}
export async function reindex(service:BrainService,cursor?:unknown):Promise<{indexed:number,conflicts:string[],scanned:number,complete:boolean,cursor:string|null}> {
  const db=service.env.DB;let id:string;
  if(cursor!==undefined){if(!uuid(cursor))throw new BrainError(400,'Invalid reindex cursor');id=cursor;}
  else {
    id=crypto.randomUUID();
    try {
      const results=await db.batch([
        db.prepare("INSERT INTO brain_config(key,value) SELECT 'reindex_lock',? WHERE NOT EXISTS(SELECT 1 FROM brain_intents) AND NOT EXISTS(SELECT 1 FROM brain_config WHERE key='vault_rotation_lock')").bind(id),
        db.prepare("INSERT INTO brain_reindex_jobs(id,state,cursor,created_at) SELECT ?,'scanning',NULL,? WHERE EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?)").bind(id,new Date().toISOString(),id)
      ]);
      if(results[0].meta.changes!==1)throw new BrainError(409,'Recover incomplete writes before rebuilding');
    }catch(e){if(e instanceof BrainError)throw e;throw new BrainError(409,'A rebuild is already in progress; resume its cursor from status');}
  }
  const token=crypto.randomUUID(),now=Date.now();
  const locked=await db.prepare("UPDATE brain_reindex_jobs SET busy_token=?,busy_until=? WHERE id=? AND state='scanning' AND busy_until<? AND EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?)").bind(token,now+600000,id,now,id).run();
  if(locked.meta.changes!==1)throw new BrainError(409,'Reindex request is running; retry the same cursor later');
  try {
    const job=await db.prepare('SELECT * FROM brain_reindex_jobs WHERE id=?').bind(id).first<Job>();if(!job)throw new BrainError(404,'Reindex not found');
    await service.audit('owner_reindex_step');
    const page=await service.vault.scan(job.cursor?JSON.parse(job.cursor) as VaultCursor:null);
    if(job.scanned+page.scanned>100000)throw new BrainError(503,'Rebuild exceeds the 100000-object safety budget');
    const staging:D1PreparedStatement[]=[];
    for(const {record,driveID,contentHash}of page.records)staging.push(db.prepare('INSERT INTO brain_reindex_rows(job_id,revision,memory_id,drive_id,payload,content_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(job_id,drive_id) DO UPDATE SET conflict=CASE WHEN brain_reindex_rows.payload=excluded.payload THEN brain_reindex_rows.conflict ELSE 1 END').bind(id,record.revision,record.id,driveID,JSON.stringify(record),contentHash));
    for(const r of page.receipts){
      if(!r.authenticated){staging.push(db.prepare('INSERT OR IGNORE INTO brain_reindex_untrusted(job_id,revision,content_hash) VALUES(?,?,?)').bind(id,r.revision,r.contentHash));continue;}
      if(r.format==='cloudnest-commit-v2')staging.push(db.prepare('INSERT OR REPLACE INTO brain_reindex_checkpoint_receipts(job_id,revision,content_hash) VALUES(?,?,?)').bind(id,r.revision,r.contentHash));
      for(const digest of r.retiredReceipts??[])staging.push(db.prepare('INSERT OR IGNORE INTO brain_reindex_retired(job_id,revision,content_hash) VALUES(?,?,?)').bind(id,r.revision,digest));
      staging.push(db.prepare('INSERT INTO brain_reindex_receipts(job_id,revision,memory_id,canonical_id,content_hash,version) VALUES(?,?,?,?,?,?) ON CONFLICT(job_id,revision) DO UPDATE SET conflict=CASE WHEN brain_reindex_receipts.memory_id=excluded.memory_id AND brain_reindex_receipts.canonical_id=excluded.canonical_id AND brain_reindex_receipts.content_hash=excluded.content_hash AND brain_reindex_receipts.version=excluded.version THEN brain_reindex_receipts.conflict ELSE 1 END').bind(id,r.revision,r.memoryID,r.canonicalID,r.sha256,r.version));
    }
    for(const c of page.checkpoints)staging.push(db.prepare('INSERT OR REPLACE INTO brain_reindex_checkpoints(job_id,drive_id,content_hash,authenticated,payload) VALUES(?,?,?,?,?)').bind(id,c.driveID,c.contentHash,c.authenticated?1:0,JSON.stringify(c)));
    if(staging.length)await db.batch(staging);
    await db.prepare('UPDATE brain_reindex_jobs SET cursor=?,scanned=scanned+? WHERE id=? AND busy_token=?').bind(page.cursor?JSON.stringify(page.cursor):null,page.scanned,id,token).run();
    if(page.cursor)return{indexed:0,conflicts:[],scanned:job.scanned+page.scanned,complete:false,cursor:id};
    const roots=(await db.prepare('SELECT drive_id,content_hash,authenticated,payload FROM brain_reindex_checkpoints WHERE job_id=?').bind(id).all<{drive_id:string;content_hash:string;authenticated:number;payload:string}>()).results;
    const authenticatedRoots=roots.filter(r=>r.authenticated);
    const expectedRoot=await db.prepare("SELECT value FROM brain_config WHERE key='vault_checkpoint_id'").first<{value:string}>();
    if(expectedRoot&&!authenticatedRoots.some(r=>r.drive_id===expectedRoot.value)||new Set(authenticatedRoots.map(r=>r.content_hash)).size>1)throw new BrainError(409,'Active canonical root checkpoint is missing or conflicts');
    const retiredRoots=new Set(authenticatedRoots.flatMap(r=>(JSON.parse(r.payload) as Checkpoint).retiredCheckpoints));
    if(roots.some(r=>!r.authenticated&&!retiredRoots.has(r.content_hash)))throw new BrainError(409,'Canonical root checkpoint signature is invalid');
    const checkpointRows=(await db.prepare('SELECT revision,content_hash FROM brain_reindex_checkpoint_receipts WHERE job_id=? ORDER BY revision LIMIT 10001').bind(id).all<{revision:string;content_hash:string}>()).results;
    if(checkpointRows.length>10000)throw new BrainError(503,'Checkpoint exceeds the revision safety budget');
    if(checkpointRows.length&&!authenticatedRoots.length)throw new BrainError(409,'Signed canonical root checkpoint is missing');
    for(const root of authenticatedRoots){const c=JSON.parse(root.payload) as Checkpoint;if(c.revisionCount!==checkpointRows.length||c.receiptSetSHA256!==await checkpointDigest(checkpointRows))throw new BrainError(409,'Canonical root checkpoint history is incomplete or changed');}
    const untrusted=await db.prepare('SELECT 1 FROM brain_reindex_untrusted u WHERE u.job_id=? AND NOT EXISTS(SELECT 1 FROM brain_reindex_retired r WHERE r.job_id=u.job_id AND r.revision=u.revision AND r.content_hash=u.content_hash) LIMIT 1').bind(id).first();
    if(untrusted)throw new BrainError(409,'Canonical approval signature is invalid or lacks a replacement-key checkpoint');
    // Read only bounded chain metadata, not all memory bodies into Worker RAM.
    const rows=(await db.prepare("SELECT r.revision,r.memory_id,r.drive_id,r.content_hash,r.conflict,json_extract(r.payload,'$.parentRevision') AS parentRevision,json_extract(r.payload,'$.version') AS version,json_extract(r.payload,'$.createdAt') AS createdAt,c.canonical_id,c.content_hash AS committedHash,c.conflict AS commitConflict,c.version AS committedVersion FROM brain_reindex_rows r LEFT JOIN brain_reindex_receipts c ON c.job_id=r.job_id AND c.revision=r.revision WHERE r.job_id=? ORDER BY r.memory_id,version LIMIT 10001").bind(id).all<{revision:string,memory_id:string,drive_id:string,content_hash:string,conflict:number,parentRevision:string|null,version:number,createdAt:string,canonical_id:string|null,committedHash:string|null,commitConflict:number|null,committedVersion:number|null}>()).results;
    if(rows.length>10000)throw new BrainError(503,'Rebuild exceeds the 10000-revision index budget');
    const groups=new Map<string,typeof rows>(),conflicts=new Set<string>();
    for(const row of rows){
      if(row.conflict||row.commitConflict||!row.canonical_id||row.content_hash!==row.committedHash||row.version!==row.committedVersion){conflicts.add(row.memory_id);continue;}
      if(row.drive_id!==row.canonical_id)continue; // identical copies do not create a second canonical revision
      const values=groups.get(row.memory_id)??[];values.push(row);groups.set(row.memory_id,values);
    }
    const missing=(await db.prepare('SELECT DISTINCT c.memory_id FROM brain_reindex_receipts c LEFT JOIN brain_reindex_rows r ON r.job_id=c.job_id AND r.drive_id=c.canonical_id WHERE c.job_id=? AND (r.drive_id IS NULL OR c.conflict=1)').bind(id).all<{memory_id:string}>()).results;
    for(const row of missing)conflicts.add(row.memory_id);
    for(const [memoryID,group]of groups){let previous:typeof rows[number]|undefined;for(const record of group){if(record.version!==(previous?.version??0)+1||record.parentRevision!==(previous?.revision??null)||previous&&record.createdAt!==previous.createdAt){conflicts.add(memoryID);break;}previous=record;}}
    if(expectedRoot){
      // A rotated root is a minimum snapshot. Preserve newer trusted D1 history
      // as well: deleting a post-checkpoint private/tombstone record AND receipt
      // must never permit an older approved revision to replace its head.
      const lost=await db.prepare(`SELECT 1 FROM brain_revisions trusted LEFT JOIN brain_reindex_rows staged ON staged.job_id=? AND staged.revision=trusted.revision AND staged.drive_id=trusted.drive_id LEFT JOIN brain_reindex_receipts approved ON approved.job_id=staged.job_id AND approved.revision=staged.revision AND approved.canonical_id=staged.drive_id WHERE staged.revision IS NULL OR approved.revision IS NULL OR approved.content_hash<>staged.content_hash OR approved.conflict<>0 OR staged.conflict<>0 OR json_remove(trusted.payload,'$.body')<>json_remove(staged.payload,'$.body') OR json_extract(trusted.payload,'$.body') IS NOT json_extract(staged.payload,'$.body') LIMIT 1`).bind(id).first();
      if(lost)throw new BrainError(409,'Canonical rebuild is missing trusted post-checkpoint history');
    }
    const excluded=JSON.stringify([...conflicts]);
    const publication="EXISTS(SELECT 1 FROM brain_reindex_jobs WHERE id=? AND busy_token=? AND state='publishing')";
    // Bulk SELECTs execute inside SQLite. The maintenance lock prevents all
    // readers/writers until this atomic index switch, including deleted/private rows.
    const statements:D1PreparedStatement[]=[
      db.prepare("UPDATE brain_reindex_jobs SET state='publishing' WHERE id=? AND busy_token=? AND busy_until>? AND state='scanning' AND EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?) AND NOT EXISTS(SELECT 1 FROM brain_config WHERE key='vault_rotation_lock')").bind(id,token,Date.now(),id),
      db.prepare(`DELETE FROM memories WHERE ${publication}`).bind(id,token),db.prepare(`DELETE FROM brain_heads WHERE ${publication}`).bind(id,token),db.prepare(`DELETE FROM brain_revisions WHERE ${publication}`).bind(id,token),
      db.prepare(`INSERT INTO brain_revisions(revision,memory_id,parent_revision,version,drive_id,payload,created_at,operation_id,request_hash) SELECT r.revision,r.memory_id,json_extract(r.payload,'$.parentRevision'),json_extract(r.payload,'$.version'),r.drive_id,r.payload,json_extract(r.payload,'$.updatedAt'),json_extract(r.payload,'$.operationId'),json_extract(r.payload,'$.requestHash') FROM brain_reindex_rows r JOIN brain_reindex_receipts c ON c.job_id=r.job_id AND c.revision=r.revision AND c.canonical_id=r.drive_id WHERE r.job_id=? AND r.memory_id NOT IN(SELECT value FROM json_each(?)) AND ${publication}`).bind(id,excluded,id,token),
      db.prepare(`INSERT INTO brain_heads(memory_id,revision,project,visibility,deleted,payload,updated_at) SELECT r.memory_id,r.revision,json_extract(r.payload,'$.project'),json_extract(r.payload,'$.visibility'),json_extract(r.payload,'$.deleted'),r.payload,json_extract(r.payload,'$.updatedAt') FROM brain_revisions r WHERE r.version=(SELECT MAX(x.version) FROM brain_revisions x WHERE x.memory_id=r.memory_id) AND ${publication}`).bind(id,token),
      db.prepare(`INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at,expires_at,canonical_drive_id) SELECT h.memory_id,h.project,json_extract(h.payload,'$.title'),json_extract(h.payload,'$.body'),json_extract(h.payload,'$.source'),json_extract(h.payload,'$.version'),h.visibility,h.updated_at,json_extract(h.payload,'$.expiresAt'),r.drive_id FROM brain_heads h JOIN brain_revisions r ON r.revision=h.revision WHERE h.deleted=0 AND ${publication}`).bind(id,token),
      db.prepare(`INSERT INTO audit(client_id,action) SELECT 'owner','index_rebuilt' WHERE ${publication}`).bind(id,token),db.prepare("UPDATE brain_reindex_jobs SET state='complete' WHERE id=? AND busy_token=? AND state='publishing'").bind(id,token),db.prepare("DELETE FROM brain_config WHERE key='reindex_lock' AND value=? AND EXISTS(SELECT 1 FROM brain_reindex_jobs WHERE id=? AND busy_token=? AND state='complete')").bind(id,id,token)];
    const published=await db.batch(statements);
    if(published[0].meta.changes!==1)throw new BrainError(409,'Reindex lease or maintenance ownership changed before publication');
    const indexed=await db.prepare('SELECT count(*) AS count FROM brain_heads WHERE deleted=0').first<{count:number}>();
    return{indexed:indexed?.count??0,conflicts:[...conflicts],scanned:job.scanned+page.scanned,complete:true,cursor:null};
  }finally{await db.prepare('UPDATE brain_reindex_jobs SET busy_token=NULL,busy_until=0 WHERE id=? AND busy_token=?').bind(id,token).run();}
}
