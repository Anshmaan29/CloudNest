# Selective conversation import

CloudNest accepts extracted conversation JSON from ChatGPT and Claude exports, plus a limited Gemini Apps Takeout My Activity JSON adapter. The browser reads and previews the selected local file before uploading anything. No model API, background collection, account cookies, attachment downloads, page scraping or paid service is used.

## Export and compatibility

OpenAI documents `conversations.json` and numbered JSON files in larger official exports in [Transfer exported conversations between ChatGPT accounts](https://help.openai.com/en/articles/9106926-transfer-exported-conversations-between-chatgpt-accounts). Claude documents its account conversation export through [Settings → Privacy → Export data](https://support.claude.com/en/articles/9450526-export-your-claude-data).

Google documents [My Activity → Gemini Apps in Takeout](https://support.google.com/gemini/answer/16920332?hl=en); selecting only the separate Gemini product can export Gems settings rather than chat activity. These official pages do not promise a stable detailed JSON schema. The implemented compatibility contracts are:

- ChatGPT: an array of conversations with `id` or `conversation_id`, `title`, `mapping`, and `current_node`. Each mapping node has `parent` and an optional `message` containing `id`, `author.role`, text `content.parts`, and optional Unix `create_time`. The importer follows only the current parent chain, omitting hidden, analysis-channel and tool-addressed entries. Alternative branches are excluded; missing or cyclic branch identity fails explicitly.
- Gemini: a Gemini-only My Activity JSON array whose entries identify `products` as `Gemini Apps` or legacy `Bard`, contain a valid `time`, and an English `title` beginning `Prompted `. Each prompt becomes an independent user-only activity with a stable hashed identity; no conversation-thread links or assistant replies are fabricated. HTML response/details, uploads and generated media are omitted. Mixed Google products, Gems settings, unsupported/localized-only activity and invalid timestamps are rejected. Repeated identical activity records are collapsed. Use manual context excerpts for other variants.
- Claude: an array with conversation `uuid`, `name`, and `chat_messages`; each message has `uuid`, `sender` (`human` or `assistant`), optional ISO `created_at`, and either `text` or text blocks in `content`. Non-text blocks are omitted with a warning. Empty legacy `text` falls back to text blocks, preserving modern content-block exports.

These variants have synthetic format and security tests, not a verified fresh personal-account export. A changed vendor schema is rejected or warns about omitted content; unsupported output should be reviewed before adding another adapter. ZIP/HTML, uploads, tools and system instructions are not imported. The browser's local preview is bounded at 8 MiB, 1000 conversations, 10000 messages, 50000 structural containers and depth 32. Select or split conversation JSON locally if needed; never use an online splitter for private chat data.

## Review before sending

The preview shows original roles, dates and exact text. A deterministic heuristic suggests explicit user statements such as preferences and decisions. These are editable suggestions, not verified facts. Assistant text is never automatically suggested as a user fact. The UI may offer explicit manual excerpt selection using the same provenance structure. Only selected quotes of at most 4000 characters plus edited titles/bodies are sent, in batches of 1–20. Full histories, unrelated conversations, account metadata, attachments and local filenames remain outside the upload.

Every submitted item has provider, conversation and message IDs, date, exact source quote, and SHA-256 quote identity. The server independently recalculates the fingerprint and creates only `pending` Inbox proposals with an untrusted-content label. No canonical memory is created until the existing owner approval workflow is used. Imported instructions cannot grant permissions. The selected source text is self-reported export provenance; CloudNest cannot cryptographically attest that the vendor authored a manually edited export.

Duplicate detection normalizes Unicode and whitespace and includes provider, speaker and project. An identical selected quote in the same project links to the existing proposal rather than creating another, including after rejection or rollback. A different project remains separate. The original quote is preserved without normalization. A UUID batch ID makes retrying the same selection idempotent; editing content requires a new batch ID.

## Router and UI integration contract

Apply `0009_conversation_import.sql`. Call these functions only after the existing authenticated owner REST gate and rate limit; never expose them as MCP tools:

| Route | Action |
| --- | --- |
| `GET /api/v1/conversation-imports` | `listConversationImports(service)` returns up to 50 batches. |
| `POST /api/v1/conversation-imports/check` | `checkConversationDuplicates(service,input)` accepts `{project,fingerprints}` (up to 20 source fingerprints); returns existing proposal IDs/status without sending source bodies. |
| `POST /api/v1/conversation-imports` | `commitConversationImport(service,input)` with bounded JSON up to 256 KiB. |
| `POST /api/v1/conversation-imports/:id/rollback` | Require an empty JSON body, then `rollbackConversationImport(service,id)`. |

Recovery & export includes a complete conversation-import panel: local file/provider preview, paginated source messages, manual contiguous excerpts, unchecked editable suggestions, project-scoped duplicate checks, explicit Inbox submission, and import-history rollback. The panel clears selected files, drafts and history on sign-out and discards late asynchronous results; rendering uses text/value properties. A lost commit acknowledgement retries the same batch identity.

The browser module `web/console/conversation-import.ts` exports `previewConversationFile(file,provider)`, `suggestConversationMemories(preview)` and `conversationCommitPayload(provider,project,selected,batchId?)`. Render all source text through textContent or native form values, never innerHTML. Let the user select/edit excerpts and explicitly confirm the upload; keep the batch ID across retries. The optional server preview helper is not needed for the privacy-preserving local flow.

Rollback atomically rejects only that batch's still-pending Inbox proposals. Approved memories, approvals already in progress, unrelated proposals and canonical history stay intact. Batch/source metadata remains as a private audit and duplicate-detection record. Rollback is not account erasure; owner deletion/export policy must include these operational tables. Metadata alone does not reconstruct discarded pending proposals from canonical Drive, because unapproved proposals are not canonical memories.

Synthetic tests exercise all three compatibility adapters, branching, structural bounds, quote integrity, idempotency, duplicate races, Inbox-only persistence, maintenance, audit failure and selective rollback. The panel has DOM interaction tests for explicit selection, edits, source isolation, safe rendering, late-result cancellation, retry identity and rollback. Generated full-shape fixtures in `brain/tests/fixtures/conversations/` contain no personal data. They test selected ChatGPT branches, Claude content blocks, Gemini prompt-only activities, stable identities, provider/project duplicate isolation, provenance, Inbox-only writes and repeatable rollback. This is generated-format acceptance, not a claim of verified fresh personal exports. Physical-browser visual acceptance remains a release gate; no owner download is required for the synthetic suite.
