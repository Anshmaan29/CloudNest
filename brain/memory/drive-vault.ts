import { BrainError, MemoryRecord, boundedBytes, markdown, parseMarkdown, sha256, utf8, uuid } from './record';
export interface VaultEnv {
  DB: D1Database; BRAIN_ENABLED?: string; OWNER_TOKEN_SHA256?: string;
  VAULT_SIGNING_KEY?: string; GOOGLE_CLIENT_ID?: string; GOOGLE_CLIENT_SECRET?: string; GOOGLE_REFRESH_TOKEN?: string;
}
interface FileInfo { id: string; mimeType?: string; size?: string; sha256Checksum?: string; trashed?: boolean; parents?: string[]; appProperties?: Record<string,string> }
const DRIVE = 'https://www.googleapis.com/drive/v3/';
export function configured(env: VaultEnv): boolean {
  return env.BRAIN_ENABLED === 'true' && /^[a-f0-9]{64}$/.test(env.OWNER_TOKEN_SHA256 ?? '') &&
    /^[a-f0-9]{64}$/.test(env.VAULT_SIGNING_KEY??'') && env.VAULT_SIGNING_KEY!==env.OWNER_TOKEN_SHA256 && !!env.GOOGLE_CLIENT_ID?.endsWith('.apps.googleusercontent.com') && !!env.GOOGLE_CLIENT_SECRET && !!env.GOOGLE_REFRESH_TOKEN;
}
export class DriveVault {
  private token?: { value: string; expires: number };
  constructor(private env: VaultEnv) {}
  private async accessToken(): Promise<string> {
    if (this.token && this.token.expires > Date.now()) return this.token.value;
    if (!configured(this.env)) throw new BrainError(503, 'Canonical Drive is not configured');
    const response = await fetch('https://oauth2.googleapis.com/token', {method:'POST',redirect:'manual',signal:AbortSignal.timeout(15000),headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:this.env.GOOGLE_CLIENT_ID!,client_secret:this.env.GOOGLE_CLIENT_SECRET!,refresh_token:this.env.GOOGLE_REFRESH_TOKEN!,grant_type:'refresh_token'})});
    if (!response.ok) throw new BrainError(503, 'Canonical Drive authorization is unavailable');
    const value = JSON.parse(new TextDecoder().decode(await boundedBytes(response.body, 16384))) as {access_token?:string;expires_in?:number};
    if (typeof value.access_token !== 'string' || !value.access_token || typeof value.expires_in !== 'number' || !Number.isFinite(value.expires_in) || value.expires_in <= 0) throw new BrainError(503, 'Invalid Drive authorization response');
    this.token = {value:value.access_token,expires:Date.now()+Math.max(0,Math.min(3600,value.expires_in)-60)*1000}; return this.token.value;
  }
  private endpoint(path: string, query: Record<string,string> = {}): URL { const url = new URL(path, DRIVE); for (const [k,v] of Object.entries(query)) url.searchParams.set(k,v); return url; }
  private async request(url: URL | string, init: RequestInit = {}): Promise<Response> {
    const target = new URL(url); if (target.protocol !== 'https:' || target.hostname !== 'www.googleapis.com' || target.port || target.username || target.password) throw new BrainError(503, 'Invalid canonical endpoint');
    const response = await fetch(target, {...init,redirect:'manual',signal:AbortSignal.timeout(15000),headers:{...Object.fromEntries(new Headers(init.headers)),Authorization:`Bearer ${await this.accessToken()}`}});
    if (response.status === 404) return response;
    if (!response.ok) {
      if(response.status===429)throw new BrainError(429,'Google Drive is limiting requests; retry the pending operation later');
      if(response.status===403){
        let reason='';try{const value=JSON.parse(new TextDecoder().decode(await boundedBytes(response.body,16384)));reason=value?.error?.errors?.[0]?.reason??'';}catch{/* Never expose provider response text. */}
        if(reason==='storageQuotaExceeded')throw new BrainError(503,'Google Drive quota is exhausted; free cloud capacity before recovering the pending operation');
      }
      throw new BrainError(503, 'Canonical Drive request failed; retry the pending operation');
    }
    return response;
  }
  private async json<T>(response: Response): Promise<T> { if (!response.ok) throw new BrainError(503,'Canonical Drive object is unavailable'); return JSON.parse(new TextDecoder().decode(await boundedBytes(response.body,131072))) as T; }
  private id(id: string): void { if (!/^[A-Za-z0-9_-]{1,128}$/.test(id)) throw new BrainError(400,'Invalid Drive object identity'); }
  async folder():Promise<string>{
    const cached=await this.env.DB.prepare("SELECT value FROM brain_config WHERE key='drive_folder'").first<{value:string}>();
    const correct=(info:FileInfo|null)=>!!info&&info.trashed===false&&info.mimeType==='application/vnd.google-apps.folder'&&info.appProperties?.cloudnestRole==='brain-v1';
    if(cached){this.id(cached.value);if(!correct(await this.metadata(cached.value)))throw new BrainError(503,'Configured Brain folder is unavailable or its ownership marker changed');return cached.value;}
    const listing=await this.json<{files:{id:string}[],nextPageToken?:string,incompleteSearch?:boolean}>(await this.request(this.endpoint('files',{q:"trashed=false and mimeType='application/vnd.google-apps.folder' and appProperties has { key='cloudnestRole' and value='brain-v1' }",fields:'files(id),nextPageToken,incompleteSearch',pageSize:'2',spaces:'drive'})));
    if(listing.files.length>1||listing.nextPageToken||listing.incompleteSearch)throw new BrainError(409,'Ambiguous canonical Brain folder');
    let id=listing.files[0]?.id;
    if(!id){
      // All concurrent bootstraps share one preallocated immutable folder ID.
      // A lost acknowledgement can only leave this same known folder, never a
      // duplicate root that makes catalog reconstruction ambiguous.
      const proposed=await this.allocateID();
      await this.env.DB.prepare("INSERT INTO brain_config(key,value) VALUES('drive_folder_bootstrap',?) ON CONFLICT(key) DO NOTHING").bind(proposed).run();
      const retained=await this.env.DB.prepare("SELECT value FROM brain_config WHERE key='drive_folder_bootstrap'").first<{value:string}>();if(!retained)throw new BrainError(503,'Brain folder identity could not be retained');id=retained.value;this.id(id);
      if(!correct(await this.metadata(id))){
        try{await this.request(this.endpoint('files',{fields:'id'}),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,name:'CloudNest Brain',mimeType:'application/vnd.google-apps.folder',appProperties:{cloudnestRole:'brain-v1'}})});}catch(error){if(!correct(await this.metadata(id)))throw error;}
      }
    }
    this.id(id);if(!correct(await this.metadata(id)))throw new BrainError(503,'Brain folder ownership could not be verified');
    await this.env.DB.prepare("INSERT INTO brain_config(key,value) VALUES('drive_folder',?) ON CONFLICT(key) DO NOTHING").bind(id).run();
    const saved=await this.env.DB.prepare("SELECT value FROM brain_config WHERE key='drive_folder'").first<{value:string}>();if(!saved||saved.value!==id)throw new BrainError(409,'Brain folder identity conflicts with the catalog');return id;
  }
  async allocateID(): Promise<string> {
    const value = await this.json<{ids:string[]}>(await this.request(this.endpoint('files/generateIds',{count:'1',space:'drive',type:'files'})));
    if (!value.ids?.[0]) throw new BrainError(503,'Drive could not allocate an immutable revision ID'); this.id(value.ids[0]); return value.ids[0];
  }
  private async metadata(id: string): Promise<FileInfo | null> {
    this.id(id); const response = await this.request(this.endpoint(`files/${id}`,{fields:'id,mimeType,size,sha256Checksum,trashed,parents,appProperties'}));
    if (response.status === 404) return null; return this.json<FileInfo>(response);
  }
  private async putObject(id:string,name:string,content:string,properties:Record<string,string>,mimeType:string):Promise<void>{
    this.id(id);const folder=await this.folder(),bytes=utf8(content),digest=await sha256(bytes);
    const verify=(info:FileInfo|null)=>!!info&&info.trashed===false&&Number(info.size)===bytes.length&&info.sha256Checksum===digest&&info.parents?.includes(folder)&&Object.entries(properties).every(([k,v])=>info.appProperties?.[k]===v);
    const existing=await this.metadata(id);if(existing){if(!verify(existing))throw new BrainError(409,'Immutable canonical object conflicts with Drive');return;}
    const boundary='cloudnest-'+crypto.randomUUID();
    const metadata={id,name,mimeType,parents:[folder],appProperties:properties};
    const upload=`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${mimeType}; charset=UTF-8\r\n\r\n${content}\r\n--${boundary}--\r\n`;
    await this.request('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id',{method:'POST',headers:{'Content-Type':`multipart/related; boundary=${boundary}`},body:upload});
    if(!verify(await this.metadata(id)))throw new BrainError(503,'Canonical object integrity could not be verified');
  }
  async put(record:MemoryRecord,id:string):Promise<void>{
    await this.putObject(id,`${record.id}--${record.version}--${record.revision}.md`,markdown(record),{cloudnestMemory:record.id,cloudnestRevision:record.revision},'text/markdown');
  }
  private async signReceipt(receipt:Omit<CommitReceipt,'signature'>):Promise<string>{
    if(!/^[a-f0-9]{64}$/.test(this.env.VAULT_SIGNING_KEY??''))throw new BrainError(503,'Vault signing key is not configured');
    const bytes=new Uint8Array(this.env.VAULT_SIGNING_KEY!.match(/../g)!.map(b=>parseInt(b,16)));
    const key=await crypto.subtle.importKey('raw',bytes,{name:'HMAC',hash:'SHA-256'},false,['sign']);
    return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,utf8(JSON.stringify(receipt))))).map(b=>b.toString(16).padStart(2,'0')).join('');
  }
  async putCommit(record:MemoryRecord,canonicalID:string,commitID:string):Promise<void>{
    const unsigned:Omit<CommitReceipt,'signature'>={format:'cloudnest-commit-v1',memoryID:record.id,revision:record.revision,version:record.version,canonicalID,sha256:await sha256(markdown(record))};
    const receipt:CommitReceipt={...unsigned,signature:await this.signReceipt(unsigned)};
    await this.putObject(commitID,`${record.id}--${record.version}--${record.revision}.commit.json`,JSON.stringify(receipt),{cloudnestCommit:record.id,cloudnestRevision:record.revision},'application/json');
  }
  async scan(cursor: VaultCursor | null): Promise<{records:{record:MemoryRecord,driveID:string,contentHash:string}[],receipts:CommitReceipt[],cursor:VaultCursor|null,scanned:number}> {
    const folder = await this.folder(); const state:VaultCursor=cursor??{pending:[],pageToken:null,finished:false};
    const records:{record:MemoryRecord,driveID:string,contentHash:string}[]=[];const receipts:CommitReceipt[]=[];let scanned=0,pages=0,downloads=0;
    while(downloads<20){
      if(!state.pending.length){
        if(state.finished)break;
        if(pages++>=3)break;
        const query:Record<string,string>={q:`trashed=false and '${folder}' in parents`,fields:'files(id,size,sha256Checksum,trashed,parents,appProperties),nextPageToken,incompleteSearch',pageSize:'100',spaces:'drive'};
        if(state.pageToken)query.pageToken=state.pageToken;
        const listing=await this.json<{files:FileInfo[],nextPageToken?:string,incompleteSearch?:boolean}>(await this.request(this.endpoint('files',query)));
        if(!Array.isArray(listing.files)||listing.files.length>100||listing.incompleteSearch)throw new BrainError(503,'Canonical listing is incomplete');
        if(listing.nextPageToken&&(listing.nextPageToken.length>4096||listing.nextPageToken===state.pageToken))throw new BrainError(503,'Canonical pagination is invalid');
        state.pending=listing.files;state.pageToken=listing.nextPageToken??null;state.finished=!listing.nextPageToken;
        if(!state.pending.length&&state.finished)break;
      }
      const file=state.pending.shift();if(!file)continue;scanned++;
      const isReceipt=uuid(file.appProperties?.cloudnestCommit);
      if((!isReceipt&&!uuid(file.appProperties?.cloudnestMemory))||!uuid(file.appProperties?.cloudnestRevision))continue;downloads++;
      this.id(file.id);const size=Number(file.size);
      if(!Number.isSafeInteger(size)||size<1||size>100000||!/^[a-f0-9]{64}$/.test(file.sha256Checksum??'')||file.trashed!==false)throw new BrainError(409,'Invalid canonical revision metadata');
      const response=await this.request(this.endpoint(`files/${file.id}`,{alt:'media'}));if(!response.ok)throw new BrainError(503,'Canonical revision is unavailable');
      const bytes=await boundedBytes(response.body,100000);
      if(bytes.length!==size||await sha256(bytes)!==file.sha256Checksum)throw new BrainError(409,'Canonical revision integrity mismatch');
      if(isReceipt){
        let receipt:CommitReceipt;try{receipt=JSON.parse(new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes));}catch{throw new BrainError(409,'Invalid canonical commit receipt');}
        if(receipt.format!=='cloudnest-commit-v1'||!uuid(receipt.memoryID)||!uuid(receipt.revision)||!Number.isSafeInteger(receipt.version)||receipt.version<1||!/^[A-Za-z0-9_-]{1,128}$/.test(receipt.canonicalID)||!/^[a-f0-9]{64}$/.test(receipt.sha256)||receipt.memoryID!==file.appProperties!.cloudnestCommit||receipt.revision!==file.appProperties!.cloudnestRevision)throw new BrainError(409,'Invalid canonical commit receipt');
        const unsigned:Omit<CommitReceipt,'signature'>={format:receipt.format,memoryID:receipt.memoryID,revision:receipt.revision,version:receipt.version,canonicalID:receipt.canonicalID,sha256:receipt.sha256};
        const signature=await this.signReceipt(unsigned);let difference=0;if(typeof receipt.signature!=='string'||!/^[a-f0-9]{64}$/.test(receipt.signature))throw new BrainError(409,'Canonical approval signature is invalid');for(let i=0;i<64;i++)difference|=signature.charCodeAt(i)^receipt.signature.charCodeAt(i);if(difference)throw new BrainError(409,'Canonical approval signature is invalid');
        receipts.push(receipt);continue;
      }
      const record=parseMarkdown(new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes));
      if(record.id!==file.appProperties!.cloudnestMemory||record.revision!==file.appProperties!.cloudnestRevision)throw new BrainError(409,'Canonical marker mismatch');
      records.push({record,driveID:file.id,contentHash:file.sha256Checksum!});
    }
    return{records,receipts,cursor:state.finished&&!state.pending.length?null:state,scanned};
  }
}
export interface VaultCursor {pending:FileInfo[];pageToken:string|null;finished:boolean}

export interface CommitReceipt {format:'cloudnest-commit-v1';memoryID:string;revision:string;version:number;canonicalID:string;sha256:string;signature:string}
