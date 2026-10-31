import { BrainError, object, sha256, text, uuid } from '../memory/record';
import { BrainService } from './service';
import { OAuthEnv, oauthGrantList } from './oauth';
export interface ClientGrant {id:string;sha256:string;projects:string[];expiresAt:string;revoked?:boolean;permissions?:string[]}
export async function clientList(service:BrainService, configured:string):Promise<unknown[]> {
  const staticGrants:ClientGrant[]=JSON.parse(configured||'[]');if(!Array.isArray(staticGrants)||staticGrants.length>100)throw new BrainError(503,'Client grant configuration is invalid');
  const dynamic=(await service.env.DB.prepare('SELECT id,projects,permissions,expires_at AS expiresAt,revoked FROM brain_clients').all<{id:string,projects:string,permissions:string,expiresAt:string,revoked:number}>()).results;
  const revoked=new Set((await service.env.DB.prepare('SELECT id FROM brain_client_revocations').all<{id:string}>()).results.map(x=>x.id));
  const clients=[...staticGrants.map(g=>({id:g.id,projects:g.projects,permissions:g.permissions??[],expiresAt:g.expiresAt,revoked:!!g.revoked,managed:false})),...dynamic.map(g=>({id:g.id,projects:JSON.parse(g.projects),permissions:JSON.parse(g.permissions),expiresAt:g.expiresAt,revoked:!!g.revoked,managed:true}))];
  const activity=(await service.env.DB.prepare('SELECT client_id,MAX(created_at) AS lastSeen FROM audit GROUP BY client_id').all<{client_id:string,lastSeen:string}>()).results;
  const oauth=await oauthGrantList(service.env as OAuthEnv);
  await service.audit('owner_clients');return [...clients.map(c=>({...c,revoked:c.revoked||revoked.has(c.id),status:c.revoked||revoked.has(c.id)?'revoked':Date.parse(c.expiresAt)<=Date.now()?'expired':'configured',lastSeen:activity.find(a=>a.client_id===c.id)?.lastSeen??null})),...oauth];
}
export async function createClient(service:BrainService,input:Record<string,unknown>,configured:string):Promise<unknown> {
  if(Object.keys(input).some(k=>!['id','projects','permissions','expiresAt'].includes(k)))throw new BrainError(400,'Invalid client fields');
  const id=text(input.id,'client ID',64);if(id==='owner'||id.startsWith('oauth-')||!/^[A-Za-z0-9][A-Za-z0-9_.-]+$/.test(id))throw new BrainError(400,'Invalid client ID');
  if(!Array.isArray(input.projects)||input.projects.length<1||input.projects.length>32||input.projects.some(p=>typeof p!=='string'||!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(p)))throw new BrainError(400,'Invalid client projects');
  const permissions=input.permissions??[];if(!Array.isArray(permissions)||permissions.some(p=>p!=='propose')||permissions.length>1)throw new BrainError(400,'Only the optional propose permission is supported');
  const expiresAt=text(input.expiresAt,'expiry',40),expires=Date.parse(expiresAt);if(!Number.isFinite(expires)||expires<=Date.now()||expires>Date.now()+90*86400000)throw new BrainError(400,'Expiry must be within 90 days');
  if(await service.env.DB.prepare('SELECT id FROM brain_client_revocations WHERE id=?').bind(id).first())throw new BrainError(409,'A retired client identity cannot be reused');
  const all=await clientList(service,configured);if(all.length>=100||all.some(c=>(c as {id:string}).id===id))throw new BrainError(409,'Client identity exists or grant budget reached');
  const token=Array.from(crypto.getRandomValues(new Uint8Array(32))).map(b=>b.toString(16).padStart(2,'0')).join('');
  await service.env.DB.batch([service.env.DB.prepare('INSERT INTO brain_clients(id,sha256,projects,permissions,expires_at,created_at) VALUES(?,?,?,?,?,?)').bind(id,await sha256(token),JSON.stringify(input.projects),JSON.stringify(permissions),new Date(expires).toISOString(),new Date().toISOString()),service.env.DB.prepare('INSERT INTO audit(client_id,action,memory_id) VALUES(?,?,?)').bind('owner','client_created',id)]);
  return{client:{id,projects:input.projects,permissions,expiresAt:new Date(expires).toISOString(),status:'configured'},token,warning:'Shown once. Store securely; never put this token in a URL or send it to another client.'};
}
export async function revokeClient(service:BrainService,id:string):Promise<void>{
  text(id,'client ID',64);await service.env.DB.batch([service.env.DB.prepare('INSERT INTO brain_client_revocations(id,revoked_at) VALUES(?,?) ON CONFLICT(id) DO NOTHING').bind(id,new Date().toISOString()),service.env.DB.prepare('UPDATE brain_clients SET revoked=1 WHERE id=?').bind(id),service.env.DB.prepare('INSERT INTO audit(client_id,action,memory_id) VALUES(?,?,?)').bind('owner','client_revoked',id)]);
}
