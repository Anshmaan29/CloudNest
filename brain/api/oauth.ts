import { BrainError, boundedJSON, sha256, uuid } from '../memory/record';
import { BrainService } from './service';

export interface OAuthEnv { DB:D1Database; PUBLIC_ORIGIN?:string; OWNER_TOKEN_SHA256?:string; ALLOWED_ORIGINS?:string }
export interface OAuthGrant { id:string;sha256:string;projects:string[];permissions:string[];expiresAt:string;origins:string[] }
interface Client { id:string;name:string;redirects:string;metadata:string;created_at:number }
interface Consent { id:string;client_id:string;redirect_uri:string;resource:string;challenge:string;state:string;scopes:string;created_at:number;expires_at:number;status:string;grant_id:string|null;code_hash:string|null;code_expires_at:number|null;code_used_at:number|null }
interface Grant { id:string;client_id:string;resource:string;projects:string;permissions:string;created_at:number;expires_at:number;revoked:number;rotation_count:number;revocation_reason:string|null }
interface ApprovedGrant extends Grant {redirect_uri:string}
const READ='memory:read', PROPOSE='memory:propose', MINUTE=60_000, DAY=86_400_000;
const headers={'Content-Type':'application/json','Cache-Control':'no-store','Pragma':'no-cache','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32))).map(v=>v.toString(16).padStart(2,'0')).join('');
const iso=(n:number)=>new Date(n).toISOString();
class OAuthError extends Error { constructor(readonly error:string,readonly status=400){super(error);} }
const invalid=(error='invalid_request'):never=>{throw new OAuthError(error);};

/** No Host/request-URL discovery fallback: the issuer is operator configured. */
export function oauthOrigin(env:OAuthEnv):string|null {
  if(!/^[a-f0-9]{64}$/.test(env.OWNER_TOKEN_SHA256??''))return null;
  try {const u=new URL(env.PUBLIC_ORIGIN??'');if(u.origin!==env.PUBLIC_ORIGIN||u.username||u.password||u.hash||u.search||u.pathname!=='/')return null;
    return u.protocol==='https:'||(u.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(u.hostname))?u.origin:null;
  }catch{return null;}
}
export function oauthChallenge(env:OAuthEnv):string {
  const origin=oauthOrigin(env);return origin?`Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp", scope="${READ}"`:'Bearer realm="cloudnest-brain"';
}
function validRedirect(value:unknown):value is string {
  if(typeof value!=='string'||value.length>2048||/[\s\u0000-\u001f\u007f\\*]/.test(value)||value.includes('#'))return false;
  try{const u=new URL(value);return !/^https?:\/\/[^/]*@/i.test(value)&&!u.username&&!u.password&&!!u.hostname&&!u.hostname.includes('*')&&(u.protocol==='https:'||(u.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(u.hostname)));}catch{return false;}
}
function registeredRedirectMatches(registered:string,actual:string):boolean{
  if(!validRedirect(registered)||!validRedirect(actual))return false;
  if(registered===actual)return true;
  // RFC8252 7.3/8.4: remove ONLY the port of a literal loopback-IP HTTP
  // authority. Keep path/query bytes intact; no hostname or URL normalization.
  const loopback=/^http:\/\/(127\.0\.0\.1|\[::1\])(?::\d+)?([/?].*)?$/i;
  const a=registered.match(loopback),b=actual.match(loopback);
  return !!a&&!!b&&a[1]===b[1]&&(a[2]??'')===(b[2]??'');
}
function tokenOriginAllowed(request:Request,env:OAuthEnv,issuer:string,redirectUri:string):boolean{
  const origin=request.headers.get('Origin');return !origin||origin===issuer||!!env.ALLOWED_ORIGINS?.split(',').includes(origin)||origin===new URL(redirectUri).origin;
}
function scopes(value:string|null):string[] {
  if(value===null||value==='')return[READ];const parts=value.split(' ');
  if(parts.length>2||new Set(parts).size!==parts.length||parts.some(p=>![READ,PROPOSE].includes(p))||!parts.includes(READ))return invalid('invalid_scope');return parts;
}
function single(params:URLSearchParams,key:string,required=true,max=2048):string {
  const list=params.getAll(key);if(list.length>1||(!list.length&&required))return invalid();const s=list[0]??'';
  if(s.length>max||/[\u0000-\u001f\u007f]/.test(s)||(!s&&required))return invalid();return s;
}
async function form(request:Request):Promise<URLSearchParams>{
  if(request.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase()!=='application/x-www-form-urlencoded')return invalid();
  const reader=request.body?.getReader();if(!reader)return invalid();const parts:Uint8Array[]=[];let size=0;
  while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>16384){await reader.cancel();throw new OAuthError('invalid_request',413);}parts.push(value);}
  const bytes=new Uint8Array(size);let i=0;for(const part of parts){bytes.set(part,i);i+=part.length;}
  let text:string;try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes);}catch{return invalid();}
  const data=new URLSearchParams(text);for(const [key]of data){if(data.getAll(key).length!==1)return invalid();}return data;
}
async function rate(env:OAuthEnv,request:Request,kind:string):Promise<void>{
  const service=new BrainService(env);const ip=await sha256(request.headers.get('CF-Connecting-IP')??'local');
  await service.rate('oauth:global',300);await service.rate(`oauth:${kind}:${ip}`,kind==='register'?10:60);
}
async function audit(env:OAuthEnv,action:string,id:string,actor='owner'):Promise<void>{await new BrainService(env).audit(action,id,actor);}
/** Bounded opportunistic maintenance, not a continuously running process.
 * Used refresh hashes stay until seven days AFTER grant expiry for replay evidence.
 * Audit IDs remain independent of this token/client metadata retention policy. */
export async function oauthHousekeep(env:OAuthEnv):Promise<void>{
  const now=Date.now(),cutoff=now-7*DAY;
  await env.DB.batch([
    env.DB.prepare('DELETE FROM oauth_access WHERE hash IN(SELECT hash FROM oauth_access WHERE expires_at<=? LIMIT 256)').bind(now),
    env.DB.prepare('DELETE FROM oauth_refresh WHERE hash IN(SELECT hash FROM oauth_refresh WHERE expires_at<? LIMIT 256)').bind(cutoff),
    env.DB.prepare('DELETE FROM oauth_requests WHERE id IN(SELECT r.id FROM oauth_requests r LEFT JOIN oauth_grants g ON g.id=r.grant_id WHERE r.expires_at<? AND (g.id IS NULL OR g.expires_at<?) LIMIT 64)').bind(now-DAY,cutoff),
    env.DB.prepare('DELETE FROM oauth_grants WHERE id IN(SELECT g.id FROM oauth_grants g WHERE g.expires_at<? AND NOT EXISTS(SELECT 1 FROM oauth_access a WHERE a.grant_id=g.id) AND NOT EXISTS(SELECT 1 FROM oauth_refresh r WHERE r.grant_id=g.id) AND NOT EXISTS(SELECT 1 FROM oauth_requests q WHERE q.grant_id=g.id) LIMIT 16)').bind(cutoff),
    env.DB.prepare('DELETE FROM oauth_clients WHERE id IN(SELECT c.id FROM oauth_clients c WHERE c.last_used_at<? AND NOT EXISTS(SELECT 1 FROM oauth_grants g WHERE g.client_id=c.id) AND NOT EXISTS(SELECT 1 FROM oauth_requests r WHERE r.client_id=c.id) LIMIT 16)').bind(now-DAY)
  ]);
}
async function activeGrant(env:OAuthEnv,id:string):Promise<ApprovedGrant|null>{
  return env.DB.prepare("SELECT g.*,q.redirect_uri FROM oauth_grants g JOIN oauth_requests q ON q.grant_id=g.id AND q.status='approved' WHERE g.id=? AND g.revoked=0 AND g.expires_at>? AND NOT EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=g.id)").bind(id,Date.now()).first<ApprovedGrant>();
}
async function revoke(env:OAuthEnv,id:string,action:string,actor:string):Promise<void>{
  // A broken audit sink must not resurrect a known-compromised token family.
  // Keep a durable reason on the grant even if the normal audit insert fails.
  let failure:unknown;try{await audit(env,action,id,actor);}catch(error){failure=error;}
  await env.DB.prepare('UPDATE oauth_grants SET revoked=1,revoked_at=?,revocation_reason=? WHERE id=?').bind(Date.now(),action,id).run();
  if(failure)throw failure;
}
function redirect(consent:Consent,origin:string,code?:string):string {
  const u=new URL(consent.redirect_uri);u.searchParams.set('iss',origin);if(consent.state)u.searchParams.set('state',consent.state);
  if(code)u.searchParams.set('code',code);else u.searchParams.set('error','access_denied');return u.toString();
}
async function register(request:Request,env:OAuthEnv):Promise<Response>{
  const input=await boundedJSON(request,8192),redirects=input.redirect_uris;
  if(!Array.isArray(redirects)||!redirects.length||redirects.length>8||redirects.some(v=>!validRedirect(v))||new Set(redirects).size!==redirects.length)return invalid('invalid_redirect_uri');
  if(input.token_endpoint_auth_method!==undefined&&input.token_endpoint_auth_method!=='none')return invalid('invalid_client_metadata');
  for(const [key,allowed]of [['grant_types',['authorization_code','refresh_token']],['response_types',['code']]] as const){const v=input[key];if(v!==undefined&&(!Array.isArray(v)||!v.length||v.some(p=>!allowed.includes(p as never))))return invalid('invalid_client_metadata');}
  // Metadata is displayed as untrusted text. Never fetch logos, URLs or metadata documents.
  const name=input.client_name??'Unverified MCP client';if(typeof name!=='string'||!name.trim()||name.length>200||/[\u0000-\u001f\u007f]/.test(name))return invalid('invalid_client_metadata');
  if(input.scope!==undefined&&(typeof input.scope!=='string'||!scopes(input.scope)))return invalid('invalid_client_metadata');
  const metadata:Record<string,string>={};for(const key of ['client_uri','logo_uri','policy_uri','tos_uri','software_id','software_version'])if(input[key]!==undefined){if(typeof input[key]!=='string'||(input[key] as string).length>2048)return invalid('invalid_client_metadata');metadata[key]=input[key] as string;}
  const id=crypto.randomUUID(),now=Date.now();
  await oauthHousekeep(env);
  const outcome=await env.DB.batch([
    env.DB.prepare('INSERT INTO oauth_clients(id,name,redirects,metadata,created_at,last_used_at) SELECT ?,?,?,?,?,? WHERE (SELECT count(*) FROM oauth_clients)<200').bind(id,name,JSON.stringify(redirects),JSON.stringify(metadata),now,now),
    env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) SELECT ?,'oauth_registered',? WHERE EXISTS(SELECT 1 FROM oauth_clients WHERE id=?)").bind(id,id,id)
  ]);if(outcome[0].meta.changes!==1)throw new OAuthError('temporarily_unavailable',429);
  return json({client_id:id,client_id_issued_at:Math.floor(now/1000),client_name:name,redirect_uris:redirects,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code'],scope:[READ,PROPOSE].join(' ')},201);
}
async function authorize(request:Request,env:OAuthEnv,origin:string):Promise<Response>{
  const params=new URL(request.url).searchParams;if(request.url.length>8192)return invalid();
  const id=single(params,'client_id'),client=await env.DB.prepare('SELECT * FROM oauth_clients WHERE id=?').bind(id).first<Client>();if(!client)return invalid('invalid_client');
  const uri=single(params,'redirect_uri');if(!(JSON.parse(client.redirects) as string[]).some(registered=>registeredRedirectMatches(registered,uri)))return invalid('invalid_request');
  const state=single(params,'state',false,1024);
  try{
  if(single(params,'response_type')!=='code')return invalid('unsupported_response_type');
  const resource=single(params,'resource');if(resource!==origin+'/mcp')return invalid('invalid_target');
  const challenge=single(params,'code_challenge');if(single(params,'code_challenge_method')!=='S256'||!/^[A-Za-z0-9_-]{43}$/.test(challenge))return invalid();
  const scope=scopes(params.has('scope')?single(params,'scope',false):null),requestID=crypto.randomUUID(),now=Date.now();
  const touched=await env.DB.prepare('UPDATE oauth_clients SET last_used_at=? WHERE id=?').bind(now,id).run();if(touched.meta.changes!==1)return invalid('invalid_client');
  await oauthHousekeep(env);
  const out=await env.DB.batch([
    env.DB.prepare("INSERT INTO oauth_requests(id,client_id,redirect_uri,resource,challenge,state,scopes,created_at,expires_at,status) SELECT ?,?,?,?,?,?,?,?,?,'pending' WHERE (SELECT count(*) FROM oauth_requests WHERE status='pending' AND expires_at>?)<200").bind(requestID,id,uri,resource,challenge,state,JSON.stringify(scope),now,now+5*MINUTE,now),
    env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) SELECT ?,'oauth_consent_requested',? WHERE EXISTS(SELECT 1 FROM oauth_requests WHERE id=?)").bind(id,requestID,requestID)
  ]);if(out[0].meta.changes!==1)throw new OAuthError('temporarily_unavailable',429);
  return new Response(null,{status:302,headers:{...headers,Location:origin+'/#authorize='+requestID}});
  }catch(error){if(!(error instanceof OAuthError))throw error;const callback=new URL(uri);callback.searchParams.set('error',error.error);callback.searchParams.set('iss',origin);if(state)callback.searchParams.set('state',state);return new Response(null,{status:302,headers:{...headers,Location:callback.toString()}});}
}
async function tokens(env:OAuthEnv,grant:Grant,scope:string,source:{kind:'code'|'refresh';id:string}):Promise<Response>{
  if(grant.rotation_count>=10000){await revoke(env,grant.id,'oauth_rotation_limit',grant.id);return invalid('invalid_grant');}
  await oauthHousekeep(env);
  const now=Date.now(),access=random(),refresh=random(),accessHash=await sha256(access),refreshHash=await sha256(refresh),nonce=crypto.randomUUID();
  const table=source.kind==='code'?'oauth_requests':'oauth_refresh',column=source.kind==='code'?'id':'hash',used=source.kind==='code'?'code_used_at':'used_at',expiry=source.kind==='code'?'code_expires_at':'expires_at';
  // Conditional UPDATE + dependent inserts share one atomic D1 transaction. A losing
  // exchange never issues credentials, even when two requests read the same old row.
  const statements=[env.DB.prepare(`UPDATE ${table} SET ${used}=?,consume_nonce=? WHERE ${column}=? AND ${used} IS NULL AND ${expiry}>? AND grant_id IN (SELECT id FROM oauth_grants WHERE revoked=0 AND expires_at>? AND rotation_count<10000 AND NOT EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=oauth_grants.id))`).bind(now,nonce,source.id,now,now),
    env.DB.prepare(`UPDATE oauth_grants SET rotation_count=rotation_count+1 WHERE id=? AND EXISTS(SELECT 1 FROM ${table} WHERE ${column}=? AND consume_nonce=?)`).bind(grant.id,source.id,nonce),
    env.DB.prepare(`INSERT INTO oauth_access(hash,grant_id,scope,created_at,expires_at) SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM ${table} WHERE ${column}=? AND consume_nonce=?)`).bind(accessHash,grant.id,scope,now,Math.min(now+5*MINUTE,grant.expires_at),source.id,nonce),
    env.DB.prepare(`INSERT INTO oauth_refresh(hash,grant_id,scope,created_at,expires_at) SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM ${table} WHERE ${column}=? AND consume_nonce=?)`).bind(refreshHash,grant.id,scope,now,grant.expires_at,source.id,nonce),
    env.DB.prepare(`INSERT INTO audit(client_id,action,memory_id) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM ${table} WHERE ${column}=? AND consume_nonce=?)`).bind(grant.id,source.kind==='code'?'oauth_code_exchanged':'oauth_refresh_rotated',grant.id,source.id,nonce)];
  const results=await env.DB.batch(statements);if(results[0].meta.changes!==1){await revoke(env,grant.id,'oauth_replay_revoked',grant.id);return invalid('invalid_grant');}
  return json({access_token:access,token_type:'Bearer',expires_in:Math.max(0,Math.floor((Math.min(now+5*MINUTE,grant.expires_at)-now)/1000)),refresh_token:refresh,scope});
}
async function token(request:Request,env:OAuthEnv,origin:string):Promise<Response>{
  if(request.headers.has('Authorization'))throw new OAuthError('invalid_client',401);
  const data=await form(request),allowed=['grant_type','client_id','code','redirect_uri','code_verifier','resource','refresh_token','scope'];for(const [key]of data)if(!allowed.includes(key))return invalid();
  const id=single(data,'client_id'),resource=single(data,'resource');if(resource!==origin+'/mcp')return invalid('invalid_target');
  const type=single(data,'grant_type');
  if(type==='authorization_code'){
    const code=single(data,'code'),verifier=single(data,'code_verifier');if(!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier))return invalid('invalid_grant');
    const row=await env.DB.prepare('SELECT * FROM oauth_requests WHERE code_hash=?').bind(await sha256(code)).first<Consent>();
    if(!row||row.client_id!==id||row.redirect_uri!==single(data,'redirect_uri')||row.resource!==resource||row.status!=='approved'||!row.grant_id)return invalid('invalid_grant');
    if(!tokenOriginAllowed(request,env,origin,row.redirect_uri))throw new OAuthError('access_denied',403);
    const challenge=btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
    if(challenge!==row.challenge)return invalid('invalid_grant');
    if(row.code_used_at){await revoke(env,row.grant_id,'oauth_code_replay_revoked',row.grant_id);return invalid('invalid_grant');}
    if((row.code_expires_at??0)<=Date.now())return invalid('invalid_grant');
    const grant=await activeGrant(env,row.grant_id);if(!grant)return invalid('invalid_grant');
    const scope=[READ,...(JSON.parse(grant.permissions).includes('propose')?[PROPOSE]:[])].join(' ');return tokens(env,grant,scope,{kind:'code',id:row.id});
  }
  if(type==='refresh_token'){
    const hash=await sha256(single(data,'refresh_token')),row=await env.DB.prepare('SELECT * FROM oauth_refresh WHERE hash=?').bind(hash).first<{grant_id:string;scope:string;expires_at:number;used_at:number|null}>();
    if(!row)return invalid('invalid_grant');const grant=await activeGrant(env,row.grant_id);if(!grant||grant.client_id!==id||grant.resource!==resource)return invalid('invalid_grant');
    if(!tokenOriginAllowed(request,env,origin,grant.redirect_uri))throw new OAuthError('access_denied',403);
    if(row.used_at){await revoke(env,grant.id,'oauth_refresh_replay_revoked',grant.id);return invalid('invalid_grant');}if(row.expires_at<=Date.now())return invalid('invalid_grant');
    const requested=data.has('scope')?scopes(single(data,'scope')).join(' '):row.scope;if(requested.split(' ').some(s=>!row.scope.split(' ').includes(s)))return invalid('invalid_scope');
    return tokens(env,grant,requested,{kind:'refresh',id:hash});
  }
  return invalid('unsupported_grant_type');
}

async function registeredOrigin(env:OAuthEnv,origin:string):Promise<boolean>{
  const clients=(await env.DB.prepare('SELECT redirects FROM oauth_clients LIMIT 200').all<{redirects:string}>()).results;
  return clients.some(c=>(JSON.parse(c.redirects) as string[]).some(uri=>new URL(uri).origin===origin));
}
async function consentedOrigin(env:OAuthEnv,origin:string,active=true):Promise<boolean>{
  if(!oauthOrigin(env))return false;
  const rows=(await env.DB.prepare(`SELECT q.redirect_uri FROM oauth_grants g JOIN oauth_requests q ON q.grant_id=g.id AND q.status='approved' WHERE g.resource=? ${active?'AND g.revoked=0 AND g.expires_at>? AND NOT EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=g.id)':''} ORDER BY ${active?'g.created_at DESC':'CASE WHEN g.revoked=0 AND g.expires_at>? THEN 0 ELSE 1 END,g.created_at DESC'} LIMIT ${active?100:200}`).bind(oauthOrigin(env)!+'/mcp',Date.now()).all<{redirect_uri:string}>()).results;
  return rows.some(row=>new URL(row.redirect_uri).origin===origin);
}
export async function oauthApprovedOrigin(env:OAuthEnv,origin:string):Promise<boolean>{return consentedOrigin(env,origin);}
/** Only an operator-allowed or previously owner-approved Origin can preflight. */
export async function oauthPreflight(request:Request,env:OAuthEnv):Promise<Response|null>{
  if(request.method!=='OPTIONS'||!oauthOrigin(env))return null;const origin=request.headers.get('Origin');if(!origin)return null;
  if(!env.ALLOWED_ORIGINS?.split(',').includes(origin)&&!await oauthApprovedOrigin(env,origin))return json({error:'Origin rejected'},403);
  return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'Authorization, Content-Type, Accept, MCP-Protocol-Version','Access-Control-Expose-Headers':'WWW-Authenticate','Vary':'Origin'}});
}
export async function handleOAuth(request:Request,env:OAuthEnv):Promise<Response|null>{
  const url=new URL(request.url),path=url.pathname,isMetadata=['/.well-known/oauth-protected-resource','/.well-known/oauth-protected-resource/mcp','/.well-known/oauth-authorization-server'].includes(path);
  if(!isMetadata&&!path.startsWith('/oauth/'))return null;
  let acceptedOrigin:string|null=null;const done=(response:Response):Response=>{if(acceptedOrigin){response.headers.set('Access-Control-Allow-Origin',acceptedOrigin);response.headers.set('Vary','Origin');}return response;};
  try{
    const origin=oauthOrigin(env);if(!origin)return json({error:'OAuth is not configured'},503);if(url.origin!==origin)return json({error:'Host rejected'},403);
    if(isMetadata){if(request.method!=='GET')return json({error:'method_not_allowed'},405);
      if(path==='/.well-known/oauth-authorization-server')return json({issuer:origin,authorization_endpoint:origin+'/oauth/authorize',token_endpoint:origin+'/oauth/token',registration_endpoint:origin+'/oauth/register',revocation_endpoint:origin+'/oauth/revoke',response_types_supported:['code'],grant_types_supported:['authorization_code','refresh_token'],token_endpoint_auth_methods_supported:['none'],revocation_endpoint_auth_methods_supported:['none'],code_challenge_methods_supported:['S256'],scopes_supported:[READ,PROPOSE],authorization_response_iss_parameter_supported:true,client_id_metadata_document_supported:false});
      return json({resource:origin+'/mcp',authorization_servers:[origin],scopes_supported:[READ,PROPOSE],bearer_methods_supported:['header'],resource_name:'CloudNest Brain'});
    }
    const browserOrigin=request.headers.get('Origin'),same=browserOrigin===origin||env.ALLOWED_ORIGINS?.split(',').includes(browserOrigin??'');
    if(browserOrigin&&!same&&!(await (path==='/oauth/token'?oauthApprovedOrigin(env,browserOrigin):path==='/oauth/revoke'?consentedOrigin(env,browserOrigin,false):registeredOrigin(env,browserOrigin))))return json({error:'Origin rejected'},403);
    acceptedOrigin=browserOrigin;
    if(request.method==='OPTIONS')return browserOrigin?new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Origin':browserOrigin,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'Content-Type','Vary':'Origin'}}):json({error:'Origin required'},400);
    await rate(env,request,path.slice(7));let response:Response;
    if(path==='/oauth/register'&&request.method==='POST')response=await register(request,env);
    else if(path==='/oauth/authorize'&&request.method==='GET')response=await authorize(request,env,origin);
    else if(path==='/oauth/token'&&request.method==='POST')response=await token(request,env,origin);
    else if(path==='/oauth/revoke'&&request.method==='POST'){
      if(request.headers.has('Authorization'))throw new OAuthError('invalid_client',401);const data=await form(request),id=single(data,'client_id'),hash=await sha256(single(data,'token'));
      const row=await env.DB.prepare("SELECT g.id,q.redirect_uri FROM oauth_grants g JOIN oauth_requests q ON q.grant_id=g.id AND q.status='approved' WHERE g.client_id=? AND (g.id IN(SELECT grant_id FROM oauth_access WHERE hash=?) OR g.id IN(SELECT grant_id FROM oauth_refresh WHERE hash=?))").bind(id,hash,hash).first<{id:string;redirect_uri:string}>();if(row){if(!tokenOriginAllowed(request,env,origin,row.redirect_uri))throw new OAuthError('access_denied',403);await revoke(env,row.id,'oauth_client_revoked',row.id);}response=json({});
    }else return json({error:'Not found'},404);
    return done(response);
  }catch(error){if(error instanceof OAuthError)return done(json({error:error.error},error.status));if(error instanceof BrainError)return done(json({error:error.status===429?'temporarily_unavailable':'invalid_request'},error.status));return done(json({error:'temporarily_unavailable'},503));}
}

/** Existing owner bearer authentication and Origin checks MUST run before this. */
export async function ownerOAuth(request:Request,env:OAuthEnv,path:string):Promise<Response|null>{
  if(!path.startsWith('/oauth/'))return null;const origin=oauthOrigin(env);if(!origin)throw new BrainError(503,'OAuth requires PUBLIC_ORIGIN and owner authentication');
  const match=path.match(/^\/oauth\/requests\/([^/]+)(?:\/(approve|deny))?$/);
  if(match){
    if(!uuid(match[1]))throw new BrainError(400,'Invalid consent request ID');const row=await env.DB.prepare('SELECT * FROM oauth_requests WHERE id=?').bind(match[1]).first<Consent>();if(!row)throw new BrainError(404,'Consent request not found');
    const client=await env.DB.prepare('SELECT * FROM oauth_clients WHERE id=?').bind(row.client_id).first<Client>();if(!client)throw new BrainError(404,'OAuth client not found');
    if(!match[2]&&request.method==='GET'){await audit(env,'owner_oauth_consent_read',row.id);return json({request:{id:row.id,clientId:row.client_id,clientName:client.name,redirectUri:row.redirect_uri,resource:row.resource,scopes:JSON.parse(row.scopes),createdAt:iso(row.created_at),expiresAt:iso(row.expires_at),status:row.status}});}
    if(request.method!=='POST')throw new BrainError(405,'POST required');if(row.status!=='pending'||row.expires_at<=Date.now())throw new BrainError(409,'Consent request expired or already handled');
    const input=await boundedJSON(request,8192);
    if(match[2]==='deny'){
      if(Object.keys(input).length)throw new BrainError(400,'Deny takes an empty object');const results=await env.DB.batch([env.DB.prepare("UPDATE oauth_requests SET status='denied' WHERE id=? AND status='pending' AND expires_at>?").bind(row.id,Date.now()),env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) SELECT 'owner','oauth_consent_denied',? WHERE EXISTS(SELECT 1 FROM oauth_requests WHERE id=? AND status='denied')").bind(row.id,row.id)]);if(results[0].meta.changes!==1)throw new BrainError(409,'Consent request already handled');return json({redirectUrl:redirect(row,origin)});
    }
    if(Object.keys(input).some(k=>!['projects','permissions'].includes(k))||!Array.isArray(input.projects)||!input.projects.length||input.projects.length>32||new Set(input.projects).size!==input.projects.length||input.projects.some(p=>typeof p!=='string'||!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(p)))throw new BrainError(400,'Choose one to 32 explicit projects');
    const permissions=input.permissions??[];if(!Array.isArray(permissions)||permissions.length>1||permissions.some(p=>p!=='propose')||(permissions.includes('propose')&&!JSON.parse(row.scopes).includes(PROPOSE)))throw new BrainError(400,'Proposal permission must be requested and explicitly approved');
    const code=random(),codeHash=await sha256(code),grantId='oauth-'+crypto.randomUUID(),now=Date.now();
    const results=await env.DB.batch([
      env.DB.prepare("UPDATE oauth_requests SET status='approved',grant_id=?,code_hash=?,code_expires_at=? WHERE id=? AND status='pending' AND expires_at>? AND (SELECT count(*) FROM oauth_grants WHERE revoked=0 AND expires_at>?)<100").bind(grantId,codeHash,now+5*MINUTE,row.id,now,now),
      env.DB.prepare("UPDATE oauth_grants SET revoked=1,revoked_at=?,revocation_reason='oauth_replaced_by_consent' WHERE client_id=? AND resource=? AND EXISTS(SELECT 1 FROM oauth_requests WHERE id=? AND grant_id=?)").bind(now,row.client_id,row.resource,row.id,grantId),
      env.DB.prepare('INSERT INTO oauth_grants(id,client_id,resource,projects,permissions,created_at,expires_at) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM oauth_requests WHERE id=? AND grant_id=?)').bind(grantId,row.client_id,row.resource,JSON.stringify(input.projects),JSON.stringify(permissions),now,now+30*DAY,row.id,grantId),
      env.DB.prepare("INSERT INTO audit(client_id,action,memory_id) SELECT 'owner','oauth_consent_approved',? WHERE EXISTS(SELECT 1 FROM oauth_requests WHERE id=? AND grant_id=?)").bind(grantId,row.id,grantId)
    ]);if(results[0].meta.changes!==1)throw new BrainError(409,'Consent already handled or active grant budget reached');return json({redirectUrl:redirect(row,origin,code),grantId});
  }
  if(path==='/oauth/grants'&&request.method==='GET')return json({grants:await oauthGrantList(env)});
  const revoked=path.match(/^\/oauth\/grants\/(oauth-[a-f0-9-]+)\/revoke$/);
  if(revoked&&request.method==='POST'){
    if(Object.keys(await boundedJSON(request,1024)).length)throw new BrainError(400,'Revoke takes an empty object');if(!await env.DB.prepare('SELECT id FROM oauth_grants WHERE id=?').bind(revoked[1]).first())throw new BrainError(404,'Grant not found');await revoke(env,revoked[1],'owner_oauth_revoked','owner');return json({revoked:true});
  }
  throw new BrainError(404,'OAuth operation not found');
}
export async function oauthGrantList(env:OAuthEnv):Promise<Array<{id:string;clientId:string;clientName:string;projects:string[];permissions:string[];expiresAt:string;revoked:boolean;revocationReason:string|null;lastSeen:string|null;status:string;managed:boolean;oauth:boolean}>>{
  if(!oauthOrigin(env))return[];const rows=(await env.DB.prepare("SELECT g.*,c.name,(SELECT MAX(created_at) FROM audit a WHERE a.client_id=g.id AND a.action IN ('retrieved','memory_search','memory_read','memory_recent','project_context')) AS last_seen,EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=g.id) AS retired FROM oauth_grants g JOIN oauth_clients c ON c.id=g.client_id ORDER BY CASE WHEN g.revoked=0 AND g.expires_at>? AND NOT EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=g.id) THEN 0 ELSE 1 END,g.created_at DESC LIMIT 200").bind(Date.now()).all<Grant&{name:string;last_seen:string|null;retired:number}>()).results;
  await audit(env,'owner_oauth_grants_read','oauth');return rows.map(g=>({id:g.id,clientId:g.client_id,clientName:g.name,projects:JSON.parse(g.projects),permissions:JSON.parse(g.permissions),expiresAt:iso(g.expires_at),revoked:!!g.revoked||!!g.retired,revocationReason:g.revocation_reason,lastSeen:g.last_seen,status:g.revoked||g.retired?'revoked':g.expires_at<=Date.now()?'expired':'configured',managed:true,oauth:true}));
}
export async function oauthAuthenticate(hash:string,env:OAuthEnv):Promise<OAuthGrant|null>{
  const origin=oauthOrigin(env);if(!origin)return null;const now=Date.now();
  const row=await env.DB.prepare("SELECT g.*,a.expires_at AS access_expiry,a.scope,q.redirect_uri FROM oauth_access a JOIN oauth_grants g ON g.id=a.grant_id JOIN oauth_requests q ON q.grant_id=g.id AND q.status='approved' WHERE a.hash=? AND a.expires_at>? AND g.expires_at>? AND g.revoked=0 AND g.resource=? AND NOT EXISTS(SELECT 1 FROM brain_client_revocations r WHERE r.id=g.id)").bind(hash,now,now,origin+'/mcp').first<ApprovedGrant&{access_expiry:number;scope:string}>();
  if(!row||!row.scope.split(' ').includes(READ))return null;
  return{id:row.id,sha256:hash,projects:JSON.parse(row.projects),permissions:row.scope.split(' ').includes(PROPOSE)?JSON.parse(row.permissions):[],expiresAt:iso(Math.min(row.expires_at,row.access_expiry)),origins:[new URL(row.redirect_uri).origin]};
}
