import type {BrainService} from './service';
import {BrainError,object,text,uuid} from '../memory/record';
import {conversationHash,parseConversationExport,type ConversationProvider} from '../../shared/schemas/conversation';
const client=(id:string)=>'conversation-import:'+id;
function projectName(value:unknown):string {const p=text(value,'project',128);if(!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(p))throw new BrainError(400,'Invalid project');return p;}
const identity=(digest:string)=>digest.slice(0,8)+'-'+digest.slice(8,12)+'-4'+digest.slice(13,16)+'-a'+digest.slice(17,20)+'-'+digest.slice(20,32);
export async function previewConversationImport(input:Record<string,unknown>):Promise<unknown>{
 if(Object.keys(input).some(k=>!['provider','source'].includes(k)))throw new BrainError(400,'Invalid preview fields');
 try{return await parseConversationExport(input.provider as ConversationProvider,text(input.source,'selected export',512*1024));}catch(error){throw new BrainError(400,error instanceof Error?error.message:'Unsupported export');}
}
/** Owner-only duplicate preview sends hashes, never the unselected history. */
export async function checkConversationDuplicates(service:BrainService,input:Record<string,unknown>):Promise<unknown>{
 await service.ensureReadable();
 if(Object.keys(input).some(k=>!['project','fingerprints'].includes(k))||!Array.isArray(input.fingerprints)||input.fingerprints.length>20||input.fingerprints.some(v=>typeof v!=='string'||!/^[a-f0-9]{64}$/.test(v)))throw new BrainError(400,'Check up to 20 source fingerprints');
 const project=projectName(input.project),pairs=await Promise.all((input.fingerprints as string[]).map(async fingerprint=>({fingerprint,key:await conversationHash(JSON.stringify([project,fingerprint]))})));
 await service.audit('owner_conversation_duplicate_check');
 if(!pairs.length)return {duplicates:[]};
 const rows=(await service.env.DB.prepare('SELECT s.fingerprint,s.proposal_id AS proposalId,s.batch_id AS batchId,p.status FROM brain_conversation_sources s JOIN brain_inbox p ON p.id=s.proposal_id WHERE s.fingerprint IN('+pairs.map(()=>'?').join(',')+')').bind(...pairs.map(p=>p.key)).all<{fingerprint:string;proposalId:string;batchId:string;status:string}>()).results;
 return {duplicates:rows.map(row=>({...row,fingerprint:pairs.find(p=>p.key===row.fingerprint)!.fingerprint}))};
}
export async function commitConversationImport(service:BrainService,input:Record<string,unknown>):Promise<unknown>{
 await service.ensureReadable();
 if(Object.keys(input).some(k=>!['batchId','provider','project','suggestions'].includes(k))||!uuid(input.batchId)||!['chatgpt','claude','gemini'].includes(String(input.provider))||!Array.isArray(input.suggestions)||input.suggestions.length<1||input.suggestions.length>20)throw new BrainError(400,'Select 1–20 edited suggestions and a UUID batchId');
 const batchID=input.batchId,provider=String(input.provider),project=projectName(input.project),now=new Date().toISOString();
 const seen=new Set<string>();
 const selections=await Promise.all(input.suggestions.map(async value=>{
  const s=object(value);if(Object.keys(s).some(k=>!['conversationID','conversationTitle','messageID','role','timestamp','quote','title','body','inferred','fingerprint'].includes(k)))throw new BrainError(400,'Invalid suggestion fields');
  const conversationID=text(s.conversationID,'conversation ID',256),conversationTitle=text(s.conversationTitle,'conversation title',500,true),messageID=text(s.messageID,'message ID',256),quote=text(s.quote,'source quote',4000),title=text(s.title,'title',200),edited=text(s.body,'edited suggestion',4000);
  if(!['user','assistant'].includes(String(s.role))||s.inferred!==true||(s.timestamp!==null&&(typeof s.timestamp!=='string'||!Number.isFinite(Date.parse(s.timestamp))||new Date(s.timestamp).toISOString()!==s.timestamp)))throw new BrainError(400,'Invalid source provenance');
  const quoteHash=await conversationHash(JSON.stringify([provider,s.role,quote.normalize('NFC').replace(/\s+/g,' ').trim()]));
  if(s.fingerprint!==quoteHash)throw new BrainError(400,'Source quote changed; preview the selection again');
  const fingerprint=await conversationHash(JSON.stringify([project,quoteHash]));if(seen.has(fingerprint))throw new BrainError(400,'Duplicate selected excerpts');seen.add(fingerprint);
  const provenance={provider,conversationID,conversationTitle,messageID,role:s.role,timestamp:s.timestamp,quote,quoteHash,inferred:true};
  const body=`Untrusted imported conversation suggestion — review before approving.\n\n${edited}\n\nSource excerpt (${s.role}; ${s.timestamp??'date unavailable'}):\n${quote}`;
  const source=`${provider} export; conversation ${conversationID}; message ${messageID}; SHA-256 ${quoteHash}`;
  return {fingerprint,provenance,title,body,source,id:identity(await conversationHash(JSON.stringify([batchID,fingerprint])))};
 }));
 const requestHash=await conversationHash(JSON.stringify({provider,project,selections}));
 const existing=await service.env.DB.prepare('SELECT request_hash,rolled_back_at FROM brain_conversation_imports WHERE id=?').bind(batchID).first<{request_hash:string;rolled_back_at:string|null}>();
 if(existing&&existing.request_hash!==requestHash)throw new BrainError(409,'Batch ID belongs to different selections');
 if(!existing){
  const statements=[service.env.DB.prepare("INSERT OR IGNORE INTO brain_conversation_imports(id,request_hash,provider,project,created_at) SELECT ?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM brain_config WHERE key IN('reindex_lock','vault_rotation_lock'))").bind(batchID,requestHash,provider,project,now)];
  for(const s of selections){
   const guard="EXISTS(SELECT 1 FROM brain_conversation_imports WHERE id=? AND request_hash=? AND rolled_back_at IS NULL) AND NOT EXISTS(SELECT 1 FROM brain_conversation_sources WHERE fingerprint=?)";
   statements.push(service.env.DB.prepare(`INSERT OR IGNORE INTO brain_inbox(id,client_id,project,title,body,source,category,created_at,status) SELECT ?,?,?,?,?,?,'imported-conversation',?,'pending' WHERE ${guard}`).bind(s.id,client(batchID),project,s.title,s.body,s.source,now,batchID,requestHash,s.fingerprint));
   statements.push(service.env.DB.prepare('INSERT OR IGNORE INTO brain_conversation_sources(fingerprint,batch_id,proposal_id,provenance) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM brain_inbox WHERE id=? AND client_id=?)').bind(s.fingerprint,batchID,s.id,JSON.stringify(s.provenance),s.id,client(batchID)));
  }
  statements.push(service.env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) VALUES('owner','conversation_import_reviewed',?)").bind(batchID));await service.env.DB.batch(statements);
 }
 const saved=await service.env.DB.prepare('SELECT request_hash,rolled_back_at FROM brain_conversation_imports WHERE id=?').bind(batchID).first<{request_hash:string;rolled_back_at:string|null}>();
 if(!saved)throw new BrainError(503,'Import paused by vault maintenance');if(saved.request_hash!==requestHash)throw new BrainError(409,'Batch ID belongs to different selections');
 await service.audit('owner_conversation_import_status',batchID);
 const rows=(await service.env.DB.prepare('SELECT s.fingerprint,s.proposal_id AS proposalId,s.batch_id AS batchId,p.status FROM brain_conversation_sources s JOIN brain_inbox p ON p.id=s.proposal_id WHERE s.fingerprint IN('+selections.map(()=>'?').join(',')+')').bind(...selections.map(s=>s.fingerprint)).all<{fingerprint:string;proposalId:string;batchId:string;status:string}>()).results;
 return {batchId:batchID,rolledBack:saved.rolled_back_at!==null,proposals:rows.filter(r=>r.batchId===batchID),duplicates:rows.filter(r=>r.batchId!==batchID),total:selections.length};
}
export async function listConversationImports(service:BrainService):Promise<unknown>{await service.audit('owner_conversation_imports');return {imports:(await service.env.DB.prepare('SELECT b.id,b.provider,b.project,b.created_at AS createdAt,b.rolled_back_at AS rolledBackAt,count(s.proposal_id) AS proposals FROM brain_conversation_imports b LEFT JOIN brain_conversation_sources s ON s.batch_id=b.id GROUP BY b.id ORDER BY b.created_at DESC,b.id DESC LIMIT 50').all()).results};}
export async function rollbackConversationImport(service:BrainService,id:unknown):Promise<unknown>{
 if(!uuid(id))throw new BrainError(400,'Invalid import batch ID');await service.ensureReadable();
 if(!await service.env.DB.prepare('SELECT id FROM brain_conversation_imports WHERE id=?').bind(id).first())throw new BrainError(404,'Conversation import not found');
 const result=await service.env.DB.batch([
  service.env.DB.prepare("UPDATE brain_inbox SET status='rejected' WHERE status='pending' AND client_id=? AND id IN(SELECT proposal_id FROM brain_conversation_sources WHERE batch_id=?)").bind(client(id),id),
  service.env.DB.prepare('UPDATE brain_conversation_imports SET rolled_back_at=coalesce(rolled_back_at,?) WHERE id=?').bind(new Date().toISOString(),id),
  service.env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) VALUES('owner','conversation_import_rolled_back',?)").bind(id),
 ]);
 const retained=(await service.env.DB.prepare("SELECT count(*) AS n FROM brain_inbox WHERE client_id=? AND status IN('approved','approving')").bind(client(id)).first<{n:number}>())?.n??0;
 return {batchId:id,rejected:result[0].meta.changes,retainedApprovedOrApproving:retained};
}
