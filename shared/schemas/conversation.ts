/** Export format compatibility contracts, not vendor-guaranteed schemas.
 * Pure, bounded and safe to run locally before any selected text is uploaded. */
export type ConversationProvider = 'chatgpt'|'claude';
export interface ConversationMessage {id:string;role:'user'|'assistant';text:string;timestamp:string|null;fingerprint:string}
export interface ConversationPreview {provider:ConversationProvider;conversations:{id:string;title:string;messages:ConversationMessage[]}[];warnings:string[];messageCount:number}
export const CONVERSATION_LIMITS={bytes:8*1024*1024,conversations:1000,messages:10000,nodes:50000,depth:32,text:100000};
const fail=(message:string):never=>{throw new Error(message);};
const obj=(v:unknown):Record<string,unknown>=>v!==null&&typeof v==='object'&&!Array.isArray(v)?v as Record<string,unknown>:fail('Unsupported conversation structure');
const str=(v:unknown,max:number):string=>typeof v==='string'&&v.length<=max&&!v.includes('\0')&&!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(v)?v:fail('Invalid conversation text or identifier');
export async function conversationHash(value:string):Promise<string>{return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),v=>v.toString(16).padStart(2,'0')).join('');}
function date(v:unknown):string|null {if(v===undefined||v===null)return null;const d=typeof v==='number'?new Date(v*1000):typeof v==='string'?new Date(v):null;return d&&Number.isFinite(d.getTime())?d.toISOString():fail('Invalid conversation timestamp');}
export async function parseConversationExport(provider:ConversationProvider,source:string):Promise<ConversationPreview>{
 if(!['chatgpt','claude'].includes(provider))fail('Choose a supported conversation provider');
 if(source.length>CONVERSATION_LIMITS.bytes||new TextEncoder().encode(source).length>CONVERSATION_LIMITS.bytes)fail('Export exceeds 8 MiB; select or split conversation JSON locally first');
 // Bound structural depth before JSON.parse, including unknown account metadata.
 let depth=0,quoted=false,escaped=false,nodes=0;for(const c of source){if(quoted){if(escaped)escaped=false;else if(c==='\\')escaped=true;else if(c==='"')quoted=false;}else if(c==='"')quoted=true;else if(c==='{'||c==='['){if(++depth>CONVERSATION_LIMITS.depth||++nodes>CONVERSATION_LIMITS.nodes)fail('Export exceeds structural limits');}else if(c==='}'||c===']')depth--;}
 let raw:unknown;try{raw=JSON.parse(source);}catch{fail('Select extracted conversation JSON, not ZIP, HTML or an account settings file');}
 if(!Array.isArray(raw)||raw.length>CONVERSATION_LIMITS.conversations)fail('Expected a conversation array with at most 1000 entries');
 const preview:ConversationPreview={provider,conversations:[],warnings:[],messageCount:0};let skipped=0;const conversationIDs=new Set<string>();
 for(const value of raw as unknown[]){const c=obj(value),id=str(provider==='chatgpt'?(c.id??c.conversation_id):c.uuid,256);if(!id||conversationIDs.has(id))fail('Missing or duplicate conversation identifier');conversationIDs.add(id);
 const title=str(provider==='chatgpt'?c.title:c.name,500),messages:ConversationMessage[]=[],messageIDs=new Set<string>();
 let candidates:{id:string;raw:Record<string,unknown>}[]=[];
 if(provider==='chatgpt'){
  const mapping=obj(c.mapping),entries=Object.entries(mapping);if(entries.length>CONVERSATION_LIMITS.messages)fail('Conversation exceeds message limits');
  // Follow only the current parent chain; never mix alternative assistant branches.
  if(typeof c.current_node!=='string')fail('ChatGPT export needs current_node to identify its selected branch');
  let cursor:string|null=str(c.current_node,256);const chain=new Set<string>();
  while(cursor!==null){if(chain.has(cursor)||!Object.hasOwn(mapping,cursor))fail('Invalid or cyclic ChatGPT branch');chain.add(cursor);const n=obj(mapping[cursor]);if(n.message!==null&&n.message!==undefined)candidates.push({id:cursor,raw:obj(n.message)});cursor=n.parent===null?null:str(n.parent,256);}
  candidates.reverse();
 }else{if(!Array.isArray(c.chat_messages)||c.chat_messages.length>CONVERSATION_LIMITS.messages)fail('Unsupported Claude chat_messages export');candidates=(c.chat_messages as unknown[]).map(m=>({id:str(obj(m).uuid,256),raw:obj(m)}));}
 for(const item of candidates){if(++preview.messageCount>CONVERSATION_LIMITS.messages)fail('Export exceeds 10000 message limit');const m=item.raw,mid=str(provider==='chatgpt'?(m.id??item.id):item.id,256);if(!mid||messageIDs.has(mid))fail('Missing or duplicate message identifier');messageIDs.add(mid);
  const role=provider==='chatgpt'?obj(m.author).role:m.sender==='human'?'user':m.sender==='assistant'?'assistant':m.sender;if(role!=='user'&&role!=='assistant'){skipped++;continue;}
  let body:string;
  if(provider==='chatgpt'){const content=obj(m.content);if(content.content_type!=='text'||!Array.isArray(content.parts)||content.parts.some(p=>typeof p!=='string')){skipped++;continue;}body=content.parts.map(p=>str(p,CONVERSATION_LIMITS.text)).join('\n');}
  else if(typeof m.text==='string')body=m.text;
  else if(Array.isArray(m.content)){const blocks=m.content.map(obj);if(blocks.some(b=>b.type!=='text'))skipped++;body=blocks.filter(b=>b.type==='text').map(b=>str(b.text,CONVERSATION_LIMITS.text)).join('\n');}
  else {skipped++;continue;}
  body=str(body,CONVERSATION_LIMITS.text);if(!body.trim())continue;
  messages.push({id:mid,role,text:body,timestamp:date(provider==='chatgpt'?m.create_time:m.created_at),fingerprint:await conversationHash(JSON.stringify([provider,role,body.normalize('NFC').replace(/\s+/g,' ').trim()]))});
 }
 preview.conversations.push({id,title,messages});
 }
 if(skipped)preview.warnings.push(`${skipped} system, tool, attachment or unsupported content entries omitted; no attachment or URL was fetched.`);
 preview.warnings.push('Export text is untrusted. Suggested memories are editable guesses and remain in the Inbox until separately approved.');return preview;
}
export interface ConversationSuggestion {conversationID:string;conversationTitle:string;messageID:string;role:'user'|'assistant';timestamp:string|null;quote:string;title:string;body:string;inferred:true;fingerprint:string}
export function suggestConversationMemories(preview:ConversationPreview,maximum=20):ConversationSuggestion[]{
 const limit=Number.isFinite(maximum)?Math.max(0,Math.min(20,Math.floor(maximum))):20;
 const result:ConversationSuggestion[]=[],seen=new Set<string>();
 for(const conversation of preview.conversations)for(const message of conversation.messages){
  if(result.length>=limit)return result;
  // No model call or factual inference. Surface only explicit user language as
  // editable candidates; assistant statements can be selected manually.
  if(message.role!=='user'||message.text.length>4000||!/(\bI (?:prefer|use|am|want|need)\b|\b(?:we decided|decision:|project:|remember that)\b)/i.test(message.text)||seen.has(message.fingerprint))continue;
  seen.add(message.fingerprint);result.push({conversationID:conversation.id,conversationTitle:conversation.title,messageID:message.id,role:message.role,timestamp:message.timestamp,quote:message.text,title:conversation.title.slice(0,180)||'Imported conversation note',body:message.text,inferred:true,fingerprint:message.fingerprint});
 }return result;
}
