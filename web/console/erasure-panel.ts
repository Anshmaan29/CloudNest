import {LocalOwnerConnection} from './owner-connection';
interface AccountJob {id:string;state:string;objects:number;bytes:number;deleted:number;preserved:number;digest:string|null;recoverable:boolean;completedAt:string|null}
interface AuditPlan {id:string;state:string;cutoff:string;expected:number;deleted:number;digest:string|null}
interface Dependencies {notice(message:string,error?:boolean):void}
const create=<T extends keyof HTMLElementTagNameMap>(tag:T,text='')=>{const e=document.createElement(tag);e.textContent=text;return e;};
/** Standalone owner recovery remains reachable when normal sessions are revoked.
 * No credential, job or private content is persisted in browser storage. */
export class ErasurePanel {
 private generation=0;
 private credential='';
 private imported:LocalOwnerConnection;
 private requests=new Set<AbortController>();
 private busy=false;
 private stopping=false;
 private job:AccountJob|null=null;
 private audit:AuditPlan|null=null;
 private requestId=crypto.randomUUID();
 private auditRequestId=crypto.randomUUID();
 private summary=create('p','Import your owner recovery connection to inspect a privacy operation.');
 private file=create('input');
 private phrase=create('input');
 private auditPhrase=create('input');
 private days=create('select');
 private controls=create('div');
 private auditSummary=create('p');
 private buttons:HTMLButtonElement[]=[];
 constructor(private root:HTMLElement,private deps:Dependencies){
  this.imported=new LocalOwnerConnection(location.origin);
  const heading=create('h2','Privacy, retention and erasure recovery'),intro=create('p','Individual memory deletion keeps a tombstone and recoverable revision history. Permanent account erasure removes every canonical revision, Inbox item, search index, client connection and access audit. Export your data first. Storage archives are separate and are never deleted by this operation.');
  const details=create('details');details.append(create('summary','Privacy, retention and erasure recovery'),heading,intro);
  const label=create('label','Import the current owner recovery connection JSON');this.file.type='file';this.file.accept='.json,application/json';label.append(this.file);
  this.file.addEventListener('change',()=>{const selected=this.file.files?.[0];this.file.value='';if(selected)void this.loadConnection(selected);});
  const warning=create('p','This local import does not send the file or start deletion. The credential stays only in this tab and is cleared when locked or closed. Keep the recovery file: approval revokes every passkey/browser/AI session, and the job must resume using this recovery connection.');warning.className='fine';
  const actions=create('div');actions.className='actions';actions.append(this.button('Load privacy status',()=>this.status()),this.button('Clear local recovery access',async()=>this.clear(),false));
  const account=create('section');account.className='stack';account.append(create('h3','Permanent Brain account erasure'),create('p','Preparing an inventory temporarily freezes normal Brain access; nothing is deleted before approval. Unknown or unrelated Drive items and the empty Brain folder are preserved. Once approved, deletion cannot be undone and this deployment stays disabled. Independently saved exports, provider backups and copies held by other people cannot be recalled.'));
  const phraseLabel=create('label','After reviewing the counts, type ERASE CLOUDNEST BRAIN');this.phrase.type='text';this.phrase.autocomplete='off';this.phrase.maxLength=64;phraseLabel.append(this.phrase);
  this.controls.className='actions';account.append(this.summary,phraseLabel,this.controls);
  const audit=create('section');audit.className='stack';audit.append(create('h3','Access-audit retention'),create('p','Remove access logs older than a reviewed cutoff in bounded 200-record steps. Memory content, tombstones and revision history are unaffected. New logs after the review remain outside its scope. This is user initiated; no background pruning runs.'));
  const daysLabel=create('label','Keep at least');for(const n of [7,30,90,365]){const option=create('option',n+' days');option.value=String(n);this.days.append(option);}this.days.value='90';daysLabel.append(this.days);this.days.addEventListener('change',()=>{this.auditRequestId=crypto.randomUUID();});
  const auditLabel=create('label','To approve the reviewed cutoff, type DELETE OLD ACCESS LOGS');this.auditPhrase.type='text';this.auditPhrase.autocomplete='off';this.auditPhrase.maxLength=64;auditLabel.append(this.auditPhrase);
  const auditActions=create('div');auditActions.className='actions';auditActions.append(this.button('Preview old access logs',()=>this.previewAudit()),this.button('Approve audit cleanup',()=>this.approveAudit()),this.button('Continue audit cleanup',()=>this.continueAudit()),this.button('Cancel audit review',()=>this.cancelAudit()));
  audit.append(daysLabel,this.auditSummary,auditLabel,auditActions);
  const stop=this.button('Pause after the current request',async()=>{this.stopping=true;this.requests.forEach(c=>c.abort());this.deps.notice('Paused locally. Read status before continuing; confirmed deletions cannot be undone.');},false);stop.dataset.privacyStop='true';
  const help=create('a','Erasure, backup and credential cleanup instructions');help.href='https://github.com/Anshmaan29/CloudNest/blob/main/docs/account-erasure.md';help.target='_blank';help.rel='noopener noreferrer';details.append(label,warning,actions,account,audit,stop,help);this.root.classList.add('panel','stack');this.root.append(details);this.render();
 }
 private button(text:string,action:()=>Promise<void>,authorized=true){const button=create('button',text);button.type='button';button.dataset.privacyAuthorized=authorized?'true':'false';button.addEventListener('click',()=>{if(authorized)void this.run(action);else void action();});this.buttons.push(button);return button;}
 private async loadConnection(file:File){this.clear();const generation=this.generation;try{if(await this.imported.load(file)&&generation===this.generation){this.credential=this.imported.take();this.stopping=false;this.summary.textContent='Owner recovery access loaded locally. Choose Load privacy status or prepare a review; no request has been made yet.';this.render();}}catch(error){if(generation===this.generation)this.deps.notice(error instanceof Error?error.message:'Could not read the local connection.',true);}}
 clear(){this.generation++;this.credential='';this.imported.clear();for(const request of this.requests)request.abort();this.requests.clear();this.stopping=true;this.busy=false;this.job=null;this.audit=null;this.phrase.value='';this.auditPhrase.value='';this.file.value='';this.requestId=crypto.randomUUID();this.auditRequestId=crypto.randomUUID();this.render();}
 private async run(action:()=>Promise<void>){if(this.busy)return;if(!this.credential){this.deps.notice('Import your current owner recovery connection first.',true);return;}this.busy=true;this.stopping=false;const generation=this.generation;this.render();try{await action();}catch(error){if(generation===this.generation)this.deps.notice(error instanceof Error?error.message:'Privacy operation did not finish. Read status and resume the same job.',true);}finally{if(generation===this.generation){this.busy=false;this.render();}}}
 private async api<T>(path:string,body?:unknown):Promise<T>{
  if(!this.credential)throw new Error('Import the owner recovery connection first.');const generation=this.generation,controller=new AbortController();this.requests.add(controller);const timer=setTimeout(()=>controller.abort(),45000);
  try{const response=await fetch('/api/v1'+path,{method:body===undefined?'GET':'POST',credentials:'omit',redirect:'error',signal:controller.signal,headers:{Authorization:'Bearer '+this.credential,Accept:'application/json',...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});
   const reader=response.body?.getReader();if(!reader)throw new Error('Privacy service returned no status.');let size=0;const chunks:Uint8Array[]=[];while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>65536){await reader.cancel();throw new Error('Privacy status exceeded its safety limit.');}chunks.push(value);}const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}let value:Record<string,unknown>;try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new Error('Privacy service returned invalid status.');}
   if(generation!==this.generation)throw new Error('Local owner recovery access was cleared.');if(!response.ok)throw new Error(typeof value.error==='string'?value.error:'Privacy operation did not finish. Read status before retrying.');return value as T;
  }finally{clearTimeout(timer);this.requests.delete(controller);}
 }
 private async status(){const result=await this.api<{job:AccountJob|null}>('/account-erasure');this.job=result.job;if(!this.job||this.job.state==='cancelled')this.requestId=crypto.randomUUID();if(this.job?.state!=='complete'&&!this.job?.recoverable&&this.job)this.deps.notice('This account is disabled during irreversible erasure. Continue with owner recovery; do not start a new vault.');try{this.audit=(await this.api<{plan:AuditPlan|null}>('/audit-retention')).plan;}catch{this.audit=null;}this.render();}
 private async prepare(){this.job=await this.api<AccountJob>('/account-erasure/prepare',{requestId:this.requestId});await this.continueInventory();}
 private async continueInventory(){if(!this.job)throw new Error('Prepare or load an erasure job first.');while(this.job.state==='scanning'&&!this.stopping){this.job=await this.api<AccountJob>('/account-erasure/'+this.job.id+'/scan',{});this.render();}if(this.job.state==='review')this.deps.notice('Review is complete. Nothing is deleted until you type the phrase and approve.');}
 private async approve(){if(!this.job||this.job.state!=='review'||!this.job.digest)throw new Error('Finish and review an inventory first.');this.job=await this.api<AccountJob>('/account-erasure/'+this.job.id+'/approve',{digest:this.job.digest,confirmation:this.phrase.value});this.phrase.value='';this.deps.notice('Irreversible erasure approved. Browser/AI credentials were revoked. Continue using this owner recovery connection.');this.render();}
 private async resume(){if(!this.job)throw new Error('Load the existing erasure job first.');while(['deleting','verifying','purging'].includes(this.job.state)&&!this.stopping){this.job=await this.api<AccountJob>('/account-erasure/'+this.job.id+'/resume',{});this.render();}if(this.job.state==='complete')this.deps.notice('Active-service erasure complete. This Brain stays disabled. Review the provider/backup/credential cleanup instructions; Storage archives were preserved.');}
 private async rescan(){if(!this.job)throw new Error('Load the existing job first.');this.job=await this.api<AccountJob>('/account-erasure/'+this.job.id+'/rescan',{});await this.continueInventory();}
 private async cancel(){if(!this.job)throw new Error('Load a review first.');this.job=await this.api<AccountJob>('/account-erasure/'+this.job.id+'/cancel',{});this.requestId=crypto.randomUUID();this.deps.notice('Preapproval review cancelled. Normal Brain access may resume; no canonical object was deleted.');}
 private async previewAudit(){this.audit=await this.api<AuditPlan>('/audit-retention/preview',{requestId:this.auditRequestId,days:Number(this.days.value)});this.render();}
 private async approveAudit(){if(!this.audit?.digest)throw new Error('Preview old access logs first.');this.audit=await this.api<AuditPlan>('/audit-retention/'+this.audit.id+'/approve',{digest:this.audit.digest,confirmation:this.auditPhrase.value});this.auditPhrase.value='';this.render();}
 private async continueAudit(){if(!this.audit)throw new Error('Load or preview an audit plan first.');while(this.audit.state==='deleting'&&!this.stopping){this.audit=await this.api<AuditPlan>('/audit-retention/'+this.audit.id+'/step',{});this.render();}if(this.audit.state==='complete'){this.auditRequestId=crypto.randomUUID();this.deps.notice('Reviewed old access logs removed. Canonical memory history was not changed.');}}
 private async cancelAudit(){if(!this.audit)throw new Error('Load or preview an audit review first.');this.audit=await this.api<AuditPlan>('/audit-retention/'+this.audit.id+'/cancel',{});this.auditRequestId=crypto.randomUUID();this.render();}
 private async downloadReceipt(){
  if(this.job?.state!=='complete')return;
  const receipt={format:'cloudnest-account-erasure-receipt-v1',operation:this.job.id,state:'complete',canonicalObjects:this.job.objects,confirmedDeletions:this.job.deleted,canonicalBytes:this.job.bytes,unrelatedItemsPreserved:this.job.preserved,completedAt:this.job.completedAt,boundary:'Active-service deletion only. Independent exports/provider backups and credential deprovisioning require separate owner action. Storage archives were not deleted.'};
  const url=URL.createObjectURL(new Blob([JSON.stringify(receipt,null,2)],{type:'application/json'}));try{const link=create('a');link.href=url;link.download='CloudNest-erasure-receipt.json';link.click();}finally{URL.revokeObjectURL(url);}
 }
 private render(){
  this.controls.replaceChildren();const actions:HTMLButtonElement[]=[];
  if(!this.job||this.job.state==='cancelled')actions.push(this.button('Prepare account-erasure inventory',()=>this.prepare()));
  else if(this.job.state==='scanning')actions.push(this.button('Continue inventory',()=>this.continueInventory()));
  else if(this.job.state==='review')actions.push(this.button('Approve permanent account erasure',()=>this.approve()));
  else if(['deleting','verifying','purging'].includes(this.job.state)){actions.push(this.button('Continue permanent erasure',()=>this.resume()));if(this.job.state!=='purging')actions.push(this.button('Review changed or newly added objects',()=>this.rescan()));}
  if(this.job?.state==='complete')actions.push(this.button('Download completion receipt',()=>this.downloadReceipt(),false));
  if(this.job?.recoverable&&!['complete','cancelled'].includes(this.job.state))actions.push(this.button('Cancel preapproval review',()=>this.cancel()));
  this.controls.append(...actions);this.buttons=this.buttons.filter(b=>b.isConnected||actions.includes(b));for(const b of this.buttons)b.disabled=b.dataset.privacyStop==='true'?!this.busy:b.dataset.privacyAuthorized==='true'?(this.busy||!this.credential):false;this.file.disabled=this.busy;this.days.disabled=this.busy||!!this.audit&&['review','deleting'].includes(this.audit.state);this.phrase.disabled=this.busy;this.auditPhrase.disabled=this.busy;
  if(this.job)this.summary.textContent=`Job ${this.job.id}: ${this.job.state}. ${this.job.objects} canonical objects, ${this.job.bytes.toLocaleString()} bytes; ${this.job.deleted} confirmed deletions. ${this.job.preserved} unrelated items preserved. ${this.job.recoverable?'Review may be cancelled before approval.':'Already approved deletions cannot be undone.'}`;else this.summary.textContent=this.credential?'Owner recovery access loaded locally. Load privacy status or prepare a review.':'Import your owner recovery connection to inspect a privacy operation.';
  this.auditSummary.textContent=this.audit?`Audit review ${this.audit.state}: ${this.audit.expected} records before ${this.audit.cutoff}; ${this.audit.deleted} removed. Canonical revisions are preserved.`:'No audit retention review loaded.';
 }
}
