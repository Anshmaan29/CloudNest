-- Disposable Phase 0 fixture. Contains no personal information.
INSERT INTO memories(id,project,title,body,source,version,visibility,updated_at)
VALUES('phase0-safety','cloudnest','Disposable archive verification',
       'CloudNest retains local originals until remote SHA-256 and size verification succeeds.',
       'fixture:phase0-feasibility',1,'approved',strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(id) DO NOTHING;
