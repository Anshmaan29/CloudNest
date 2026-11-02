// Publisher-only signing: no private key is ever printed or stored in the repository.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const fields=['architectures','assetURL','build','bytes','expiresAt','minimumMacOS','publishedAt','schemaVersion','sha256','version'];
export function validateReleaseManifest(value,now=Date.now()) {
  if(!value||Array.isArray(value)||Object.keys(value).sort().join()!==fields.join()||value.schemaVersion!==1||['version','build','minimumMacOS','assetURL','sha256','publishedAt','expiresAt'].some(k=>typeof value[k]!=='string')||
    !/^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/.test(value.version)||
    !/^[0-9]{1,12}$/.test(value.build)||!Number.isSafeInteger(value.bytes)||value.bytes<1||value.bytes>209715200||!/^[a-f0-9]{64}$/.test(value.sha256)||
    !/^[1-9][0-9]{0,2}\.(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2}))?$/.test(value.minimumMacOS)||
    !Array.isArray(value.architectures)||value.architectures.length<1||value.architectures.length>2||new Set(value.architectures).size!==value.architectures.length||value.architectures.some(a=>!['arm64','x86_64'].includes(a)))throw Error('Invalid public release manifest');
  let url;try{url=new URL(value.assetURL);}catch{throw Error('Invalid public release URL');}
  if(url.origin!=='https://github.com'||url.href!==value.assetURL||url.search||url.hash||value.assetURL.includes('%')||!/^\/Anshmaan29\/CloudNest\/releases\/download\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\.zip$/.test(url.pathname))throw Error('Update installation requires an audited ZIP asset in the CloudNest release repository');
  const start=Date.parse(value.publishedAt),end=Date.parse(value.expiresAt);
  if(!Number.isFinite(start)||!Number.isFinite(end)||new Date(start).toISOString().replace('.000Z','Z')!==value.publishedAt||new Date(end).toISOString().replace('.000Z','Z')!==value.expiresAt||start>now+300000||end<=now||end<=start||end-start>90*86400000)throw Error('Invalid release validity window');
  const pre=value.version.split('+')[0].split('-').slice(1).join('-');if(pre&&pre.split('.').some(p=>/^\d+$/.test(p)&&p.length>1&&p[0]==='0'))throw Error('Invalid semantic prerelease version');
  return value;
}
export function privateSigningKey(file,root=path.join(os.homedir(),'Library/Application Support/CloudNest/ReleaseSigning')) {
  const actual=fs.realpathSync(file),base=fs.realpathSync(root);
  if(base!==path.resolve(root)||actual!==path.resolve(file))throw Error('Publisher key paths must not contain symbolic links');
  if(!actual.startsWith(base+path.sep))throw Error('Publisher keys must stay in the private CloudNest ReleaseSigning directory outside the workspace');
  const dir=fs.lstatSync(base);if(!dir.isDirectory()||dir.isSymbolicLink()||(dir.mode&0o077)||dir.uid!==process.getuid())throw Error('Signing directory must be private and owned');
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  try{const before=fs.fstatSync(fd);if(!before.isFile()||before.uid!==process.getuid()||before.nlink!==1||(before.mode&0o777)!==0o600||before.size<1||before.size>16384)throw Error('Signing key must be a bounded private regular file');
    const bytes=fs.readFileSync(fd),after=fs.fstatSync(fd);if(before.size!==after.size||before.ctimeMs!==after.ctimeMs||before.mtimeMs!==after.mtimeMs)throw Error('Signing key changed');
    let key;try{key=createPrivateKey(bytes);}catch{throw Error('Invalid private signing key');}if(key.asymmetricKeyType!=='ed25519')throw Error('An Ed25519 signing key is required');return key;
  }finally{fs.closeSync(fd);}
}
export async function releaseEnvelope(manifest,artifact,key) {
  validateReleaseManifest(manifest);
  const fd=fs.openSync(artifact,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  let digest;try{const before=fs.fstatSync(fd);if(!before.isFile()||before.nlink!==1||before.size!==manifest.bytes)throw Error('Artifact size does not match manifest');
    const hash=createHash('sha256'),buffer=Buffer.alloc(1048576);let count=0;while(true){const n=fs.readSync(fd,buffer,0,buffer.length,null);if(!n)break;count+=n;if(count>manifest.bytes)throw Error('Artifact grew');hash.update(buffer.subarray(0,n));}digest=hash.digest('hex');const after=fs.fstatSync(fd);if(count!==manifest.bytes||before.size!==after.size||before.ctimeMs!==after.ctimeMs||before.mtimeMs!==after.mtimeMs||digest!==manifest.sha256)throw Error('Artifact integrity does not match manifest');
  }finally{fs.closeSync(fd);}
  const payload=Buffer.from(JSON.stringify(manifest));return {payload:payload.toString('base64'),signature:sign(null,payload,key).toString('base64')};
}
async function main(args) {
  if(args.length!==4)throw Error('Usage: node scripts/sign-update-feed.mjs MANIFEST_JSON AUDITED_ZIP PRIVATE_ED25519_KEY NEW_FEED_JSON');
  const [manifestFile,artifact,keyFile,output]=args;const raw=fs.readFileSync(manifestFile);if(raw.length>32768)throw Error('Manifest is oversized');const manifest=validateReleaseManifest(JSON.parse(raw));const key=privateSigningKey(keyFile);const envelope=await releaseEnvelope(manifest,artifact,key);const fd=fs.openSync(output,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o644);
  try{fs.writeFileSync(fd,JSON.stringify(envelope)+'\n');fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
  const jwk=createPublicKey(key).export({format:'jwk'});console.log('Signed verified release feed. Public publisher key: '+Buffer.from(jwk.x,'base64url').toString('base64'));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main(process.argv.slice(2)).catch(()=>{console.error('Release feed signing failed safely. Check manifest, artifact, output path and private key permissions; no private key was printed.');process.exitCode=1;});
