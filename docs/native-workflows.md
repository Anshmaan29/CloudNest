# Native workspace workflows

The native app now includes Free Up Space, Activity, Recovery Center, a setup
guide and a command palette. These use the existing verified archive engine.
They do not introduce a separate filesystem, local model or permanent helper.

## Free Up Space

Approve folders through the native picker. Analyze approved folders to rank
eligible files using size and modification age. Ancestor roots and hard links
are deduplicated across scans. The combined result has a 10,000-file budget;
a truncated result is labelled incomplete. The first 200 candidates are shown
for review and only those displayed, nonexcluded candidates can be uploaded
in a batch. Upload retains every original. Scanning does not prove inactivity.

Allocated bytes are an estimate, separate from the historical observed
filesystem free-space increase during explicitly approved managed removal.
Category totals cover eligible scan matches rather than the entire SSD.
Custom extension/folder-name exclusions affect recommendations; protected
folders and built-in file-operation exclusions independently enforce safety.

## Transfers and scheduling

Transfer policies are off by default. Opt in to external-power requirements,
Low Power Mode pauses, expensive/Low Data Mode network restrictions, average
upload pacing and bounded transient retries. System network notifications are
used; there is no active connectivity probe or idle polling loop. Conditions
are checked at requests/chunk boundaries, not continuously during a chunk.
Downloads are checked before starting. Network conditions can change afterward.

Upload pacing bounds the average payload rate with chunk bursts; it is not a
packet-level bandwidth shaper. Retries of a failed upload chunk first ask the
server for its accepted offset. Metadata reads/status checks retry only known
transient failures. Non-idempotent manifest creation and downloads are not
blindly retried. A policy refusal leaves the job available for manual Resume.

Scheduled recommendation scans require explicit opt-in and approved roots.
One cancellable deadline runs while the app is open. No login helper is added;
overdue work is checked when CloudNest next opens. Scheduling never authorizes
upload or cleanup. Low-storage notifications separately request macOS permission
when enabled, contain no filenames/paths, and are limited to one per day while
the application is running. In-app warnings use measured disk capacity.

## History and selected-file integration

Activity is a private persistent SQLite ledger of actions observed by this
version. It does not invent older completion timestamps. The archive catalog
remains authoritative for transfer/recovery state. Activity pages are bounded;
verified event identities are deduplicated. CLI and native workflows share the
same ledger and protected-folder preference domain.

The command palette is Command-K; archive search is Command-F; Free Up Space
is Command-Shift-U. File/folder drops are reviewed before any operation. A
single-file drop does not approve its parent for future scheduled scanning.
Archive context menus open or copy existing Drive URLs without changing Google
permissions or putting credentials into URLs.

Finder Services use the public macOS Services provider API. The release bundle
must advertise Archive with CloudNest and Restore with CloudNest, and be installed
in Applications. Availability in Finder depends on system Services registration
and user settings; compiling the provider is not proof of menu availability.
Both services accept one local selection and route through native confirmation
and the existing source/restore safety checks. No private pbs interface, custom
filesystem or manipulation of Google Drive caches is used.

Apple Services implementation reference:
https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html
