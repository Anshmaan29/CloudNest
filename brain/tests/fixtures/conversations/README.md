# Generated conversation compatibility fixtures

Every conversation, account identifier, project and URL in this directory is generated test data. None came from a personal account export or private chat. The fictional Lumen project deliberately exercises native-app preferences, decisions, Unicode, branching, tools, attachments and untrusted instructions.

These are compatibility fixtures for selected JSON shapes, **not vendor-issued schema files** and not evidence of fresh-account export acceptance. Do not replace them with private exports.

- `chatgpt.synthetic.json`: conversation mapping/current-node tree, selected and alternative branches, system/tool/analysis messages, final-channel text and image references.
- `claude.synthetic.json`: conversation/chat-message array, legacy text, empty legacy text with content blocks, fractional timestamps, thinking/tool blocks and attachments.
- `gemini-myactivity.synthetic.json`: Gemini Apps My Activity activity array (`products`, `title`, `time`, optional `titleUrl`, HTML response/details). Only explicit English `Prompted ` titles become user messages. Activities remain independent; responses and thread relationships are not inferred.

Official export instructions checked 2026-11-03:

- [OpenAI: exported conversation JSON, including numbered files](https://help.openai.com/en/articles/9106926-transfer-exported-conversations-between-chatgpt-accounts).
- [Anthropic: export Claude data](https://support.claude.com/en/articles/9450526-export-your-claude-data).
- [Google: download Gemini Apps data through My Activity → Gemini Apps](https://support.google.com/gemini/answer/16920332?hl=en).

Those pages establish the export routes, **not a stable detailed JSON schema**. JSON field shapes are explicitly bounded compatibility contracts. Google exports can vary by account, locale and date. Unknown/localized formats fail visibly or warn; use manual context excerpts instead of pretending a synthetic fixture proves every live export works.
