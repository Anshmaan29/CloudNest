import { BrainService } from './service';
import { BrainError, MemoryRecord, markdown, sha256, uuid } from '../memory/record';
import { ScannedReceipt, VaultCursor, checkpointDigest } from '../memory/drive-vault';
interface Job {id:string;state:'scanning'|'signing'|'verifying'|'complete';key_sha256:string;root_id:string|null;root_hash:string|null;root_verified:number;cursor:string|null;scanned:number;busy_token:string|null;busy_until:number}
interface Row {revision:string;memory_id:string;drive_id:string;payload:string;receipt_id:string|null;receipt_hash:string|null}
export interface RotationProgress {cursor:string;state:string;complete:boolean;revisions:number;signed:number;keyFingerprint:string;checkpointID:string|null;checkpointSHA256:string|null}
const conflict=(message:string):never=>{throw new BrainError(409,message);};
const ownsLease="EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=? AND busy_token=? AND busy_until>?)";

/** Owner-only adapter must authorize before calling. The persistent maintenance
 * lock has no TTL; only a single request lease expires. Failed jobs stay frozen. */
export async function rotateVault(service:BrainService,cursor?:unknown):Promise<RotationProgress>{
  const db=service.env.DB;let id:string;
  if(cursor!==undefined){if(!uuid(cursor))throw new BrainError(400,'Invalid rotation cursor');id=cursor;}
  else{
    const fingerprint=await service.vault.keyFingerprint(true);
    if(fingerprint===await service.vault.keyFingerprint())conflict('Replacement signing key must be fresh');
    const active=await db.prepare("SELECT value FROM brain_config WHERE key='vault_active_key_sha256'").first<{value:string}>();
    if(active?.value===fingerprint)conflict('Replacement signing key is already active');
    const count=await db.prepare('SELECT count(*) AS n FROM brain_revisions').first<{n:number}>();
    if((count?.n??0)>10000)throw new BrainError(503,'Rotation exceeds the 10000-revision safety budget');
    id=crypto.randomUUID();
    try{
      const results=await db.batch([
        db.prepare("INSERT INTO brain_config(key,value) SELECT 'reindex_lock',? WHERE NOT EXISTS(SELECT 1 FROM brain_intents) AND NOT EXISTS(SELECT 1 FROM brain_import_jobs WHERE next_index<total)").bind(id),
        db.prepare("INSERT INTO brain_config(key,value) SELECT 'vault_rotation_lock',? WHERE EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?)").bind(id,id),
        db.prepare("INSERT INTO brain_vault_rotations(id,state,key_sha256,created_at) SELECT ?,'scanning',?,? WHERE EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?)").bind(id,fingerprint,new Date().toISOString(),id),
        db.prepare("INSERT INTO brain_vault_rotation_rows(job_id,revision,memory_id,drive_id,payload) SELECT ?,revision,memory_id,drive_id,payload FROM brain_revisions WHERE EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=?)").bind(id,id),
        db.prepare("INSERT INTO brain_vault_rotation_heads(job_id,memory_id,revision,payload) SELECT ?,memory_id,revision,payload FROM brain_heads WHERE EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=?)").bind(id,id),
        db.prepare("INSERT INTO audit(client_id,action) SELECT 'owner','vault_rotation_snapshot_frozen' WHERE EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=?)").bind(id)
      ]);
      if(results[0].meta.changes!==1)conflict('Recover pending writes and imports before rotating the vault');
    }catch(error){if(error instanceof BrainError)throw error;conflict('Canonical maintenance or another rotation is active');}
  }
  let job=await db.prepare('SELECT * FROM brain_vault_rotations WHERE id=?').bind(id).first<Job>();
  if(!job)throw new BrainError(404,'Vault rotation not found');
  if(job.state==='complete')return rotationProgress(service,id);
  if(job.key_sha256!==await service.vault.keyFingerprint(true))conflict('Replacement signing key changed; restore the staged key to resume');
  const token=crypto.randomUUID(),now=Date.now();
  const locked=await db.prepare("UPDATE brain_vault_rotations SET busy_token=?,busy_until=? WHERE id=? AND state<>'complete' AND busy_until<? AND EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?)").bind(token,now+600000,id,now,id).run();
  if(locked.meta.changes!==1)conflict('Rotation request is running or its maintenance lock is missing; retry the cursor');
  try{
    job=(await db.prepare('SELECT * FROM brain_vault_rotations WHERE id=? AND busy_token=?').bind(id,token).first<Job>())!;
    await assertSnapshot(service,id);
    await service.audit('owner_vault_rotation_step');
    if(job.state==='signing'){
      const rows=(await db.prepare('SELECT * FROM brain_vault_rotation_rows WHERE job_id=? AND receipt_hash IS NULL ORDER BY revision LIMIT 5').bind(id).all<Row>()).results;
      for(const row of rows){
        if(!row.receipt_id){const proposed=await service.vault.allocateID();await db.prepare(`UPDATE brain_vault_rotation_rows SET receipt_id=? WHERE job_id=? AND revision=? AND receipt_id IS NULL AND ${ownsLease}`).bind(proposed,id,row.revision,id,token,Date.now()).run();row.receipt_id=(await db.prepare('SELECT receipt_id FROM brain_vault_rotation_rows WHERE job_id=? AND revision=?').bind(id,row.revision).first<{receipt_id:string}>())!.receipt_id;}
        const retired=(await db.prepare('SELECT content_hash FROM brain_vault_rotation_receipts WHERE job_id=? AND revision=? ORDER BY content_hash LIMIT 33').bind(id,row.revision).all<{content_hash:string}>()).results.map(r=>r.content_hash);
        if(!retired.length||retired.length>32)conflict('Historical receipts exceed checkpoint safety limits');
        const digest=await service.vault.putRotatedCommit(JSON.parse(row.payload),row.drive_id,row.receipt_id!,retired);
        const saved=await db.prepare(`UPDATE brain_vault_rotation_rows SET receipt_hash=? WHERE job_id=? AND revision=? AND ${ownsLease}`).bind(digest,id,row.revision,id,token,Date.now()).run();
        if(saved.meta.changes!==1)conflict('Rotation lease changed during checkpoint upload; resume the cursor');
      }
      const remaining=await db.prepare('SELECT 1 FROM brain_vault_rotation_rows WHERE job_id=? AND receipt_hash IS NULL LIMIT 1').bind(id).first();
      if(!remaining){
        if(!job.root_id){const proposed=await service.vault.allocateID();await db.prepare('UPDATE brain_vault_rotations SET root_id=? WHERE id=? AND root_id IS NULL AND busy_token=?').bind(proposed,id,token).run();job=(await db.prepare('SELECT * FROM brain_vault_rotations WHERE id=?').bind(id).first<Job>())!;}
        const receipts=(await db.prepare('SELECT revision,receipt_hash AS content_hash FROM brain_vault_rotation_rows WHERE job_id=? ORDER BY revision LIMIT 10001').bind(id).all<{revision:string;content_hash:string}>()).results;
        const roots=(await db.prepare('SELECT content_hash FROM brain_vault_rotation_roots WHERE job_id=? ORDER BY content_hash LIMIT 33').bind(id).all<{content_hash:string}>()).results.map(r=>r.content_hash);
        if(receipts.length>10000||roots.length>32)throw new BrainError(503,'Root checkpoint exceeds the safety budget');
        const digest=await service.vault.putCheckpoint(job.root_id!,receipts.length,await checkpointDigest(receipts),roots);
        await db.prepare("UPDATE brain_vault_rotations SET root_hash=?,state='verifying',cursor=NULL,scanned=0 WHERE id=? AND busy_token=?").bind(digest,id,token).run();
      }
    }else{
      const verifying=job.state==='verifying';
      const page=await service.vault.scan(job.cursor?JSON.parse(job.cursor) as VaultCursor:null);
      if(job.scanned+page.scanned>100000)throw new BrainError(503,'Rotation exceeds the 100000-object scan budget');
      for(const item of page.records){
        const row=await db.prepare('SELECT * FROM brain_vault_rotation_rows WHERE job_id=? AND revision=?').bind(id,item.record.revision).first<Row>();
        if(!row||row.drive_id!==item.driveID||row.memory_id!==item.record.id||await sha256(markdown(JSON.parse(row.payload)))!==item.contentHash)conflict('Canonical revision differs from the frozen trusted snapshot');
        await db.prepare(`UPDATE brain_vault_rotation_rows SET ${verifying?'verified_record':'seen_record'}=1 WHERE job_id=? AND revision=? AND ${ownsLease}`).bind(id,row!.revision,id,token,Date.now()).run();
      }
      for(const receipt of page.receipts)await inspectReceipt(service,id,receipt,verifying,token);
      for(const root of page.checkpoints){
        if(verifying&&root.driveID===job.root_id){
          if(root.contentHash!==job.root_hash||!await service.vault.verifyNextCheckpoint(root))conflict('Replacement-key root checkpoint could not be verified');
          await db.prepare('UPDATE brain_vault_rotations SET root_verified=1 WHERE id=? AND busy_token=?').bind(id,token).run();
        }else if(verifying){
          const known=await db.prepare(`UPDATE brain_vault_rotation_roots SET verified=1 WHERE job_id=? AND drive_id=? AND content_hash=? AND ${ownsLease}`).bind(id,root.driveID,root.contentHash,id,token,Date.now()).run();
          if(known.meta.changes!==1)conflict('Historical root checkpoint drifted during rotation');
        }else{
          const old=await db.prepare('SELECT content_hash FROM brain_vault_rotation_roots WHERE job_id=? AND drive_id=?').bind(id,root.driveID).first<{content_hash:string}>();
          if(old&&old.content_hash!==root.contentHash)conflict('Historical root checkpoint drifted during rotation');
          await db.prepare(`INSERT OR IGNORE INTO brain_vault_rotation_roots(job_id,drive_id,content_hash) SELECT ?,?,? WHERE ${ownsLease}`).bind(id,root.driveID,root.contentHash,id,token,Date.now()).run();
        }
      }
      await db.prepare('UPDATE brain_vault_rotations SET cursor=?,scanned=scanned+? WHERE id=? AND busy_token=?').bind(page.cursor?JSON.stringify(page.cursor):null,page.scanned,id,token).run();
      if(!page.cursor){
        const missing=verifying?
          await db.prepare('SELECT 1 FROM brain_vault_rotation_rows WHERE job_id=? AND (verified_record=0 OR verified_receipt=0) UNION ALL SELECT 1 FROM brain_vault_rotation_receipts WHERE job_id=? AND verified=0 UNION ALL SELECT 1 FROM brain_vault_rotation_roots WHERE job_id=? AND verified=0 UNION ALL SELECT 1 FROM brain_vault_rotations WHERE id=? AND root_verified=0 LIMIT 1').bind(id,id,id,id).first():
          await db.prepare("SELECT 1 FROM brain_vault_rotation_rows r WHERE r.job_id=? AND (r.seen_record=0 OR NOT EXISTS(SELECT 1 FROM brain_vault_rotation_receipts c WHERE c.job_id=r.job_id AND c.revision=r.revision)) UNION ALL SELECT 1 FROM brain_config c WHERE c.key='vault_checkpoint_id' AND NOT EXISTS(SELECT 1 FROM brain_vault_rotation_roots r WHERE r.job_id=? AND r.drive_id=c.value) LIMIT 1").bind(id,id).first();
        if(missing)conflict('Canonical history or commit receipts are missing; rotation remains frozen');
        if(verifying){
          await assertSnapshot(service,id);
          // All fresh-key checkpoints were downloaded and cryptographically
          // verified. Activation and maintenance release are one transaction.
          const activated=await db.batch([
            db.prepare(`UPDATE brain_vault_rotations SET state='complete',cursor=NULL WHERE id=? AND busy_token=? AND busy_until>? AND state='verifying' AND root_verified=1 AND EXISTS(SELECT 1 FROM brain_config WHERE key='reindex_lock' AND value=?) AND EXISTS(SELECT 1 FROM brain_config WHERE key='vault_rotation_lock' AND value=?) AND NOT EXISTS(${snapshotDriftSQL})`).bind(id,token,Date.now(),id,id,id,id,id,id),
            db.prepare("INSERT INTO brain_config(key,value) SELECT 'vault_active_key_sha256',key_sha256 FROM brain_vault_rotations WHERE id=? AND busy_token=? AND state='complete' ON CONFLICT(key) DO UPDATE SET value=excluded.value").bind(id,token),
            db.prepare("INSERT INTO brain_config(key,value) SELECT 'vault_checkpoint_id',root_id FROM brain_vault_rotations WHERE id=? AND busy_token=? AND state='complete' ON CONFLICT(key) DO UPDATE SET value=excluded.value").bind(id,token),
            db.prepare("INSERT INTO audit(client_id,action) SELECT 'owner','vault_rotation_verified_activated' WHERE EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=? AND busy_token=? AND state='complete')").bind(id,token),
            db.prepare("DELETE FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock') AND value=? AND EXISTS(SELECT 1 FROM brain_vault_rotations WHERE id=? AND busy_token=? AND state='complete')").bind(id,id,token)
          ]);
          if(activated[0].meta.changes!==1)conflict('Rotation lease or trusted snapshot changed before activation; rotation remains frozen');
        }else await db.prepare("UPDATE brain_vault_rotations SET state='signing',cursor=NULL WHERE id=? AND busy_token=?").bind(id,token).run();
      }
    }
    return rotationProgress(service,id);
  }finally{await db.prepare('UPDATE brain_vault_rotations SET busy_token=NULL,busy_until=0 WHERE id=? AND busy_token=?').bind(id,token).run();}
}
async function inspectReceipt(service:BrainService,id:string,receipt:ScannedReceipt,verifying:boolean,token:string):Promise<void>{
  const db=service.env.DB,row=await db.prepare('SELECT * FROM brain_vault_rotation_rows WHERE job_id=? AND revision=?').bind(id,receipt.revision).first<Row>();
  if(!row)conflict('Canonical receipt is absent from the frozen trusted history');
  const record=JSON.parse(row!.payload) as MemoryRecord;
  if(receipt.memoryID!==row!.memory_id||receipt.canonicalID!==row!.drive_id||receipt.version!==record.version||receipt.sha256!==await sha256(markdown(record)))conflict('Canonical receipt differs from the frozen trusted snapshot');
  if(verifying&&receipt.driveID===row!.receipt_id){
    if(receipt.contentHash!==row!.receipt_hash||receipt.format!=='cloudnest-commit-v2'||!await service.vault.verifyNextReceipt(receipt))conflict('Replacement-key checkpoint could not be verified');
    await db.prepare(`UPDATE brain_vault_rotation_rows SET verified_receipt=1 WHERE job_id=? AND revision=? AND ${ownsLease}`).bind(id,row!.revision,id,token,Date.now()).run();return;
  }
  if(verifying){
    const known=await db.prepare(`UPDATE brain_vault_rotation_receipts SET verified=1 WHERE job_id=? AND revision=? AND drive_id=? AND content_hash=? AND ${ownsLease}`).bind(id,receipt.revision,receipt.driveID,receipt.contentHash,id,token,Date.now()).run();
    if(known.meta.changes!==1)conflict('Historical receipt drifted during rotation');
  }else{
    const old=await db.prepare('SELECT content_hash FROM brain_vault_rotation_receipts WHERE job_id=? AND drive_id=?').bind(id,receipt.driveID).first<{content_hash:string}>();
    if(old&&old.content_hash!==receipt.contentHash)conflict('Historical receipt drifted during rotation');
    await db.prepare(`INSERT OR IGNORE INTO brain_vault_rotation_receipts(job_id,revision,drive_id,content_hash) SELECT ?,?,?,? WHERE ${ownsLease}`).bind(id,receipt.revision,receipt.driveID,receipt.contentHash,id,token,Date.now()).run();
  }
}
// Reused inside the activation transaction to close the final D1 drift race.
const snapshotDriftSQL=`SELECT 1 WHERE EXISTS(SELECT 1 FROM brain_intents)
    OR (SELECT count(*) FROM brain_revisions)<>(SELECT count(*) FROM brain_vault_rotation_rows WHERE job_id=?)
    OR EXISTS(SELECT 1 FROM brain_revisions r LEFT JOIN brain_vault_rotation_rows s ON s.job_id=? AND s.revision=r.revision WHERE s.revision IS NULL OR s.drive_id<>r.drive_id OR s.memory_id<>r.memory_id OR s.payload<>r.payload OR r.revision<>json_extract(r.payload,'$.revision') OR r.memory_id<>json_extract(r.payload,'$.id') OR r.version<>json_extract(r.payload,'$.version') OR r.parent_revision IS NOT json_extract(r.payload,'$.parentRevision') OR r.operation_id IS NOT json_extract(r.payload,'$.operationId') OR r.request_hash IS NOT json_extract(r.payload,'$.requestHash') OR r.created_at IS NOT json_extract(r.payload,'$.updatedAt'))
    OR (SELECT count(*) FROM brain_heads)<>(SELECT count(*) FROM brain_vault_rotation_heads WHERE job_id=?)
    OR EXISTS(SELECT 1 FROM brain_heads h LEFT JOIN brain_vault_rotation_heads s ON s.job_id=? AND s.memory_id=h.memory_id WHERE s.memory_id IS NULL OR s.revision<>h.revision OR s.payload<>h.payload OR h.project IS NOT json_extract(h.payload,'$.project') OR h.visibility IS NOT json_extract(h.payload,'$.visibility') OR h.deleted IS NOT json_extract(h.payload,'$.deleted') OR h.updated_at IS NOT json_extract(h.payload,'$.updatedAt'))
    OR EXISTS(SELECT 1 FROM brain_revisions r WHERE (r.version=1 AND r.parent_revision IS NOT NULL) OR (r.version>1 AND NOT EXISTS(SELECT 1 FROM brain_revisions p WHERE p.memory_id=r.memory_id AND p.revision=r.parent_revision AND p.version=r.version-1 AND json_extract(p.payload,'$.createdAt')=json_extract(r.payload,'$.createdAt'))))
    OR EXISTS(SELECT 1 FROM brain_revisions GROUP BY memory_id,version HAVING count(*)<>1)
    OR EXISTS(SELECT 1 FROM brain_revisions r WHERE NOT EXISTS(SELECT 1 FROM brain_heads h WHERE h.memory_id=r.memory_id))
    OR EXISTS(SELECT 1 FROM brain_heads h WHERE NOT EXISTS(SELECT 1 FROM brain_revisions r WHERE r.memory_id=h.memory_id AND r.revision=h.revision AND r.payload=h.payload AND r.version=(SELECT max(p.version) FROM brain_revisions p WHERE p.memory_id=h.memory_id)))`;
async function assertSnapshot(service:BrainService,id:string):Promise<void>{
  const db=service.env.DB;
  // Compare all history and heads, not merely the newest approved/non-deleted row.
  const drift=await db.prepare(snapshotDriftSQL).bind(id,id,id,id).first();
  if(drift)conflict('Trusted history snapshot drifted or has an incomplete chain; rotation remains frozen');
}
export async function rotationProgress(service:BrainService,id?:string):Promise<RotationProgress>{
  const db=service.env.DB;
  const job=id?await db.prepare('SELECT * FROM brain_vault_rotations WHERE id=?').bind(id).first<Job>():await db.prepare('SELECT * FROM brain_vault_rotations ORDER BY created_at DESC LIMIT 1').first<Job>();
  if(!job)throw new BrainError(404,'Vault rotation not found');
  const counts=await db.prepare('SELECT count(*) AS revisions,count(receipt_hash) AS signed FROM brain_vault_rotation_rows WHERE job_id=?').bind(job.id).first<{revisions:number;signed:number}>();
  return{cursor:job.id,state:job.state,complete:job.state==='complete',revisions:counts!.revisions,signed:counts!.signed,keyFingerprint:job.key_sha256,checkpointID:job.root_id,checkpointSHA256:job.root_hash};
}
