#Requires -Version 5.1
<#
.SYNOPSIS
  Diagnose and optionally rebuild missing Codex Windows project-sidebar entries.
.DESCRIPTION
  Uses the existing SQLite project records and legacy-ID mappings to add absent
  entries to .codex-global-state.json. Does NOT edit SQLite or thread assignments.
  Default: read-only diagnosis. -Apply: backup + replace JSON. -Rollback: restore
  the original JSON from a recovery backup directory.
  Community workaround; not an official OpenAI repair utility.
.EXAMPLE
  .\Repair-CodexProjects.ps1 -SqliteExe 'C:\path\to\sqlite3.exe'
.EXAMPLE
  .\Repair-CodexProjects.ps1 -Apply -SqliteExe 'C:\path\to\sqlite3.exe'
.EXAMPLE
  .\Repair-CodexProjects.ps1 -Rollback -BackupFolder 'C:\Users\me\Codex-project-recovery-20261008-123000-abc12345'
#>
[CmdletBinding(DefaultParameterSetName = 'Diagnose')]
param(
    [Parameter(ParameterSetName = 'Diagnose')]
    [switch]$DryRun,

    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [switch]$Apply,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch]$Rollback,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [string]$BackupFolder,

    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }),
    [string]$SqliteExe
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing JSON file: $Path"
    }
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $obj -or $null -eq $obj.PSObject.Properties['local-projects'] -or
        $null -eq $obj.PSObject.Properties['project-order']) {
        throw 'Unknown JSON layout: expected local-projects and project-order.'
    }
    if ($obj.'local-projects' -isnot [pscustomobject] -or
        $obj.'project-order' -isnot [array]) {
        throw 'Unexpected JSON types; no changes made.'
    }
    return $obj
}

function Assert-AppClosed {
    $running = @(Get-Process -Name 'Codex', 'ChatGPT' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw 'Close Codex and ChatGPT completely (including background processes), then retry.'
    }
}

function Write-AtomicJson([string]$Destination, [object]$State, [string]$PreviousVersionPath) {
    $dir = Split-Path -Parent $Destination
    $temp = Join-Path $dir ('.codex-project-recovery-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $serialized = ConvertTo-Json -InputObject $State -Depth 100
        [System.IO.File]::WriteAllText($temp, $serialized, (New-Object System.Text.UTF8Encoding($false)))
        $parsed = Read-State $temp
        if ($null -eq $parsed) { throw 'JSON validation failed.' }
        # Compare every unrelated top-level setting, including thread assignments.
        $before = Read-State $Destination
        foreach ($property in $before.PSObject.Properties) {
            if ($property.Name -in @('local-projects','project-order')) { continue }
            $counterpart = $parsed.PSObject.Properties[$property.Name]
            if ($null -eq $counterpart) { throw "JSON round-trip dropped $($property.Name)." }
            $oldValue = ConvertTo-Json -InputObject $property.Value -Depth 100 -Compress
            $newValue = ConvertTo-Json -InputObject $counterpart.Value -Depth 100 -Compress
            if ($oldValue -cne $newValue) { throw "JSON round-trip changed $($property.Name)." }
        }
        # Windows: replace the existing destination and save its exact previous bytes.
        [System.IO.File]::Replace($temp, $Destination, $PreviousVersionPath)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$jsonFile = Join-Path $CodexHome '.codex-global-state.json'
$sqliteFile = Join-Path $CodexHome 'state_5.sqlite'

if ($Rollback) {
    Assert-AppClosed
    $savedJson = Join-Path $BackupFolder '.codex-global-state.json'
    $beforeRollback = Join-Path $BackupFolder ('before-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $null = Read-State $savedJson
    $null = Read-State $jsonFile
    $reply = Read-Host 'Type ROLLBACK to restore the saved JSON (current JSON will also be backed up)'
    if ($reply -cne 'ROLLBACK') { throw 'Cancelled; no changes made.' }
    $copy = Join-Path $CodexHome ('.codex-rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $savedJson -Destination $copy -ErrorAction Stop
        [System.IO.File]::Replace($copy, $jsonFile, $beforeRollback)
    } finally {
        if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force }
    }
    Write-Host "ROLLBACK COMPLETE. Previous current JSON saved to: $beforeRollback" -ForegroundColor Green
    return
}

# Require a closed application for a stable SQLite + WAL snapshot.
Assert-AppClosed
$state = Read-State $jsonFile
if (-not (Test-Path -LiteralPath $sqliteFile -PathType Leaf)) {
    throw "Missing SQLite database: $sqliteFile"
}

if ([string]::IsNullOrWhiteSpace($SqliteExe)) {
    $exe = Get-Command sqlite3.exe, sqlite3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $exe) { throw 'sqlite3.exe not found. Supply -SqliteExe with its full path.' }
    $SqliteExe = $exe.Source
}
if (-not (Test-Path -LiteralPath $SqliteExe -PathType Leaf)) {
    throw "Cannot find sqlite3.exe: $SqliteExe"
}

function Invoke-SqliteCsv([string]$Sql) {
    $oldConsoleEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $output = @(& $SqliteExe -readonly -csv -header $sqliteFile $Sql 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ("SQLite query failed: " + ($output -join ' '))
        }
        return @($output | ConvertFrom-Csv)
    } finally {
        [Console]::OutputEncoding = $oldConsoleEncoding
    }
}

# Fail closed if any project lacks a legacy ID or a project root.
$stats = @(Invoke-SqliteCsv @'
SELECT (SELECT COUNT(*) FROM projects) AS projects,
       (SELECT COUNT(DISTINCT project_id) FROM project_idempotency_keys) AS mapped,
       (SELECT COUNT(DISTINCT project_id) FROM project_roots) AS rooted;
'@)
if ($stats.Count -ne 1) { throw 'Unexpected SQLite counts result.' }
$total = [int]$stats[0].projects
if ($total -lt 1 -or [int]$stats[0].mapped -ne $total -or
    [int]$stats[0].rooted -ne $total) {
    throw 'Some SQLite projects have no legacy-ID mapping or root; refusing automatic reconstruction.'
}

$rows = @(Invoke-SqliteCsv @'
SELECT p.id AS core_id, p.name, p.position,
       k.key AS legacy_id, r.path AS root_path, r.position AS root_position,
       p.created_at_ms, p.updated_at_ms
FROM projects p
JOIN project_idempotency_keys k ON k.project_id = p.id
JOIN project_roots r ON r.project_id = p.id
ORDER BY p.position, r.position;
'@)

$groups = @($rows | Group-Object core_id | Sort-Object { [int]$_.Group[0].position })
if ($groups.Count -ne $total) { throw 'Ambiguous project mappings in SQLite.' }

$projects = @()
foreach ($group in $groups) {
    $gRows = @($group.Group | Sort-Object { [int]$_.root_position })
    $legacyIds = @($gRows | ForEach-Object { $_.legacy_id } | Select-Object -Unique)
    if ($legacyIds.Count -ne 1 -or [string]::IsNullOrWhiteSpace($legacyIds[0])) {
        throw "Ambiguous legacy ID for core project $($group.Name)."
    }
    $paths = @($gRows | ForEach-Object { $_.root_path } | Select-Object -Unique)
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Project root no longer exists: $path"
        }
    }
    $projects += [pscustomobject]@{
        Id        = [string]$legacyIds[0]
        Name      = [string]$gRows[0].name
        RootPaths = $paths
        CreatedAt = [long]$gRows[0].created_at_ms
        UpdatedAt = [long]$gRows[0].updated_at_ms
    }
}
if (@($projects | ForEach-Object { $_.Id } | Select-Object -Unique).Count -ne $total) {
    throw 'Duplicate legacy project IDs; no changes made.'
}

$local = $state.'local-projects'
$existingEntries = @($local.PSObject.Properties)
if ($existingEntries.Count -gt 0) {
    $template = $existingEntries[0].Value
    foreach ($field in @('id','name','rootPaths','createdAt','updatedAt')) {
        if ($null -eq $template.PSObject.Properties[$field]) {
            throw "Existing JSON project lacks '$field'; schema unsupported."
        }
    }
    if ($template.rootPaths -isnot [array] -or
        $template.createdAt -isnot [ValueType] -or
        $template.updatedAt -isnot [ValueType]) {
        throw 'Existing JSON project has an unsupported rootPaths/date representation.'
    }
} else {
    Write-Warning 'The JSON project index is entirely empty. Using the observed 2026 Windows project schema; review carefully.'
}

$missing = @($projects | Where-Object { $null -eq $local.PSObject.Properties[$_.Id] })
foreach ($p in $projects) {
    $existing = $local.PSObject.Properties[$p.Id]
    if ($null -ne $existing -and $existing.Value.id -ne $p.Id) {
        throw "Existing JSON project ID does not match its key: $($p.Id)"
    }
}

Write-Host "SQLite projects: $total; JSON entries: $($existingEntries.Count); missing from JSON: $($missing.Count)" 
$projects | Select-Object Name, @{N='InJson';E={ $null -ne $local.PSObject.Properties[$_.Id] }} |
    Format-Table -AutoSize

if (-not $Apply) {
    Write-Host 'DRY RUN ONLY. No files changed. Run again with -Apply to repair.' -ForegroundColor Cyan
    return
}
if ($missing.Count -eq 0) {
    Write-Host 'Nothing to repair. No files changed.'
    return
}

$reply = Read-Host "Type APPLY to add $($missing.Count) project(s) to the Codex JSON index"
if ($reply -cne 'APPLY') { throw 'Cancelled; no changes made.' }

# Snapshot complete pre-repair state (including SQLite WAL/SHM if present).
$backup = Join-Path (Split-Path -Parent $CodexHome) ('Codex-project-recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
foreach ($filename in @('.codex-global-state.json','state_5.sqlite','state_5.sqlite-wal','state_5.sqlite-shm')) {
    $from = Join-Path $CodexHome $filename
    if (Test-Path -LiteralPath $from -PathType Leaf) {
        Copy-Item -LiteralPath $from -Destination (Join-Path $backup $filename) -ErrorAction Stop
    }
}

foreach ($p in $missing) {
    $entry = [pscustomobject]@{
        id        = $p.Id
        name      = $p.Name
        rootPaths = @($p.RootPaths)
        createdAt = $p.CreatedAt
        updatedAt = $p.UpdatedAt
    }
    $local | Add-Member -MemberType NoteProperty -Name $p.Id -Value $entry
}

# Keep original SQLite ordering, followed by any JSON-only entries (never discard).
$order = @($projects | ForEach-Object { $_.Id })
foreach ($id in @($state.'project-order')) {
    if ($order -cnotcontains $id) { $order += $id }
}
$state.'project-order' = $order

$beforeReplace = Join-Path $backup 'pre-replace-extra-copy.json'
Write-AtomicJson -Destination $jsonFile -State $state -PreviousVersionPath $beforeReplace

$confirmed = Read-State $jsonFile
foreach ($p in $projects) {
    if ($null -eq $confirmed.'local-projects'.PSObject.Properties[$p.Id]) {
        throw "Post-write validation failed for $($p.Name). Restore from backup: $backup"
    }
}
Write-Host "SUCCESS: $($missing.Count) project(s) added. Total JSON projects: $(@($confirmed.'local-projects'.PSObject.Properties).Count)" -ForegroundColor Green
Write-Host "Backup folder for -Rollback: $backup"
Write-Host 'Now launch Codex and verify both the sidebar and old conversations.'