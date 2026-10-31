import { BrainService } from './service';
import { importMemories,listImports } from './import';
import { reindex } from './reindex';
import { clientList,createClient,revokeClient } from './clients';
import { ownerOAuth } from './oauth';
import { VaultEnv,configured } from '../memory/drive-vault';
import { BrainError,MemoryRecord,boundedJSON,makeRecord,markdown,object,sha256,text,uuid } from '../memory/record';
export interface BrainEnv extends VaultEnv { ALLOWED_ORIGINS:string;PUBLIC_ORIGIN:string;CLIENTS_JSON:string }
export const apiJSON=(value:unknown,status=200):Response=>{
  const data=JSON.stringify(value);if(new TextEncoder().encode(data).length>2*1024*1024)throw new BrainError(400,'Response exceeds 2 MiB; request a smaller page');
  return new Response(data,{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'}});
};
export async function handleBrain(request:Request,env:BrainEnv):Promise<Response>{
  try{
    const url=new URL(request.url);
    if(url.protocol!=='https:'&&!['127.0.0.1','localhost'].includes(url.hostname))throw new BrainError(400,'HTTPS required');
    if(env.PUBLIC_ORIGIN&&url.origin!==env.PUBLIC_ORIGIN)throw new BrainError(403,'Host rejected');
    const origin=request.headers.get('Origin');if(origin&&!env.ALLOWED_ORIGINS.split(',').filter(Boolean).includes(origin))throw new BrainError(403,'Origin rejected');
    const header=request.headers.get('Authorization');
    const expected=env.OWNER_TOKEN_SHA256??'';
    if(!header?.startsWith('Bearer ')||header.length<40||header.length>1024||!/^[a-f0-9]{64}$/.test(expected))throw new BrainError(401,'Owner authorization required');
    const hash=await sha256(header.slice(7));let difference=0;for(let i=0;i<64;i++)difference|=expected.charCodeAt(i)^hash.charCodeAt(i);if(difference)throw new BrainError(401,'Owner authorization required');
    const service=new BrainService(env);await service.rate('owner',request.method==='GET'?240:90);
    const path=url.pathname.slice('/api/v1'.length),method=request.method;
    const oauth=await ownerOAuth(request,env,path);if(oauth)return oauth;
    if(path==='/status'&&method==='GET'){
      const pending=await env.DB.prepare('SELECT count(*) AS count FROM brain_intents').first<{count:number}>();
      const maintenance=await env.DB.prepare("SELECT value FROM brain_config WHERE key='reindex_lock'").first<{value:string}>();
      return apiJSON({configured:configured(env),canonical:configured(env),pending:pending?.count??0,reindexJob:maintenance?.value??null});
    }
    if(!configured(env))throw new BrainError(503,'Canonical Brain requires an explicitly authorized server-side Google connection');
    const limit=Number(url.searchParams.get('limit')??50),cursor=url.searchParams.get('cursor')??'',project=url.searchParams.get('project')??'',query=url.searchParams.get('query')??'';
    if(path==='/memories'&&method==='GET')return apiJSON(await service.list(query,project,cursor,limit));
    if(path==='/deleted'&&method==='GET'){
      const result=await service.list(query,project,cursor,limit,true,true);return apiJSON(result);
    }
    const operation=()=>{const key=request.headers.get('Idempotency-Key')??crypto.randomUUID();if(!uuid(key))throw new BrainError(400,'Use a UUID Idempotency-Key');return key;};
    if(path==='/memories'&&method==='POST'){
      const input=await boundedJSON(request);return apiJSON({memory:await service.mutate(input,undefined,operation(),await sha256(JSON.stringify(['create',input])))},201);
    }
    const memoryPath=path.match(/^\/memories\/([^/]+)(?:\/(history|restore))?$/);
    if(memoryPath){
      const id=memoryPath[1],action=memoryPath[2];if(!uuid(id))throw new BrainError(400,'Invalid memory ID');
      if(!action&&method==='GET')return apiJSON({memory:await service.read(id)});
      if(action==='history'&&method==='GET'){const revisions=await service.history(id,Number(url.searchParams.get('beforeVersion')??1000001));return apiJSON({revisions,cursor:revisions.length===10?revisions.at(-1)!.version:null});}
      if(!action&&['PATCH','DELETE'].includes(method)){
        const input=await boundedJSON(request);return apiJSON({memory:await service.mutate(input,id,operation(),await sha256(JSON.stringify([method,id,input])),method==='DELETE')});
      }
      if(action==='restore'&&method==='POST'){
        const input=await boundedJSON(request);if(Object.keys(input).some(k=>!['expectedRevision','revision'].includes(k))||!uuid(input.revision))throw new BrainError(400,'Invalid restore request');
        const prior=await env.DB.prepare('SELECT payload FROM brain_revisions WHERE memory_id=? AND revision=?').bind(id,input.revision).first<{payload:string}>();if(!prior)throw new BrainError(404,'Revision not found');
        const r=JSON.parse(prior.payload) as MemoryRecord;const edits={project:r.project,title:r.title,body:r.body,source:r.source,category:r.category,visibility:r.visibility,expiresAt:r.expiresAt,relationships:r.relationships,confidence:r.confidence,expectedRevision:input.expectedRevision};
        return apiJSON({memory:await service.mutate(edits,id,operation(),await sha256(JSON.stringify(['restore',id,input])))});
      }
    }
    if(path==='/inbox'&&method==='GET')return apiJSON({proposals:await service.proposals()});
    const inboxPath=path.match(/^\/inbox\/([^/]+)\/(approve|reject)$/);
    if(inboxPath&&method==='POST'){
      if(!uuid(inboxPath[1]))throw new BrainError(400,'Invalid proposal ID');const input=await boundedJSON(request);
      if(inboxPath[2]==='approve')return apiJSON({memory:await service.approve(inboxPath[1],input,operation())});
      if(Object.keys(input).length)throw new BrainError(400,'Reject takes an empty object');await service.reject(inboxPath[1]);return apiJSON({rejected:true});
    }
    if(path==='/export'&&method==='GET'){
      const result=await service.list('',project,cursor,Math.min(limit,5),true);return apiJSON({...result,markdown:result.memories.map(m=>({id:m.id,text:markdown(m)}))});
    }
    if(path==='/imports'&&method==='GET')return apiJSON(await listImports(service));
    if(path==='/import'&&method==='POST'){const input=await boundedJSON(request,512*1024);return apiJSON(await importMemories(service,input,input.cursor===undefined?operation():undefined),201);}
    if(path==='/context'&&method==='GET')return apiJSON(await service.context(project,query));
    if(path==='/handoff'&&method==='POST'){
      const input=await boundedJSON(request);if(Object.keys(input).some(k=>!['project','task','objective','progress','unresolved','nextAction','references'].includes(k)))throw new BrainError(400,'Invalid handoff field');
      const context=await service.context(text(input.project,'project',128));const task=text(input.task,'task',3000);
      const lines=['# Continue in Another AI',`Task: ${task}`];
      for(const [key,label]of Object.entries({objective:'Objective',progress:'Current progress',unresolved:'Unresolved problems',nextAction:'Next recommended action'}))if(input[key]!==undefined)lines.push(`\n## ${label}\n${text(input[key],key,3000,true)}`);
      if(input.references!==undefined){if(!Array.isArray(input.references)||input.references.length>30)throw new BrainError(400,'Invalid references');lines.push('\n## File and source references\n'+input.references.map(r=>text(r,'reference',1000)).join('\n'));}
      lines.push('\n'+context.text);return apiJSON({text:lines.join('\n'),memories:context.memories});
    }
    if(path==='/suggestions'&&method==='GET')return apiJSON(await service.suggestions(project));
    if(path==='/graph'&&method==='GET'){const graph=await service.graph(project,Math.min(600,limit));const seen=new Set(graph.events.map(e=>(e as {clientId:string}).clientId));graph.clients=(await clientList(service,env.CLIENTS_JSON)).filter(c=>seen.has((c as {id:string}).id));const clients=new Set(graph.clients.map(c=>(c as {id:string}).id));graph.events=graph.events.filter(e=>clients.has((e as {clientId:string}).clientId));return apiJSON(graph);}
    if(path==='/reindex'&&method==='POST'){const input=await boundedJSON(request);if(Object.keys(input).some(k=>k!=='cursor'))throw new BrainError(400,'Invalid rebuild request');return apiJSON(await reindex(service,input.cursor));}
    if(path==='/operations'&&method==='GET'){
      const rows=(await env.DB.prepare('SELECT operation_id AS operationId,memory_id AS memoryId,created_at AS createdAt FROM brain_intents ORDER BY created_at LIMIT 100').all()).results;await service.audit('owner_pending_operations');return apiJSON({operations:rows});
    }
    const resume=path.match(/^\/operations\/([^/]+)\/resume$/);if(resume&&method==='POST'){await boundedJSON(request);return apiJSON({memory:await service.resume(resume[1])});}
    if(path==='/clients'&&method==='GET')return apiJSON({clients:await clientList(service,env.CLIENTS_JSON)});
    if(path==='/clients'&&method==='POST')return apiJSON(await createClient(service,await boundedJSON(request),env.CLIENTS_JSON),201);
    const revoke=path.match(/^\/clients\/([^/]+)\/revoke$/);if(revoke&&method==='POST'){await boundedJSON(request);await revokeClient(service,revoke[1]);return apiJSON({revoked:true});}
    if(path==='/audit'&&method==='GET'){
      const rows=(await env.DB.prepare('SELECT id,client_id AS clientId,action,memory_id AS memoryId,created_at AS createdAt FROM audit ORDER BY id DESC LIMIT 100').all()).results;await service.audit('owner_audit');return apiJSON({events:rows});
    }
    throw new BrainError(404,'Not found');
  }catch(error){return apiJSON({error:error instanceof BrainError?error.message:'Brain service unavailable; incomplete writes remain hidden until recovered'},error instanceof BrainError?error.status:503);}
}
