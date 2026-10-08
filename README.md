# Codex Project Recovery (Windows)

Community workaround for **Codex Desktop projects disappearing from the sidebar after an update** when project records still exist in the local SQLite database.

> [!WARNING]
> **Experimental and unofficial.** Not affiliated with or supported by OpenAI. Codex's internal files may change without notice. Review this script carefully and back up your data before applying any repair. The generalized script has **not been tested end-to-end across different Windows installations or Codex versions**.

## Confirmed recovery (October 8, 2026)

In one affected Windows installation, SQLite retained **10 projects**, **10 project roots**, **10 legacy-ID mappings**, and **110 threads**. The sidebar JSON had only **1 project**. Its migration flags were `projectsMigrated=true` and `threadAssignmentsMigrated=false`.

The missing nine project entries were reconstructed using surviving SQLite project records and original legacy IDs. **All ten projects and their historical conversations returned** after restarting Codex. SQLite was not modified.

The manual fix succeeded. The generalized script below has not been independently validated on other machines.

Related upstream issue: [openai/codex#42739](https://github.com/openai/codex/issues/42739).

## Requirements

- Windows PowerShell 5.1 or later
- Codex's state directory (normally `%USERPROFILE%\.codex`)
- `sqlite3.exe` installed and in `PATH`, or supplied with `-SqliteExe`
- Codex and ChatGPT completely closed (including background processes)

## Usage

Download and review [Repair-CodexProjects.ps1](./Repair-CodexProjects.ps1) before running it.

```powershell
# Diagnose only: no files modified
.\Repair-CodexProjects.ps1

# If sqlite3.exe is not on PATH
.\Repair-CodexProjects.ps1 -SqliteExe 'C:\path\to\sqlite3.exe'

# Apply after reviewing diagnosis and closing all Codex/ChatGPT processes
.\Repair-CodexProjects.ps1 -Apply -SqliteExe 'C:\path\to\sqlite3.exe'

# Restore the original JSON from the backup created by -Apply
.\Repair-CodexProjects.ps1 -Rollback -BackupFolder 'C:\path\to\Codex-project-recovery-YYYYMMDD-HHMMSS-xxxxxxxx'
```

The default run is read-only. The `-Apply` operation asks for an explicit `APPLY` confirmation. Rollback likewise asks for `ROLLBACK`.

Do not disable PowerShell security protections system-wide simply to run this tool.

## What it does

1. Checks the local SQLite project records, root paths and legacy-ID mappings against the JSON `local-projects` index.
2. Checks that required IDs, directories and expected JSON structure exist.
3. On explicit apply, backs up `.codex-global-state.json` and `state_5.sqlite` (plus existing WAL/SHM files).
4. Adds missing project definitions and restores project order, preserving unrelated JSON properties.
5. Verifies the written JSON and provides the backup folder path for rollback.

**Does not** modify SQLite, alter migration flags, create replacement project IDs, or reconstruct thread assignments manually.

## Limitations

- Works only with the internal schema assumed by this experimental version. If the checks fail, do not force the repair.
- An inconsistent or incomplete SQLite database may not be recoverable this way.
- Restoring a prior JSON can overwrite changes made since the backup; close the app and assess before rollback.
- Never post your private Codex JSON or SQLite files publicly: they may include private paths or project metadata.
- The script needs further Windows integration testing and external user verification.

## License

MIT. See [LICENSE](./LICENSE).
