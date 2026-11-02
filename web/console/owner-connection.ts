const MAXIMUM=8192;
/** Locally imported owner access stays in tab memory, never a URL or storage. */
export function parseOwnerConnection(bytes:Uint8Array,currentOrigin:string):string {
 if(bytes.byteLength>MAXIMUM)throw new Error('Owner connection file exceeds 8 KiB.');
 let expected:URL;
 try{expected=new URL(currentOrigin);}catch{throw new Error('Owner connection import requires the current HTTPS Brain origin.');}
 if(expected.protocol!=='https:'||expected.origin!==currentOrigin)throw new Error('Owner connection import requires the current HTTPS Brain origin.');
 let value:unknown;
 try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new Error('Choose a valid owner connection JSON file.');}
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Unsupported owner connection file.');
 const object=value as Record<string,unknown>,keys=Object.keys(object).sort().join(',');
 let origin:unknown,token:unknown;
 if(keys==='baseURL,ownerToken,schemaVersion'&&object.schemaVersion===1){origin=object.baseURL;token=object.ownerToken;}
 else if(keys==='origin,token'){origin=object.origin;token=object.token;}
 else throw new Error('Unsupported owner connection fields. Use the generated connection file, not Google OAuth JSON.');
 let source:URL;
 try{if(typeof origin!=='string')throw new Error();source=new URL(origin);}catch{throw new Error('Invalid owner connection origin.');}
 if(source.protocol!=='https:'||source.origin!==expected.origin||source.username||source.password||source.pathname!=='/'||source.search||source.hash)throw new Error('This owner connection belongs to a different Brain origin.');
 if(typeof token!=='string'||! /^[\x21-\x7e]{32,256}$/.test(token))throw new Error('Invalid owner recovery credential.');
 return token;
}
export class LocalOwnerConnection {
 private generation=0;
 private token='';
 constructor(private readonly currentOrigin:string){}
 get loaded(){return this.token.length>0;}
 clear(){this.generation++;this.token='';}
 take(){const token=this.token;this.clear();return token;}
 async load(file:Blob):Promise<boolean>{
  this.clear();const generation=this.generation;
  if(file.size>MAXIMUM)throw new Error('Owner connection file exceeds 8 KiB.');
  const bytes=new Uint8Array(await file.arrayBuffer());
  if(generation!==this.generation)return false;
  const token=parseOwnerConnection(bytes,this.currentOrigin);
  if(generation!==this.generation)return false;
  this.token=token;return true;
 }
}
