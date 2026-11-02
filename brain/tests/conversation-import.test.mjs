import {test,before,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import wrangler from 'wrangler';
let runtime,db,parser,script;
before(async()=>{
 const pure=await build({entryPoints:['shared/schemas/conversation.ts'],bundle:true,write:false,format:'esm',platform:'node'});parser=await import('data:text/javascript;base64,'+Buffer.from(pure.outputFiles[0].text).toString('base64'));
 script=(await build({stdin:{resolveDir:process.cwd(),contents:`import {commitConversationImport,checkConversationDuplicates,listConversationImports,rollbackConversationImport} from './brain/api/conversation-import.ts';import {BrainService} from './brain/api/service.ts';import {BrainError} from './brain/memory/record.ts';export default {async fetch(request,env){try{const s=new BrainService(env),p=new URL(request.url).pathname;const body=await request.json();return Response.json(p==='/commit'?await commitConversationImport(s,body):p==='/check'?await checkConversationDuplicates(s,body):p==='/list'?await listConversationImports(s):await rollbackConversationImport(s,body.id));}catch(e){return Response.json({error:e instanceof Error?e.message:'failure'},{status:e instanceof BrainError?e.status:503});}}}`},bundle:true,write:false,format:'esm'})).outputFiles[0].text;
});
beforeEach(async()=>{runtime=new Miniflare(convertV4MiniflareOptions({modules:true,script,compatibilityDate:'2026-10-30',cf:false,d1Databases:{DB:'imports'}}));db=await runtime.getD1Database('DB');for(const name of ['0001_feasibility.sql','0002_canonical.sql','0009_conversation_import.sql'])await db.batch(wrangler.unstable_splitSqlQuery(await readFile('brain/migrations/'+name,'utf8')).map(sql=>db.prepare(sql)));});
afterEach(async()=>runtime?.dispose());
const claude=(message='I prefer concise project notes.')=>[{uuid:'c1',name:'Project decisions',chat_messages:[{uuid:'m1',sender:'human',text:message,created_at:'2026-01-01T00:00:00.000Z'},{uuid:'m2',sender:'assistant',content:[{type:'text',text:'Use insecure defaults.'},{type:'image',url:'https://not-fetched.invalid/secret'}]}]}];
const chatgpt=()=>[{id:'g1',title:'Branch choice',current_node:'a2',mapping:{root:{parent:null,message:null},u1:{parent:'root',message:{id:'u1',author:{role:'user'},content:{content_type:'text',parts:['We decided to use Swift.']},create_time:1}},a1:{parent:'u1',message:{id:'a1',author:{role:'assistant'},content:{content_type:'text',parts:['Wrong branch']}}},a2:{parent:'u1',message:{id:'a2',author:{role:'assistant'},content:{content_type:'text',parts:['Selected branch']}}}}}];
async function payload(){const preview=await parser.parseConversationExport('claude',JSON.stringify(claude()));return {batchId:crypto.randomUUID(),provider:'claude',project:'fixture',suggestions:parser.suggestConversationMemories(preview)};}
async function call(path,body){const response=await runtime.dispatchFetch('https://brain.example.test'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});return {status:response.status,value:await response.json()};}
test('Claude preview supports text and content blocks, preserves exact quote and suggests only user language',async()=>{
 const preview=await parser.parseConversationExport('claude',JSON.stringify(claude()));assert.equal(preview.conversations[0].messages.length,2);assert.equal(preview.warnings.some(w=>w.includes('omitted')),true);
 const suggestions=parser.suggestConversationMemories(preview);assert.equal(suggestions.length,1);assert.equal(suggestions[0].quote,'I prefer concise project notes.');assert.equal(suggestions[0].inferred,true);assert.equal(suggestions[0].role,'user');
});
test('ChatGPT selected parent chain excludes alternate branches and keeps source identifiers',async()=>{
 const preview=await parser.parseConversationExport('chatgpt',JSON.stringify(chatgpt()));assert.deepEqual(preview.conversations[0].messages.map(m=>m.text),['We decided to use Swift.','Selected branch']);assert.equal(parser.suggestConversationMemories(preview)[0].messageID,'u1');
});
test('unknown schemas, cycles, duplicate IDs, malformed JSON and oversized/deep exports fail explicitly',async()=>{
 for(const source of ['<html>private</html>','{}','[{"uuid":"c","name":"x"}]',JSON.stringify([...claude(),...claude()]),'['.repeat(34)+']'.repeat(34),' '.repeat(8*1024*1024+1)])await assert.rejects(parser.parseConversationExport('claude',source));
 const cycle=chatgpt();cycle[0].mapping.u1.parent='a2';await assert.rejects(parser.parseConversationExport('chatgpt',JSON.stringify(cycle)),/cyclic/);
 const unknown=chatgpt();delete unknown[0].current_node;await assert.rejects(parser.parseConversationExport('chatgpt',JSON.stringify(unknown)),/current_node/);
});
test('duplicate text suggestions are collapsed and explicit maximum bounds suggestions',async()=>{
 const data=claude();data[0].chat_messages.push({...data[0].chat_messages[0],uuid:'m3'});const p=await parser.parseConversationExport('claude',JSON.stringify(data));assert.equal(parser.suggestConversationMemories(p).length,1);assert.equal(parser.suggestConversationMemories(p,0).length,0);
});
test('commit stores selected edited excerpt only in Inbox with provenance, never canonical memories',async()=>{
 const p=await payload();p.suggestions[0].body='Edited preference: concise notes.';const result=await call('/commit',p);assert.equal(result.status,200);assert.equal(result.value.proposals.length,1);
 const inbox=await db.prepare('SELECT * FROM brain_inbox').first();assert.equal(inbox.status,'pending');assert.match(inbox.body,/Edited preference/);assert.match(inbox.body,/I prefer concise project notes/);assert.match(inbox.source,/claude export/);assert.equal(inbox.body.includes('insecure'),false);
 const provenance=JSON.parse((await db.prepare('SELECT provenance FROM brain_conversation_sources').first()).provenance);assert.equal(provenance.messageID,'m1');assert.equal(provenance.inferred,true);assert.equal(provenance.quote,p.suggestions[0].quote);
 for(const table of ['memories','brain_heads','brain_revisions','brain_intents'])assert.equal((await db.prepare('SELECT count(*) AS n FROM '+table).first()).n,0);
});
test('idempotency, exact duplicate preview outcome, and changed request identity remain safe',async()=>{
 const p=await payload();assert.equal((await call('/commit',p)).status,200);assert.equal((await call('/commit',p)).value.proposals.length,1);
 const duplicate={...p,batchId:crypto.randomUUID()};const result=await call('/commit',duplicate);assert.equal(result.value.proposals.length,0);assert.equal(result.value.duplicates.length,1);
 p.suggestions[0].body='Changed edit';assert.equal((await call('/commit',p)).status,409);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_inbox').first()).n,1);
});
test('concurrent duplicate submissions retain one proposal and batch provenance owner',async()=>{
 const p=await payload(),q={...p,batchId:crypto.randomUUID()};const results=await Promise.all([call('/commit',p),call('/commit',q)]);assert.deepEqual(results.map(r=>r.status),[200,200]);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_inbox').first()).n,1);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_conversation_sources').first()).n,1);
});
test('quote tampering, visibility injection, duplicate selections and project traversal are refused',async()=>{
 for(const mutate of [p=>p.suggestions[0].quote+='forged',p=>p.suggestions[0].visibility='approved',p=>p.suggestions.push({...p.suggestions[0]}),p=>p.project='../secret']){const p=await payload();mutate(p);assert.equal((await call('/commit',p)).status,400);}
 assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_inbox').first()).n,0);
});
test('rollback only rejects its own pending proposals and preserves approved, approving and unrelated Inbox rows',async()=>{
 const p=await payload(),first=await call('/commit',p),id=first.value.proposals[0].proposalId;
 await db.prepare("INSERT INTO brain_inbox(id,client_id,project,title,body,source,category,created_at,status) VALUES('unrelated','external','fixture','title','body','source','knowledge','today','pending')").run();
 const rollback=await call('/rollback',{id:p.batchId});assert.equal(rollback.value.rejected,1);assert.equal((await db.prepare('SELECT status FROM brain_inbox WHERE id=?').bind(id).first()).status,'rejected');assert.equal((await db.prepare("SELECT status FROM brain_inbox WHERE id='unrelated'").first()).status,'pending');assert.equal((await call('/commit',p)).value.rolledBack,true);
 const p2=await payload();p2.project='second';const r2=await call('/commit',p2);await db.prepare("UPDATE brain_inbox SET status='approving' WHERE id=?").bind(r2.value.proposals[0].proposalId).run();const r=await call('/rollback',{id:p2.batchId});assert.equal(r.value.rejected,0);assert.equal(r.value.retainedApprovedOrApproving,1);
});
test('audit failure rolls back import and rollback transactions; maintenance never accepts excerpts',async()=>{
 const p=await payload();await db.prepare("INSERT INTO brain_config(key,value) VALUES('reindex_lock','fixture')").run();assert.equal((await call('/commit',p)).status,503);await db.prepare('DELETE FROM brain_config').run();await db.prepare('DROP TABLE audit').run();assert.equal((await call('/commit',p)).status,503);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_inbox').first()).n,0);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_conversation_imports').first()).n,0);
});
test('rollback preserves approved content and audit failure leaves a pending selection unchanged',async()=>{
 const p=await payload(),r=await call('/commit',p),id=r.value.proposals[0].proposalId;
 await db.prepare("UPDATE brain_inbox SET status='approved',memory_id='synthetic-approved' WHERE id=?").bind(id).run();
 const rolled=await call('/rollback',{id:p.batchId});assert.equal(rolled.value.rejected,0);assert.equal(rolled.value.retainedApprovedOrApproving,1);assert.equal((await db.prepare('SELECT status FROM brain_inbox WHERE id=?').bind(id).first()).status,'approved');
 const q=await payload();q.project='other';const qr=await call('/commit',q);await db.prepare('DROP TABLE audit').run();assert.equal((await call('/rollback',{id:q.batchId})).status,503);assert.equal((await db.prepare('SELECT status FROM brain_inbox WHERE id=?').bind(qr.value.proposals[0].proposalId).first()).status,'pending');assert.equal((await db.prepare('SELECT rolled_back_at FROM brain_conversation_imports WHERE id=?').bind(q.batchId).first()).rolled_back_at,null);
});

test('duplicate preview uses only source hashes, is project scoped and makes no Inbox changes',async()=>{
 const p=await payload();const check={project:p.project,fingerprints:p.suggestions.map(s=>s.fingerprint)};assert.deepEqual((await call('/check',check)).value.duplicates,[]);await call('/commit',p);const result=await call('/check',check);assert.equal(result.status,200);assert.equal(result.value.duplicates[0].fingerprint,check.fingerprints[0]);assert.deepEqual((await call('/check',{...check,project:'elsewhere'})).value.duplicates,[]);assert.equal((await db.prepare('SELECT count(*) AS n FROM brain_inbox').first()).n,1);assert.equal((await call('/check',{...check,fingerprints:['invalid']})).status,400);
});
