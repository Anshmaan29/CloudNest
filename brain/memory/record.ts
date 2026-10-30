export class BrainError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export interface Relationship { target: string; type: 'references' | 'belongs_to' | 'supersedes' | 'related' }
export interface MemoryRecord {
  id: string; project: string; title: string; body: string; source: string; category: string;
  visibility: 'approved' | 'private'; confidence: 'user-confirmed' | 'imported';
  operationId: string; requestHash: string; revision: string; parentRevision: string | null; version: number;
  createdAt: string; updatedAt: string; expiresAt: string | null;
  relationships: Relationship[]; deleted: boolean;
}
export const uuid = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5a-f0-9][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value);
export const utf8 = (text: string) => new TextEncoder().encode(text);
export async function sha256(value: string | Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof value === 'string' ? utf8(value) : value))).map(x => x.toString(16).padStart(2, '0')).join('');
}
export function text(value: unknown, name: string, max: number, allowEmpty = false): string {
  if (typeof value !== 'string' || value.length > max || (!allowEmpty && !value.trim()) || value.includes('\0') || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) throw new BrainError(400, `Invalid ${name}`);
  return value;
}
export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BrainError(400, 'Expected a JSON object');
  return value as Record<string, unknown>;
}
export function validRecord(record: MemoryRecord): MemoryRecord {
  if (!uuid(record.operationId) || !/^[a-f0-9]{64}$/.test(record.requestHash) || !uuid(record.id) || !uuid(record.revision) || (record.parentRevision !== null && !uuid(record.parentRevision)) || !Number.isSafeInteger(record.version) || record.version < 1 || record.version > 1000000 || typeof record.deleted !== 'boolean') throw new BrainError(400, 'Invalid memory identity or revision');
  text(record.project, 'project', 128); if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(record.project)) throw new BrainError(400, 'Invalid project');
  text(record.title, 'title', 200); text(record.body, 'body', 20000, true); text(record.source, 'source', 1000); text(record.category, 'category', 64);
  if (!['approved', 'private'].includes(record.visibility) || !['user-confirmed', 'imported'].includes(record.confidence)) throw new BrainError(400, 'Invalid visibility or confidence');
  for (const value of [record.createdAt, record.updatedAt, record.expiresAt]) if (value !== null && (typeof value !== 'string' || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value)) throw new BrainError(400, 'Invalid timestamp');
  if (!Array.isArray(record.relationships) || record.relationships.length > 64) throw new BrainError(400, 'Invalid relationships');
  const seen = new Set<string>();
  for (const relation of record.relationships) {
    if (!relation || Object.keys(relation).some(k => !['target','type'].includes(k)) || !uuid(relation.target) || !['references','belongs_to','supersedes','related'].includes(relation.type)) throw new BrainError(400, 'Invalid relationship');
    const key = relation.target + ':' + relation.type; if (seen.has(key)) throw new BrainError(400, 'Duplicate relationship'); seen.add(key);
  }
  return record;
}
export function makeRecord(input: Record<string, unknown>, prior: MemoryRecord | null, deleted = false, imported = false): MemoryRecord {
  const allowed = ['id','project','title','body','source','category','visibility','expiresAt','relationships','confidence','expectedRevision'];
  if (Object.keys(input).some(k => !allowed.includes(k))) throw new BrainError(400, 'Unknown memory field');
  if (input.id !== undefined && (!uuid(input.id) || (prior && input.id !== prior.id))) throw new BrainError(400, 'Invalid memory ID');
  const now = new Date().toISOString();
  const value = <T>(key: string, fallback: T): T => input[key] === undefined ? fallback : input[key] as T;
  return validRecord({ id: prior?.id ?? value('id', crypto.randomUUID()), project: value('project', prior?.project ?? ''),
    title: value('title', prior?.title ?? ''), body: deleted ? '' : value('body', prior?.body ?? ''), source: value('source', prior?.source ?? ''),
    category: value('category', prior?.category ?? 'knowledge'), visibility: value('visibility', prior?.visibility ?? 'approved'),
    operationId: crypto.randomUUID(), requestHash:'0'.repeat(64), confidence: imported ? 'imported' : value('confidence', prior?.confidence ?? 'user-confirmed'), revision: crypto.randomUUID(),
    parentRevision: prior?.revision ?? null, version: (prior?.version ?? 0) + 1, createdAt: prior?.createdAt ?? now, updatedAt: now,
    expiresAt: value('expiresAt', prior?.expiresAt ?? null), relationships: deleted ? [] : value('relationships', prior?.relationships ?? []), deleted });
}
const PREFIX = '<!-- CloudNest canonical memory v1 -->\n```json\n';
const SEPARATOR = '\n```\n\n';
export function markdown(record: MemoryRecord): string {
  validRecord(record); const { body, ...metadata } = record;
  const result = PREFIX + JSON.stringify(metadata, null, 2) + SEPARATOR + body;
  if (utf8(result).length > 100000) throw new BrainError(400, 'Canonical memory is too large');
  return result;
}
export function parseMarkdown(source: string): MemoryRecord {
  if (!source.startsWith(PREFIX) || utf8(source).length > 100000) throw new BrainError(400, 'Invalid canonical Markdown');
  const end = source.indexOf(SEPARATOR, PREFIX.length); if (end < 0) throw new BrainError(400, 'Invalid canonical metadata');
  let metadata: Record<string, unknown>;
  try { metadata = object(JSON.parse(source.slice(PREFIX.length, end))); } catch { throw new BrainError(400, 'Invalid canonical metadata'); }
  const expected = ['operationId','requestHash','id','project','title','source','category','visibility','confidence','revision','parentRevision','version','createdAt','updatedAt','expiresAt','relationships','deleted'];
  if (Object.keys(metadata).length !== expected.length || expected.some(k => !(k in metadata))) throw new BrainError(400, 'Invalid canonical fields');
  return validRecord({ ...metadata, body: source.slice(end + SEPARATOR.length) } as unknown as MemoryRecord);
}
export async function boundedJSON(request: Request, maximum = 65536): Promise<Record<string, unknown>> {
  if (!request.headers.get('Content-Type')?.startsWith('application/json')) throw new BrainError(400, 'Use application/json');
  const bytes = await boundedBytes(request.body, maximum);
  try { return object(JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes))); } catch (e) { if (e instanceof BrainError) throw e; throw new BrainError(400, 'Invalid JSON'); }
}
export async function boundedBytes(stream: ReadableStream<Uint8Array> | null, maximum: number): Promise<Uint8Array> {
  if (!stream) return new Uint8Array();
  const reader = stream.getReader(); const parts: Uint8Array[] = []; let length = 0;
  while (true) { const {value, done} = await reader.read(); if (done) break; length += value.length;
    if (length > maximum) { await reader.cancel(); throw new BrainError(400, 'Request or canonical object is too large'); } parts.push(value); }
  const result = new Uint8Array(length); let offset = 0; for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
}
