# Repository instructions

- Local snapshots only. Never push, force-push, reset hard, or rewrite user config.
- Snapshot engines must use a temporary Git index and must not run `git add`
  against the user's real index.
- Keep `#requires -Version 7.0` on PowerShell scripts and preserve the ASCII
  convention for engine scripts.
- Before changing snapshot behavior, run `tests/test_snapshot.ps1`.
