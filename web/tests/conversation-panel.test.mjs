import {test,before} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
let ConversationPanel;
before(async()=>{const b=await build({entryPoints:['web/console/conversation-panel.ts'],bundle:true,write:false,format:'esm',platform:'node'});({ConversationPanel}=await import('data:text/javascript;base64,'+Buffer.from(b.outputFiles[0].text).toString('base64')));});
class Element {
 constructor(tag){this.tagName=tag;this.children=[];this.listeners=new Map();this.disabled=false;this.checked=false;this._value='';this._text='';}
 set textContent(value){this._text=value;this.children=[];}
 get textContent(){return this._text+this.children.map(c=>c.textContent).join('');}
 set innerHTML(_){throw new Error('Unsafe HTML rendering');}
 set value(value){this._value=value;}
 get value(){return this._value||(this.tagName==='select'?this.children[0]?.value??'':'');}
 append(...children){this.children.push(...children);}
 prepend(...children){this.children.unshift(...children);}
 replaceChildren(...children){this._text='';this.children=[...children];}
 addEventListener(name,handler){this.listeners.set(name,handler);}
 event(name){this.listeners.get(name)?.({target:this});}
 querySelectorAll(query){const tags=query.split(',');return this.children.flatMap(child=>[...(tags.includes(child.tagName)?[child]:[]),...child.querySelectorAll(query)]);}
}
function setup(api=async()=>({duplicates:[],imports:[]})){
 const ids=['conversation-preview','conversation-check','conversation-submit','conversation-history-refresh','conversation-previous','conversation-next','conversation-select','conversation-project','conversation-file','conversation-provider','conversation-clear','conversation-summary','conversation-warnings','conversation-messages','conversation-drafts','conversation-page','conversation-history'];
 const elements=Object.fromEntries(ids.map(id=>[id,new Element(id.endsWith('-select')||id.endsWith('-provider')?'select':id.endsWith('-file')||id.endsWith('-project')?'input':'div')]));const panelElement=new Element('section');panelElement.append(...Object.values(elements));elements['conversation-import-panel']=panelElement;
 globalThis.document={createElement:tag=>new Element(tag),getElementById:id=>elements[id]};elements['conversation-provider'].value='claude';elements['conversation-project'].value='fixture';
 let unlocked=true;const notices=[],promises=[];const deps={api,notice:m=>notices.push(m),unlocked:()=>unlocked,confirm:()=>true,run:action=>{const p=action();promises.push(p);return p;}};
 const panel=new ConversationPanel(deps),content=JSON.stringify([{uuid:'c1',name:'<img src=x onerror=alert(1)>',chat_messages:[{uuid:'m1',sender:'human',text:'I prefer <script>private</script> notes.'},{uuid:'m2',sender:'assistant',text:'Unselected private assistant history'}]}]);elements['conversation-file'].files=[new File([content],'conversations.json')];
 return {panel,elements,notices,promises,lock:()=>{unlocked=false;panel.clear();}};
}
test('preview uses text-safe DOM, leaves drafts unchecked and never uploads whole exports',async()=>{
 const calls=[],s=setup(async(path,method,input)=>{calls.push({path,method,input});return {duplicates:[],imports:[]};});await s.panel.openFile();
 assert.match(s.elements['conversation-summary'].textContent,/Nothing has been uploaded/);assert.equal(calls.length,0);assert.match(s.elements['conversation-select'].textContent,/<img/);assert.equal(s.elements['conversation-import-panel'].querySelectorAll('img,script').length,0);
 const checkbox=s.elements['conversation-drafts'].querySelectorAll('input')[0];assert.equal(checkbox.checked,false);await assert.rejects(s.panel.submit(),/Select at least one/);assert.equal(calls.some(c=>c.path==='/conversation-imports'),false);
});
test('explicit edited selection submits only its source excerpt and offers batch rollback history',async()=>{
 const calls=[],s=setup(async(path,method,input)=>{calls.push({path,method,input});if(path.endsWith('/check'))return {duplicates:[]};if(path==='/conversation-imports'&&method==='POST')return {proposals:[{}],duplicates:[],rolledBack:false};return {imports:[]};});await s.panel.openFile();
 const [checkbox,title]=s.elements['conversation-drafts'].querySelectorAll('input');checkbox.checked=true;checkbox.event('change');title.value='Reviewed preference';title.event('input');const body=s.elements['conversation-drafts'].querySelectorAll('textarea')[0];body.value='Use concise native notes.';body.event('input');await s.panel.submit();
 const sent=calls.find(c=>c.method==='POST'&&c.path==='/conversation-imports').input;assert.equal(sent.suggestions.length,1);assert.equal(sent.suggestions[0].title,'Reviewed preference');assert.equal(sent.suggestions[0].body,'Use concise native notes.');assert.equal(sent.suggestions[0].quote,'I prefer <script>private</script> notes.');assert.equal(JSON.stringify(sent).includes('Unselected private'),false);assert.equal(Object.hasOwn(sent,'source'),false);assert.equal(s.elements['conversation-drafts'].children.length,0);
});
test('sign-out discards delayed local-file preview and clears private controls',async()=>{
 const s=setup();let resolve;const waiting=new Promise(r=>resolve=r);const content=await s.elements['conversation-file'].files[0].arrayBuffer();s.elements['conversation-file'].files=[{size:content.byteLength,arrayBuffer:()=>waiting}];const pending=s.panel.openFile();s.lock();resolve(content);await pending;assert.equal(s.elements['conversation-summary'].textContent,'');assert.equal(s.elements['conversation-drafts'].children.length,0);assert.equal(s.elements['conversation-project'].value,'');
});
test('sign-out discards late duplicate results without repopulating private drafts',async()=>{
 let resolve;const wait=new Promise(r=>resolve=r),s=setup(()=>wait);await s.panel.openFile();const check=s.panel.check();s.lock();resolve({duplicates:[]});await check;assert.equal(s.elements['conversation-drafts'].children.length,0);assert.equal(s.notices.length,0);
});
test('lost commit acknowledgement retries the same batch rather than creating new proposals',async()=>{
 let sent=null,attempts=0;const ids=[],s=setup(async(path,method,input)=>{if(path.endsWith('/check'))return {duplicates:sent?[{fingerprint:sent.suggestions[0].fingerprint,batchId:sent.batchId,status:'pending'}]:[]};if(method==='POST'){sent=input;ids.push(input.batchId);if(++attempts===1)throw new Error('Connection interrupted');return {proposals:[{}],duplicates:[],rolledBack:false};}return {imports:[]};});await s.panel.openFile();const checkbox=s.elements['conversation-drafts'].querySelectorAll('input')[0];checkbox.checked=true;checkbox.event('change');await assert.rejects(s.panel.submit(),/interrupted/);await s.panel.submit();assert.equal(attempts,2);assert.equal(ids[0],ids[1]);
});
test('history rollback is explicit and reports retained approved items',async()=>{
 const calls=[],s=setup(async(path,method,input)=>{calls.push({path,method,input});return method==='POST'?{rejected:2,retainedApprovedOrApproving:1}:{imports:[{id:'fixture-batch',provider:'claude',project:'fixture',createdAt:'2026-01-01T00:00:00.000Z',rolledBackAt:null,proposals:3}]};});await s.panel.loadHistory();const rollback=s.elements['conversation-history'].querySelectorAll('button')[0];rollback.event('click');await Promise.all(s.promises);assert.equal(calls.some(c=>c.path==='/conversation-imports/fixture-batch/rollback'&&c.method==='POST'),true);assert.match(s.notices[0],/1 approved or in-progress items retained/);
});
