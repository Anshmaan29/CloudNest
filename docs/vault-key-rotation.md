# Compromised Brain signing-key rotation

A compromised HMAC key cannot authenticate historical approval. This rotation uses the owner's trusted, complete D1 history and heads as the recovery anchor, checks their exact canonical Markdown bytes against Drive, then signs replacement checkpoints with a fresh key. It never retains the compromised key as a verification keyring.

## Deployment and owner API

1. Preserve a private D1 backup and canonical snapshot before recovery. Review all revision identities, chain continuity, latest heads, tombstones and private visibility. D1 must be an independently trusted recovery anchor; do not first rebuild it from compromised-key receipts.
2. Apply migration `0007_vault_rotation.sql` and deploy the rotation-capable Worker. Keep the existing signing key temporarily as `VAULT_SIGNING_KEY`; stage an independently generated 32-byte hexadecimal secret as `VAULT_NEXT_SIGNING_KEY`. The staged key must differ from the old key. Rotate owner/Google credentials and revoke affected clients separately.
3. Recover pending writes and finish imports. Authenticate as the owner and POST `{}` to `/api/v1/vault/rotate`. The first request atomically freezes canonical access and snapshots **every** revision and head, including deleted/private history. Another maintenance lock must be resolved before this call.
4. Save the returned cursor. Repeat POST `{"cursor":"the-job-uuid"}` until `complete:true`. GET `/api/v1/vault/rotation` reports the most recent job. Responses include counts, fresh-key fingerprint, checkpoint ID and checkpoint SHA-256; they never contain key material.
5. Only after verified activation, replace `VAULT_SIGNING_KEY` with the fresh value and remove `VAULT_NEXT_SIGNING_KEY`. The durable active fingerprint accepts only the fresh key, whether supplied temporarily through NEXT or finally through the normal binding. A Worker supplied only the old key fails closed.
6. Keep sanitized counts/fingerprints/checkpoint identifiers in incident evidence. Verify owner reads, deleted/private visibility, original revision counts and client revocation after deployment. A separate disposable restore can exercise rebuild without replacing the production catalog.

The owner router must authorize before invoking `rotateVault(service, input.cursor)` or `rotationProgress(service)`. Reject unknown POST fields. Direct MCP canonical queries must suppress reads when either `reindex_lock` or `vault_rotation_lock` exists.

## What is signed

Each immutable `cloudnest-commit-v2` receipt binds the original canonical file ID, memory/revision identity, version, exact Markdown SHA-256 and the exact byte hashes of the old receipts for that revision. Old receipt bytes are retained. Their old signatures are never used as a trust fallback: rebuild permits an unauthenticated receipt only if a fresh authenticated checkpoint covers its exact hash for that revision.

One immutable `cloudnest-checkpoint-v1` root signs the revision count and SHA-256 of the sorted JSON array of `[revision, replacementReceiptByteHash]` pairs. It also retires the exact hashes of previous root checkpoints. This makes deletion of an entire rotated revision plus both receipts detectable. Activation records the active root ID, so removal of that root cannot silently downgrade validation.

Rebuild additionally treats all currently known D1 revisions as a minimum watermark. A private or deleted revision committed **after** rotation cannot disappear with its receipt and cause an earlier approved head to be published. A loss of both the independent D1 watermark and newer Drive objects cannot be inferred from a surviving older prefix; recover from an independently preserved trusted backup/checkpoint in that case. This protocol does not advance the global root on every ordinary write.

## Failure and recovery

The durable `vault_rotation_lock` and ordinary maintenance lock have no expiry. Only a request's ten-minute lease expires. Each request downloads at most twenty canonical objects or signs at most five revision receipts; cursor state, snapshot, allocated immutable IDs and checkpoints survive isolate restarts. Retrying a lost upload acknowledgement uses the same durable Drive ID and verifies existing bytes.

Rotation rejects pending writes/imports, snapshot or canonical-byte drift, unknown/branched history, missing records/receipts, changed staged key, incomplete listings, and safety-budget overflow. It downloads and verifies all replacement receipts and the signed root, rechecks the complete trusted snapshot, then atomically activates the new fingerprint/root and releases maintenance. Current lease ownership and the full D1 drift predicate fence that final transaction. Stale requests cannot publish or release maintenance, and their staging writes require a current lease.

A failed job stays frozen. Restore missing exact bytes or the staged key and resume its cursor. Do not delete locks to force success, rebuild away trusted history, or switch back to the compromised key. There is intentionally no automatic destructive abort or cleanup of canonical history.

Safety limits: 10,000 revisions, 100,000 listed objects per scan pass, and 32 historical receipts per revision or prior root checkpoints. Originals, revisions, tombstones, relationships and operation IDs are never rewritten or deleted by rotation.
