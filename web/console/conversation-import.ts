import {parseConversationExport,suggestConversationMemories,type ConversationProvider,type ConversationPreview,type ConversationSuggestion} from '../../shared/schemas/conversation';
export {parseConversationExport,suggestConversationMemories};
export type {ConversationProvider,ConversationPreview,ConversationSuggestion};
/** Local preview only. Never uploads an export or reads any ambient page data. */
export async function previewConversationFile(file:File,provider:ConversationProvider):Promise<{preview:ConversationPreview;suggestions:ConversationSuggestion[]}>{
 if(file.size>8*1024*1024)throw new Error('Export exceeds 8 MiB. Select or split conversation JSON locally first.');
 const preview=await parseConversationExport(provider,new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()));return {preview,suggestions:suggestConversationMemories(preview)};
}
/** The caller must display/edit/select these excerpts and explicitly confirm
 * the upload. Keep the batchId for retries; changing edited content needs a new ID. */
export function conversationCommitPayload(provider:ConversationProvider,project:string,selected:ConversationSuggestion[],batchId:string=crypto.randomUUID()):Record<string,unknown>{
 if(selected.length<1||selected.length>20)throw new Error('Select 1–20 suggestions to send to the Inbox');
 return {batchId,provider,project,suggestions:selected};
}
