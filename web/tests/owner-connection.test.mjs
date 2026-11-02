import {test,before,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {randomBytes} from 'node:crypto';
let parseOwnerConnection,LocalOwnerConnection;
const origin='https://brain.example.test',secret=()=>randomBytes(32).toString('hex'),encode=value=>new TextEncoder().encode(JSON.stringify(value)),originalFetch=globalThis.fetch;
before(async()=>{const b=await build({entryPoints:['web/console/owner-connection.ts'],bundle:true,write:false,format:'esm',platform:'node'});({parseOwnerConnection,LocalOwnerConnection}=await import('data:text/javascript;base64,'+Buffer.from(b.outputFiles[0].text).toString('base64')));});
afterEach(()=>globalThis.fetch=originalFetch);
test('accepts only exact generated and native owner connection schemas for current HTTPS origin',()=>{
 const token=secret();assert.equal(parseOwnerConnection(encode({schemaVersion:1,baseURL:origin,ownerToken:token}),origin),token);assert.equal(parseOwnerConnection(encode({origin:origin+'/',token}),origin),token);
});
test('wrong origin, endpoint overrides, extra keys, Google OAuth JSON and invalid credentials fail without echoing values',()=>{
 const token=secret();
 for(const value of [{schemaVersion:1,baseURL:'https://other.example.test',ownerToken:token},{origin:origin+'/api',token},{origin:origin+'?query=secret',token},{origin:origin+'#fragment',token},{origin:'https://username:password@brain.example.test',token},{origin:'http://brain.example.test',token},{origin,token,extra:token},{schemaVersion:2,baseURL:origin,ownerToken:token},{installed:{client_secret:token}},{origin,token:'short'},{origin,token:token+'\n'}])assert.throws(()=>parseOwnerConnection(encode(value),origin),error=>!error.message.includes(token));
 for(const wrong of ['http://localhost','https://brain.example.test/path'])assert.throws(()=>parseOwnerConnection(encode({origin,token}),wrong),/current HTTPS/);
});
test('malformed UTF-8, invalid JSON and oversized input are bounded and redacted',()=>{
 assert.throws(()=>parseOwnerConnection(new Uint8Array([0xff]),origin),/valid owner connection JSON/);assert.throws(()=>parseOwnerConnection(new TextEncoder().encode('{'),origin),/valid owner connection JSON/);assert.throws(()=>parseOwnerConnection(new Uint8Array(8193),origin),/8 KiB/);
});
test('file import does not make network requests and credential is consumed once in tab memory',async()=>{
 globalThis.fetch=()=>{throw new Error('Unexpected network request');};const token=secret(),connection=new LocalOwnerConnection(origin);assert.equal(await connection.load(new Blob([encode({origin,token})])),true);assert.equal(connection.loaded,true);assert.equal(connection.take(),token);assert.equal(connection.loaded,false);assert.equal(connection.take(),'');
});
test('logout clearing rejects a delayed file load and overlapping loads keep only latest selected file',async()=>{
 const first=secret(),second=secret(),connection=new LocalOwnerConnection(origin);let resolve;const delayed=new Promise(r=>resolve=r);const pending=connection.load({size:100,arrayBuffer:()=>delayed});connection.clear();resolve(encode({origin,token:first}).buffer);assert.equal(await pending,false);assert.equal(connection.loaded,false);
 let resolveAgain;const delayedAgain=new Promise(r=>resolveAgain=r);const old=connection.load({size:100,arrayBuffer:()=>delayedAgain});await connection.load(new Blob([encode({origin,token:second})]));resolveAgain(encode({origin,token:first}).buffer);assert.equal(await old,false);assert.equal(connection.take(),second);
});
test('rejected or oversized replacement never leaves the previously loaded credential available',async()=>{
 const connection=new LocalOwnerConnection(origin);await connection.load(new Blob([encode({origin,token:secret()})]));let read=false;await assert.rejects(connection.load({size:8193,arrayBuffer:()=>{read=true;return Promise.resolve(new ArrayBuffer(0));}}),/8 KiB/);assert.equal(read,false);assert.equal(connection.loaded,false);await assert.rejects(connection.load(new Blob(['{}'])));assert.equal(connection.take(),'');
});
