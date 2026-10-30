# Contributing

Start with README, docs/security.md and docs/verification.md. Keep changes
incremental; preserve the verified storage paths and independent Brain boundary.

Run `npm ci`, `npm run check` and `npm run build:mac`. Before a public checkpoint,
review staged files and run `npm run audit:source`. Use disposable local fixtures
outside the checkout and your own private account configuration for live tests.
A test double is not evidence that Google or an external AI client works live.

Do not commit tokens, OAuth downloads, configured endpoints, account IDs, local
catalogs, personal paths, test payloads or screenshots containing personal data.
Never add automatic deletion, broad Drive scopes or paid services as incidental
changes. New destructive operations need explicit user approval and fresh
integrity checks in both the UI and backend.

Report measured performance with device and workflow limits. Describe pending
acceptance gates candidly; a preview build is not a public production release.
