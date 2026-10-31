# Filesystem workflow test isolation

The Swift workflow fixtures use fresh UUID directories ending in `.noindex`. Their contents remain real local files: uploads, recovery renames, explicit unlinks, restores, SQLite catalogs, Git snapshots, and fake Docker CLI streams still exercise the ordinary production implementations. No global Spotlight configuration is changed.

This avoids an observed source of intermittent cleanup-test failures. Diagnostic `lsof -Fpcn` output identified macOS `mdworker_shared` holding a generated folder member while a test attempted cleanup. Refusing that operation was correct. A standalone Foundation subprocess probe did not show unrelated descriptor inheritance, so changing Docker subprocess behavior would not address the reproduced cause.

Apple's [debug-symbol troubleshooting documentation](https://developer.apple.com/documentation/xcode/locating-a-missing-debug-symbol-file) identifies `.noindex` in a directory path as a reason Spotlight cannot find its contents. Naming only generated fixture roots this way prevents the indexer from becoming an incidental test participant. Real user folders retain their normal indexing behavior.

Production `FileSafety.requireUnused` is unchanged: it rejects other processes, including system indexing processes. The explicit external-reader test still opens a fixture through a separate `tail` process and verifies that cleanup is refused. Tests retain their parallel execution and do not suppress failures, retry cleanup blindly, or whitelist process names.
