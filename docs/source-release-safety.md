# Audited source and native packages

Source releases must come from one clean committed Git snapshot. Never use a
recursive ZIP of a workspace, Finder folder compression, `zip -r`, or a copy of the
whole repository directory: ignored setup bundles, exports and local credentials
can live alongside public code.

Run these commands from the repository root after committing the reviewed source:

```sh
node --test scripts/release-safety.test.mjs
node scripts/audit-public-source.mjs
node scripts/audit-public-source.mjs --history
node scripts/package-source.mjs --output ../CloudNest-source-reviewed.zip
```

Choose a **new** destination. The packager refuses to replace any existing file.
It reads the tracked `HEAD` tree and immutable Git blobs, requires a clean index
and working tree (including untracked non-ignored files), and rechecks cleanliness
and the commit before publication. Ignored local files are excluded by the Git
allowlist; they are never opened by this process. No recursive workspace archive
is created, and Git internals, submodules and symlinks cannot enter the package.

Each tracked filename and blob is audited before ZIP creation. The staged ZIP is
then independently parsed and audited before atomic publication at the requested
path. Archive checks validate the directory, local headers, CRCs, file types,
unique portable paths, compressed and expanded sizes, and complete bounds. They
reject traversal, symlinks, duplicate/colliding paths, encrypted entries, ZIP64,
unsupported metadata and unexpected trailing bytes. The deterministic STORE ZIP
uses only public tracked files and preserves executable bits.

Limits are 16 MiB per file, 128 MiB expanded total, 192 MiB archive size and 10,000
files. A future legitimate larger asset needs a reviewed policy change; the
packager fails closed instead of skipping it. Source files must be valid UTF-8
text without NUL bytes. Generated native binaries use the separate native gate.

The default source audit examines the index, including staged content. `--head`
examines the committed tree. `--history` requires a complete checkout and checks
all commits reachable from local refs, including deleted historical files; it is
bounded to 5,000 commits, 50,000 unique path/blob/mode entries and 1 GiB of scanned
history. CI fetches complete history and runs both the index and history guards.
This does not inspect unreachable Git objects, remote refs absent from the clone,
older separately distributed artifacts, or credentials outside tracked source.

Known secret values can optionally strengthen a local scan. Supply an existing
owner-only regular JSON file containing a string array, with each value at least
eight characters. The file must be no larger than 128 KiB and cannot be a symlink.
It is never copied into an archive, never printed, and is not required for CI or
ordinary public-source packaging:

```sh
node scripts/audit-public-source.mjs --history --known-secrets /private/comparison.json
node scripts/package-source.mjs --output ../CloudNest-source-reviewed.zip --known-secrets /private/comparison.json
```

Diagnostics show a rule label and escaped path, never matching file contents.
Known comparison values and recognizable token strings are redacted from paths.
Rules cover private bundle/config filenames, key material, major token formats,
configured OAuth clients, account/database IDs and literal credential fields.
Public `.example` configuration remains trackable and its contents are still
scanned. Ordinary hashes and synthetic record IDs are allowed. These checks are
a release boundary and defense in depth, not a guarantee that every unknown
credential format or sensitive document will be recognized. Review the committed
allowlist and the intended public content before release.

## Native ZIP and DMG scope

`build-mac.sh` audits the signed app before publishing it and creates its ZIP with
the same bounded archive writer and post-write audit. The allowlist contains only:

- `Contents/Info.plist`
- `Contents/MacOS/CloudNest`
- `Contents/Resources/CloudNest.icns`
- `Contents/_CodeSignature/CodeResources`

Additional app resources, symlinks, missing files and credential-pattern matches
block packaging. Executable bytes are scanned for credentials; compiler-embedded
home-directory strings are outside this binary audit's privacy claim. No build
folder, CLI-adjacent file or local setup bundle is recursively included.

`build-dmg.sh` verifies the signature, audits the original and copied app, then
checks the entire staging root. Its only extra members are the fixed
`Applications -> /Applications` link and scanned `READ ME.txt`. The DMG is created
in a separate temporary directory, verified, and then moved to its final path.
Existing native ZIP/DMG outputs are preserved under previous-output names.
These resource gates do not establish Developer ID signing, notarization, device
acceptance, reproducible compiler output or absence of every binary secret.

Older source archives were not produced by this boundary. Audit or replace each
intended distribution artifact separately. Running the new audit does not alter,
certify, delete or upload any pre-existing archive or private setup data.
