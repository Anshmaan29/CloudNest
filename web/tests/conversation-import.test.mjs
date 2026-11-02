import {test,before} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
let importer;
before(async()=>{const b=await build({entryPoints:['web/console/conversation-import.ts'],bundle:true,write:false,format:'esm',platform:'node'});importer=await import('data:text/javascript;base64,'+Buffer.from(b.outputFiles[0].text).toString('base64'));});
test('local file preview and edited commit payload never fetch or automatically upload conversation data',async()=>{
 const previous=globalThis.fetch;globalThis.fetch=()=>{throw new Error('Unexpected network access');};
 try{const file=new File([JSON.stringify([{uuid:'fixture-conversation',name:'Notes',chat_messages:[{uuid:'fixture-message',sender:'human',text:'I prefer native SwiftUI apps.'}]}])],'conversations.json');const {preview,suggestions}=await importer.previewConversationFile(file,'claude');assert.equal(preview.conversations.length,1);suggestions[0].body='An edited preference';const payload=importer.conversationCommitPayload('claude','fixture',suggestions);assert.equal(payload.suggestions[0].quote,'I prefer native SwiftUI apps.');assert.equal(payload.suggestions[0].body,'An edited preference');assert.equal(Object.hasOwn(payload,'source'),false);assert.equal(Object.hasOwn(payload,'filename'),false);assert.equal(payload.batchId,importer.conversationCommitPayload('claude','fixture',suggestions,payload.batchId).batchId);}finally{globalThis.fetch=previous;}
});
test('browser preview rejects oversized and invalid UTF-8 files before any import',async()=>{
 await assert.rejects(importer.previewConversationFile(new File([new Uint8Array(8*1024*1024+1)],'large.json'),'claude'),/8 MiB/);
 await assert.rejects(importer.previewConversationFile(new File([new Uint8Array([0xff])],'invalid.json'),'claude'));
 assert.throws(()=>importer.conversationCommitPayload('claude','fixture',[]),/Select 1/);
});
