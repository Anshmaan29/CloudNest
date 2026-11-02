# Install CloudNest 1.0 release candidate

CloudNest requires macOS 14 or newer. Device acceptance currently covers Apple Silicon. The engineering candidate is locally ad-hoc signed; it is not Developer ID signed or notarized. A public consumer release remains gated on signing/notarization and a publisher-owned public Google Desktop OAuth client.

Open a supplied DMG, copy CloudNest to Applications, and launch the copied application through the normal macOS flow. A native ZIP contains the same app bundle. If macOS does not authorize this candidate, stop and obtain a Developer ID signed, notarized build. Do not disable Gatekeeper, clear quarantine attributes, or change system security settings.

The installed app uses system frameworks. Node, npm and Swift are source-build tools, not bundled runtime requirements. To build from source, install the supported Apple command-line toolchain, run `npm ci`, `npm run check`, then `npm run build:mac`. `bash scripts/build-dmg.sh` produces the candidate disk image. Release exports use resource allowlists and credential audits; do not ZIP the whole working folder.

## The eight-step setup

The setup guide saves its current step. **Save & close** leaves setup unfinished and returns to the app; open **Settings & Security → Open setup guide** to resume. It does not silently mark an interrupted archive or restore as successful. Existing 0.4 catalogs, preferences and Keychain grants are retained.

1. **Welcome.** Review the archive/recovery model. Opening setup grants no scan, upload, cleanup, notification or login-startup permission.
2. **Google Drive.** Reuse a saved Storage client and sign in in the system browser. Public sign-in is disabled with a reason when the app has no release client metadata. Advanced users can import their dedicated Desktop OAuth JSON, then sign in. A replacement requires confirmation; it disconnects the previous grant. A different Google project may not be able to access existing archives made with the original app's `drive.file` grant. Keep your original Storage client available and separate from Brain.
3. **Approved folders.** Choose a small disposable local folder. The folder picker explicitly approves its analysis; no upload starts. Scans stay inside approved folders. Built-in security exclusions and explicitly protected folders still apply. Repositories, active database storage and cloud placeholders may be excluded.
4. **Safety & recovery.** Protect additional folders, review separate cleanup approvals, and optionally change real network/power transfer settings. Existing preferences are preserved. Scheduling, login startup and notification permissions remain separate opt-in controls in Settings.
5. **Optional Brain.** Open the existing self-hosted Brain connection panel or skip it. A saved connection is not a server-availability check. Storage archive/restore does not need Brain, its owner credential, an LLM download or a paid model API.
6. **Your assistants.** Review the supported-client boundary. The MCP SDK and Codex CLI have verification evidence; hosted ChatGPT, Claude and Gemini still require client-specific validation. The wizard does not claim that any assistant is connected. Its context-note fallback copies only text you enter, for you to review and paste.
7. **First archive.** Select a small file inside an approved folder, explicitly approve the upload, and wait for the catalog entry to become verified. Verification checks remote file SHA-256/size and the recovery manifest. The original stays in place. A catalog job is retained before upload so interruption can resume. You can also select an existing verified file archive from the loaded catalog.
8. **Verified restore.** Choose a different destination. CloudNest downloads the real archive, verifies SHA-256 and size, and installs without overwriting an existing item. Setup finishes only after the restored bytes match that verified catalog archive. On resume, the saved restored file is checked again; a moved or changed copy requires another restore. No cleanup is performed by setup.

A failed or expired Google grant leaves the archive job resumable. Reconnect in the Google step, review any quota/network/power message, and resume. Optional Brain failures do not block file operations. Pausing retains the original and durable catalog identity; it does not promise that an already accepted remote upload was cancelled.

## Storage after setup

Archive Library supports file-job search, resumable uploads, health checks, and recovery from app-owned Drive manifests. Folder archives retain hierarchy, empty directories and a portable root manifest. File and folder restore can use their manifests without the original local catalog.

Both file and folder cleanup are available in 0.4 through managed recovery. Cleanup requires explicit local approval and fresh cloud verification. Moving an original into managed recovery retains its bytes locally; freeing that retained copy requires a separate removal approval. Put back works locally where the recovery state permits it. Partial folder cleanup may require a cloud restore into a new destination. Uploaded bytes and allocated-size estimates are not promises of SSD space saved.

Optional scans run only across approved folders while CloudNest is open. Optional login startup and low-storage notifications are controlled in Settings; enabling them is a separate user action, subject to macOS permission and registration results. The signed updater and recovery helper are implemented, but updates remain disabled until a reviewed publisher key, Developer ID identity and notarized release are available. See [signed updates](signed-updates.md).

## Public Google client: release gate and resource contract

No personal Storage or Brain client is embedded or reused by this change. Until the publisher supplies a suitable public release configuration, this remains an advanced/BYOC candidate, not consumer one-click onboarding.

Google treats installed Desktop apps as public clients. The existing authorization flow uses a fresh PKCE verifier/challenge, state validation, the system browser, and a short-lived IPv4 loopback callback. Google documents `client_secret` as optional for Desktop token requests; a bundled client ID is public metadata, not a confidential app secret. See [OAuth for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app).

Storage requests only `https://www.googleapis.com/auth/drive.file`, Google's recommended non-sensitive per-file scope. It covers files created by or opened with the app rather than all of Drive. Adding broad Drive scopes changes the verification obligations and is outside this resource contract. See [Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

The owner must create a **separate production project and Desktop client**, enable Drive API, configure the external consent audience and production publication, and complete applicable branding/policy requirements with owned domains, homepage and privacy information. Non-sensitive scope classification does not remove branding and production-policy obligations. See [production OAuth policy compliance](https://developers.google.com/identity/protocols/oauth2/production-readiness/policy-compliance) and [brand verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification).

The native loader accepts one optional resource at `CloudNest.app/Contents/Resources/CloudNestGoogleClient.json`, with exactly these keys:

```json
{
  "schemaVersion": 1,
  "clientID": "YOUR_PUBLIC_DESKTOP_CLIENT_ID.apps.googleusercontent.com"
}
```

The example is a placeholder, not usable credentials. The parser validates a real Google client ID and rejects unknown keys, provider endpoints, secrets and tokens. Configuration remains outside Git and is copied only from an explicitly supplied build input. Packaging must validate and allow this one optional resource **before codesigning**, while retaining the exact allowlist for every other resource. Copying an arbitrary resource directory, a downloaded personal OAuth JSON, or a working folder is not supported. The loader alone does not prove Google has approved a project; the publisher owns that release decision.

The default build contains no resource, keeps public sign-in visibly disabled, and preserves the existing import/sign-in route. Merely opening setup or loading a resource never replaces a saved Keychain client. Explicitly choosing a different release client uses the existing validated import transaction and warns about archive access continuity.

## Updates and uninstall

Finish or pause work, quit CloudNest, then replace the app. Keep Application Support state and Keychain items to resume transfers; retain independent portable manifests and your original Storage client. Review optional login startup in Settings rather than assuming it is enabled or disabled by an update.

Before uninstalling, put back retained recovery copies where possible, save recovery manifests, and decide separately whether to revoke Google access. Quit and remove the application. Removing the app alone does not remove cloud archives, catalog data, Keychain items or managed recovery copies. Review `~/Library/Application Support/CloudNest/` and Keychain service `org.cloudnest.os` yourself only if intentionally erasing local configuration. Preserve independent backups before removing recovery records.
