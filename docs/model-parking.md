# AI Model Parking

Model Parking reviews a selected local weights file, portable model export, or complete `~/.ollama/models` directory. It uses CloudNest's existing resumable, verified archive and restore queue. Drive stores inactive bytes; it does not run models. Restore and verify the weights locally before starting your runtime.

Quit Ollama, LM Studio and other model runtimes before preview, archive, cleanup or restore. CloudNest checks known runtime process names and bounded `lsof` results, including memory mappings, directory use and open files. Unknown or timed-out checks refuse the operation. These are point-in-time checks: keep runtimes closed until the operation completes. CloudNest never invokes a model CLI, runs downloaded code or starts/stops a runtime.

The native review shows file count, logical bytes and the selected location. Explicit archive approval rechecks the complete metadata inventory before handing it to the normal archive queue. Only a verified archive may later enter the separate cleanup flow. Restore requires an unused destination and never overwrites existing content. The application must persist each model archive job's purpose before transfer and apply `requireInactive` again to resume, cleanup and restore; the review component does not bypass the archive engine.

Ollama's `models` directory includes both blobs and manifests; preserve them together. Never select the parent `.ollama` directory, which can contain account identity keys. Generic model exports accept recognized weights and model metadata and reject private, temporary, lock or unrecognized files. Git repositories, protected directories, cloud placeholders, symbolic links and active databases retain the ordinary Storage safety policy. A nested directory named `library`, as used by Ollama manifests, is allowed; actual system and user Library roots remain protected.

Hugging Face cache snapshots commonly use symlinks and are refused. Create a portable export of regular weights and metadata using the provider's documented tools, then select that export. Do not select shared cache or credential roots. Models placed in active repositories must likewise be exported outside the repository first.

Inspection is cancellable, limited to 100,000 entries, and keeps metadata rather than weights in memory. Each process check has a five-second limit and one-MiB output limit. Existing archive size, integrity, metadata and quota checks still apply. No background polling or inference process is introduced.
