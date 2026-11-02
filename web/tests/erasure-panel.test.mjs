import {test,before} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {randomBytes,randomUUID} from 'node:crypto';
let ErasurePanel;
before(async()=>{const result=await build({entryPoints:['web/console/erasure-panel.ts'],bundle:true,write:false,format:'esm',platform:'node'});({ErasurePanel}=await import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64')));});
class Element {
 constructor(tag){this.tagName=tag;this.children=[];this.parent=null;this.connected=false;this.listeners=new Map();this.dataset={};this.classList={add(){}};this.disabled=false;this.value='';this._text='';}
 get isConnected(){return this.connected||this.parent?.isConnected||false;}
 set textContent(v){this._text=v;for(const c of this.children)c.parent=null;this.children=[];}
 get textContent(){return this._text+this.children.map(c=>c.textContent).join('');}
 set innerHTML(_){throw Error('Unsafe HTML rendering');}
 append(...children){for(const c of children){c.parent=this;this.children.push(c);}}
 replaceChildren(...children){for(const c of this.children)c.parent=null;this.children=[];this._text='';this.append(...children);}
 addEventListener(name,callback){this.listeners.set(name,callback);}
 querySelectorAll(query){const tags=query.split(',');return this.children.flatMap(c=>[...(tags.includes(c.tagName)?[c]:[]),...c.querySelectorAll(query)]);}
}
function fixture(handler=async()=>Response.json({job:null,plan:null})){
 const calls=[],root=new Element('section');root.connected=true;globalThis.location={origin:'https://brain.example.test'};globalThis.document={createElement:t=>new Element(t)};globalThis.fetch=async(url,options)=>{calls.push({url,options});return handler(url,options);};const notices=[],token=randomBytes(32).toString('hex'),file=new File([JSON.stringify({schemaVersion:1,baseURL:location.origin,ownerToken:token})],'connection.json');const panel=new ErasurePanel(root,{notice:(text,error)=>notices.push({text,error})});return{root,panel,token,file,calls,notices};
}
const job=(state='scanning')=>({id:randomUUID(),state,objects:2,bytes:64,deleted:0,preserved:1,digest:state==='review'?'a'.repeat(64):null,recoverable:true,completedAt:null});
test('local owner import makes no request and never renders or stores the recovery token',async()=>{
 const f=fixture();await f.panel.loadConnection(f.file);assert.equal(f.calls.length,0);assert.equal(f.root.textContent.includes(f.token),false);assert.equal(f.root.querySelectorAll('input').some(i=>i.value===f.token),false);assert.match(f.root.textContent,/loaded locally/);await f.panel.status();assert.equal(f.calls.length,2);assert.equal(f.calls[0].options.headers.Authorization,'Bearer '+f.token);assert.equal(f.calls[0].options.credentials,'omit');assert.equal(f.calls[0].options.redirect,'error');f.panel.clear();assert.equal(f.root.textContent.includes('loaded locally'),false);
});
test('late local file import cannot restore recovery access after lock',async()=>{
 const f=fixture();let resolve;const waiting=new Promise(r=>resolve=r),data=await f.file.arrayBuffer();const pending=f.panel.loadConnection({size:data.byteLength,arrayBuffer:()=>waiting});f.panel.clear();resolve(data);await pending;assert.equal(f.panel.credential,'');assert.equal(f.calls.length,0);assert.match(f.root.textContent,/Import your owner recovery/);
});
test('wrong-origin recovery file is rejected before any network request',async()=>{
 const f=fixture();await f.panel.loadConnection(new File([JSON.stringify({origin:'https://elsewhere.example',token:f.token})],'other.json'));assert.equal(f.calls.length,0);assert.equal(f.panel.credential,'');assert.match(f.notices.at(-1).text,/different Brain/);
});
test('review does not approve deletion and exact typed approval is an independent request',async()=>{
 const current=job();const f=fixture(async(url,options)=>{if(url.endsWith('/prepare'))return Response.json(current);if(url.endsWith('/scan'))return Response.json({...current,state:'review',digest:'a'.repeat(64)});if(url.endsWith('/approve')){const input=JSON.parse(options.body);return input.confirmation==='ERASE CLOUDNEST BRAIN'?Response.json({...current,state:'deleting',recoverable:false}):Response.json({error:'type exact phrase'},{status:400});}throw Error('unexpected');});await f.panel.loadConnection(f.file);await f.panel.prepare();assert.equal(f.calls.length,2);assert.equal(f.panel.job.state,'review');await assert.rejects(f.panel.approve(),/exact phrase/);f.panel.phrase.value='ERASE CLOUDNEST BRAIN';await f.panel.approve();assert.equal(f.panel.job.state,'deleting');assert.equal(f.panel.phrase.value,'');assert.match(f.notices.at(-1).text,/revoked/);assert.equal(f.calls.filter(c=>c.url.endsWith('/resume')).length,0);
});
test('account continuation stays recovery-authorized after browser revocation and uses bounded server states',async()=>{
 const current={...job('deleting'),recoverable:false};let step=0;const f=fixture(async()=>Response.json({...current,state:['verifying','purging','complete'][step++],deleted:2}));await f.panel.loadConnection(f.file);f.panel.job=current;await f.panel.resume();assert.equal(f.calls.length,3);assert.equal(f.panel.job.state,'complete');assert.equal(f.calls.every(c=>c.options.credentials==='omit'&&c.options.headers.Authorization==='Bearer '+f.token),true);assert.match(f.notices.at(-1).text,/Storage archives were preserved/);
});
test('clearing owner access discards delayed private operation results',async()=>{
 let resolve;const waiting=new Promise(r=>resolve=r),f=fixture(()=>waiting);await f.panel.loadConnection(f.file);const pending=f.panel.status();f.panel.clear();resolve(Response.json({job:job('review')}));await assert.rejects(pending,/cleared/);assert.equal(f.panel.job,null);assert.equal(f.panel.credential,'');assert.equal(f.root.textContent.includes('canonical objects'),false);
});
test('audit cleanup needs separate typed approval and never uses memory erasure routes',async()=>{
 const plan={id:randomUUID(),state:'review',cutoff:'2026-01-01T00:00:00.000Z',expected:201,deleted:0,digest:'b'.repeat(64)};let step=0;const f=fixture(async(url,options)=>{if(url.endsWith('/preview'))return Response.json(plan);if(url.endsWith('/approve')){assert.equal(JSON.parse(options.body).confirmation,'DELETE OLD ACCESS LOGS');return Response.json({...plan,state:'deleting'});}if(url.endsWith('/step'))return Response.json({...plan,state:++step===2?'complete':'deleting',deleted:step===2?201:200});throw Error('unexpected');});await f.panel.loadConnection(f.file);await f.panel.previewAudit();f.panel.auditPhrase.value='DELETE OLD ACCESS LOGS';await f.panel.approveAudit();await f.panel.continueAudit();assert.equal(f.panel.audit.deleted,201);assert.equal(f.calls.every(c=>c.url.includes('/audit-retention/')),true);assert.match(f.notices.at(-1).text,/Canonical memory history was not changed/);
});
