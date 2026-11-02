import {previewConversationFile,conversationCommitPayload,type ConversationPreview,type ConversationSuggestion,type ConversationProvider} from './conversation-import';
import {conversationHash} from '../../shared/schemas/conversation';
interface Dependencies {
 api<T>(path:string,method?:string,payload?:unknown):Promise<T>;
 run(action:()=>Promise<void>):Promise<void>;
 notice(message:string,error?:boolean):void;
 unlocked():boolean;
 confirm(message:string):boolean;
}
interface Draft {value:ConversationSuggestion;selected:boolean;duplicate?:string}
interface Batch {id:string;provider:string;project:string;createdAt:string;rolledBackAt:string|null;proposals:number}
const node=<T extends keyof HTMLElementTagNameMap>(tag:T,value=''):HTMLElementTagNameMap[T]=>{const n=document.createElement(tag);n.textContent=value;return n;};
const control=<T extends HTMLElement>(id:string)=>{const n=document.getElementById(id);if(!n)throw new Error('Missing conversation import control');return n as T;};
/** All content uses native text/value properties. Raw export stays tab-local. */
export class ConversationPanel {
 private epoch=0;
 private operation=0;
 private preview:ConversationPreview|null=null;
 private drafts:Draft[]=[];
 private page=0;
 private retry:{serialized:string;batchId:string}|null=null;
 constructor(private readonly deps:Dependencies){
  this.bind('conversation-preview',()=>this.openFile());
  this.bind('conversation-check',()=>this.check());
  this.bind('conversation-submit',()=>this.submit());
  this.bind('conversation-history-refresh',()=>this.loadHistory());
  this.bind('conversation-previous',async()=>{this.page=Math.max(0,this.page-1);this.renderMessages();});
  this.bind('conversation-next',async()=>{this.page++;this.renderMessages();});
  control<HTMLSelectElement>('conversation-select').addEventListener('change',()=>{this.page=0;this.renderMessages();});
  control<HTMLInputElement>('conversation-project').addEventListener('input',()=>{for(const draft of this.drafts)delete draft.duplicate;this.epoch++;this.retry=null;this.renderDrafts();});
  control<HTMLInputElement>('conversation-file').addEventListener('change',()=>this.clearPreview());
  control<HTMLSelectElement>('conversation-provider').addEventListener('change',()=>{control<HTMLInputElement>('conversation-file').value='';this.clearPreview();});
  control<HTMLButtonElement>('conversation-clear').addEventListener('click',()=>this.clear());
 }
 private bind(id:string,action:()=>Promise<void>){control<HTMLButtonElement>(id).addEventListener('click',()=>void this.execute(action));}
 private execute(action:()=>Promise<void>){return this.deps.run(async()=>{const operation=++this.operation;control('conversation-import-panel').inert=true;const fields=[...control('conversation-import-panel').querySelectorAll<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>('input,select,textarea')],states=fields.map(field=>field.disabled);fields.forEach(field=>field.disabled=true);try{await action();}finally{if(operation===this.operation){control('conversation-import-panel').inert=false;fields.forEach((field,index)=>field.disabled=states[index]);this.syncButtons();}}});}
 private active(epoch:number){return this.epoch===epoch&&this.deps.unlocked();}
 private clearPreview(){this.epoch++;this.preview=null;this.drafts=[];this.page=0;this.retry=null;for(const id of ['conversation-summary','conversation-warnings','conversation-select','conversation-messages','conversation-drafts','conversation-page'])control(id).replaceChildren();}
 clear(){this.operation++;control('conversation-import-panel').inert=false;control('conversation-import-panel').querySelectorAll<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>('input,select,textarea').forEach(field=>field.disabled=false);this.clearPreview();control<HTMLInputElement>('conversation-file').value='';control<HTMLInputElement>('conversation-project').value='';control('conversation-history').replaceChildren();this.syncButtons();}
 private project(){const p=control<HTMLInputElement>('conversation-project').value.trim();if(!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(p))throw new Error('Enter a project ID using letters, numbers, dots, underscores or hyphens.');return p;}
 async openFile(){
  if(!this.deps.unlocked())throw new Error('Sign in before previewing an export.');
  const file=control<HTMLInputElement>('conversation-file').files?.[0];if(!file)throw new Error('Choose extracted conversation JSON first.');
  this.clearPreview();const epoch=this.epoch,provider=control<HTMLSelectElement>('conversation-provider').value as ConversationProvider;
  control('conversation-summary').textContent='Reading and checking this file locally…';
  const {preview,suggestions}=await previewConversationFile(file,provider);if(!this.active(epoch))return;
  this.preview=preview;this.drafts=suggestions.map(value=>({value,selected:false}));
  control('conversation-summary').textContent=`${preview.conversations.length} conversations · ${preview.messageCount} inspected messages. Nothing has been uploaded. Choose excerpts below.`;
  for(const warning of preview.warnings)control('conversation-warnings').append(node('p',warning));
  const select=control<HTMLSelectElement>('conversation-select');preview.conversations.forEach((conversation,index)=>{const option=node('option',conversation.title||'Untitled conversation');option.value=String(index);select.append(option);});
  this.renderMessages();this.renderDrafts();
 }
 syncButtons(){const conversation=this.preview?.conversations[Number(control<HTMLSelectElement>('conversation-select').value)];const pages=Math.max(1,Math.ceil((conversation?.messages.length??0)/25));control<HTMLButtonElement>('conversation-previous').disabled=!conversation||this.page===0;control<HTMLButtonElement>('conversation-next').disabled=!conversation||this.page+1>=pages;}
 private renderMessages(){
  const target=control('conversation-messages');target.replaceChildren();const conversation=this.preview?.conversations[Number(control<HTMLSelectElement>('conversation-select').value)];
  if(!conversation){target.append(node('p','No text conversations available.'));return;}
  const pages=Math.max(1,Math.ceil(conversation.messages.length/25));this.page=Math.min(this.page,pages-1);
  control('conversation-page').textContent=`Page ${this.page+1} of ${pages}`;
  control<HTMLButtonElement>('conversation-previous').disabled=this.page===0;control<HTMLButtonElement>('conversation-next').disabled=this.page+1>=pages;
  for(const message of conversation.messages.slice(this.page*25,this.page*25+25)){
   const details=node('details'),summary=node('summary',`${message.role} · ${message.timestamp?new Date(message.timestamp).toLocaleString():'date unavailable'} · ${message.text.slice(0,100)}`),label=node('label','Exact source excerpt (up to 4000 characters)'),quote=node('textarea');
   quote.rows=4;quote.maxLength=4000;quote.value=message.text.slice(0,4000);label.append(quote);const add=node('button','Add editable suggestion');add.type='button';
   if(message.text.length>4000)details.append(node('p','This message is longer than the excerpt budget. Select a contiguous excerpt; only that excerpt can be submitted.'));
   add.addEventListener('click',()=>void this.execute(async()=>{
    if(this.drafts.length>=20)throw new Error('Keep at most 20 suggestions in a batch. Remove a draft first.');
    if(!quote.value.trim()||!message.text.includes(quote.value))throw new Error('Choose an exact contiguous excerpt from the source message. Edit the suggested memory separately.');
    const epoch=this.epoch,value=quote.value,fingerprint=await conversationHash(JSON.stringify([this.preview!.provider,message.role,value.normalize('NFC').replace(/\s+/g,' ').trim()]));if(!this.active(epoch))return;
    if(this.drafts.some(d=>d.value.fingerprint===fingerprint))throw new Error('This excerpt already has a draft.');
    this.drafts.push({selected:false,value:{conversationID:conversation.id,conversationTitle:conversation.title,messageID:message.id,role:message.role,timestamp:message.timestamp,quote:value,title:conversation.title.slice(0,180)||'Imported conversation note',body:value,inferred:true,fingerprint}});this.retry=null;this.renderDrafts();
   }));details.append(summary,label,add);target.append(details);
  }
 }
 private renderDrafts(){
  const target=control('conversation-drafts');target.replaceChildren();if(!this.drafts.length){target.append(node('p','No drafts yet. Open a source message and add an excerpt, or choose another export.'));return;}
  for(const draft of this.drafts){
   const card=node('article');card.className='conversation-draft stack';const choose=node('input');choose.type='checkbox';choose.checked=draft.selected;choose.addEventListener('change',()=>{draft.selected=choose.checked;this.retry=null;});const selected=node('label',' Include this suggestion in the Inbox');selected.prepend(choose);
   const titleLabel=node('label','Editable memory title'),title=node('input');title.value=draft.value.title;title.maxLength=200;title.addEventListener('input',()=>{draft.value.title=title.value;this.retry=null;});titleLabel.append(title);
   const bodyLabel=node('label','Editable suggested memory (unverified)'),body=node('textarea');body.value=draft.value.body;body.rows=4;body.maxLength=4000;body.addEventListener('input',()=>{draft.value.body=body.value;this.retry=null;});bodyLabel.append(body);
   const source=node('details');source.append(node('summary',`${draft.value.role} source · ${draft.value.conversationTitle} · ${draft.value.timestamp??'date unavailable'}`),node('p',`Conversation ${draft.value.conversationID}; message ${draft.value.messageID}`),node('pre',draft.value.quote));
   const remove=node('button','Remove draft');remove.type='button';remove.addEventListener('click',()=>{this.drafts=this.drafts.filter(d=>d!==draft);this.retry=null;this.renderDrafts();});
   card.append(selected,titleLabel,bodyLabel,source,node('p',draft.duplicate?`Already imported: ${draft.duplicate}. It will be skipped.`:'Not checked against earlier imports.'),remove);target.append(card);
  }
 }
 async check(){
  if(!this.preview||!this.drafts.length)throw new Error('Preview an export and add drafts first.');const epoch=this.epoch;
  const result=await this.deps.api<{duplicates:{fingerprint:string;status:string;batchId:string}[]}>('/conversation-imports/check','POST',{project:this.project(),fingerprints:this.drafts.map(d=>d.value.fingerprint)});if(!this.active(epoch))return;
  for(const draft of this.drafts)draft.duplicate=result.duplicates.find(row=>row.fingerprint===draft.value.fingerprint&&row.batchId!==this.retry?.batchId)?.status;
  this.renderDrafts();this.deps.notice(`${result.duplicates.length} previously imported excerpts found. Nothing new was saved.`);
 }
 async submit(){
  if(!this.preview)throw new Error('Preview an export first.');const epoch=this.epoch;await this.check();if(!this.active(epoch))return;
  const selected=this.drafts.filter(d=>d.selected&&!d.duplicate).map(d=>d.value);if(!selected.length)throw new Error('Select at least one new suggestion. Duplicates are skipped.');
  if(selected.some(s=>!s.title.trim()||!s.body.trim()))throw new Error('Give each selected suggestion a title and body.');
  if(!this.deps.confirm(`Send ${selected.length} selected excerpts and edited suggestions to your private Brain Inbox? Their exact quotes and source identifiers will be uploaded. Full histories stay in this tab. Separate Inbox approval is required before AI access.`))return;
  const project=this.project(),serialized=JSON.stringify({provider:this.preview.provider,project,selected});if(this.retry?.serialized!==serialized)this.retry={serialized,batchId:crypto.randomUUID()};
  const payload=conversationCommitPayload(this.preview.provider,project,selected,this.retry.batchId);
  const result=await this.deps.api<{proposals:unknown[];duplicates:unknown[];rolledBack:boolean}>('/conversation-imports','POST',payload);if(!this.active(epoch))return;
  this.deps.notice(result.rolledBack?'This batch was already rolled back.':'Saved '+result.proposals.length+' Inbox proposals. '+result.duplicates.length+' duplicates skipped. Review them in Inbox before approving.');
  this.clearPreview();control<HTMLInputElement>('conversation-file').value='';await this.loadHistory();
 }
 async loadHistory(){
  const epoch=this.epoch,result=await this.deps.api<{imports:Batch[]}>('/conversation-imports');if(!this.active(epoch))return;
  const target=control('conversation-history');target.replaceChildren();if(!result.imports.length)target.append(node('p','No conversation excerpts have been imported.'));
  for(const batch of result.imports){const row=node('article');row.className='conversation-draft stack';row.append(node('h3',`${batch.provider} · ${batch.project}`),node('p',`${new Date(batch.createdAt).toLocaleString()} · ${batch.proposals} selected excerpts${batch.rolledBackAt?' · rolled back':''}`));
   if(!batch.rolledBackAt){const rollback=node('button','Roll back pending suggestions…');rollback.type='button';rollback.addEventListener('click',()=>void this.execute(async()=>{
    if(!this.deps.confirm('Reject only this batch’s still-pending suggestions? Approved memories and approvals already in progress are preserved. Private provenance and audit records remain.'))return;
    const current=this.epoch,result=await this.deps.api<{rejected:number;retainedApprovedOrApproving:number}>('/conversation-imports/'+encodeURIComponent(batch.id)+'/rollback','POST',{});if(!this.active(current))return;this.deps.notice(`${result.rejected} pending suggestions rejected; ${result.retainedApprovedOrApproving} approved or in-progress items retained.`);await this.loadHistory();
   }));row.append(rollback);}target.append(row);
  }
 }
}
