# Codebase map

All paths are under `public/scripts/`. Line numbers refer to the scripts as of commit `842de73` and will drift as the code changes. All four scripts set `$ErrorActionPreference = 'Stop'` and contain only ASCII characters.

## Files

| File | Runs on | Called by | Role |
| --- | --- | --- | --- |
| `Invoke-ChargebackWizard.ps1` | Orchestrator | Operator or Task Scheduler | Workspace, config, menu and stage dispatch. Contains the whole Collect stage. |
| `Get-DfsTargetMap.ps1` | Orchestrator | Wizard Discover | Builds the target map. Does not read file data. |
| `Install-FsrmOwnerReport.ps1` | Each file server | Wizard Collect, through a PSSession | Produces the owner-by-folder CSV with FSRM or an NTFS owner walk. |
| `Invoke-ChargebackMerge.ps1` | Orchestrator | Wizard Merge | Filters drop CSVs through the map, joins AD and writes the canonical CSV. |
| `dfs-targets.json` | (none) | (none) | Sample map with only `Server`, `LocalPath` and `Role`. Not read by any script. |
| `README.md` | (none) | (none) | Operator documentation. |

## Invoke-ChargebackWizard.ps1

**Parameters (L11-22):** `-Stage` (`Discover`, `Collect`, `Merge`, `All`; omit it for interactive mode), `-WorkspacePath`, `-NamespaceRoot`, `-BusinessUnitAttribute`, `-Engine` (`Auto` (default), `Fsrm` or `Ntfs`), `-Credential`, `-TimeoutSeconds` (default 3600).

| Function | Lines | Does |
| --- | --- | --- |
| `Initialize-Workspace` | 68-114 | Creates `input\json`, `input\drop` and `output`, and runs a write test. Returns paths, including `ConfigPath` and `MapPath`. |
| `Read-Config` / `Save-Config` | 116-131 | `input\json\config.json` holds `WorkspacePath`, `NamespaceRoot`, `BusinessUnitAttribute` and `UpdatedUtc`. It is rewritten on every run (L340). |
| `Resolve-SessionConfig` | 321-342 | The command-line values win, then config, then `Department` for the BU attribute. Interactive mode prompts for both. |
| `ConvertFrom-MapFile` / `Get-MapRows` | 53-66, 141-147 | Loads the map with `ConvertFrom-Json -InputObject` (avoids the PS 5.1 array-in-pipeline wrapping). |
| `Show-Map` | 149-164 | Prints the rows and the role counts. |
| `Invoke-DiscoverStage` | 166-202 | Runs Discover into `$env:TEMP\dfs-targets-<PID>.json`, then shows the map and warns on authoritative rows with no `LocalPath`. Interactive mode asks before saving; unattended mode always saves. Copies the file over `MapPath`. |
| `Get-CollectCredential` | 204-211 | Uses `-Credential` if passed, otherwise the current identity. Interactive mode offers `Get-Credential`. |
| `Invoke-CollectStage` | 213-300 | See [Collect](#collect-stage). |
| `Invoke-MergeStage` | 302-319 | Calls Merge to write `output\chargeback-<yyyy-MM-dd>.csv`, then copies it to `output\chargeback.csv`. |
| `Invoke-NamedStage` | 344-352 | Dispatches the stage. |

The menu (L389-416) uses a `$keepGoing` flag because `break` inside `switch` does not leave the loop in PS 5.1.

### Collect stage

`Invoke-CollectStage` (L213-300):

1. Selects map rows where `Role = authoritative` and `LocalPath` is non-empty. It throws if there are none (L217-220).
2. Groups them by `Server`. For each server it:
   - opens `New-PSSession -ComputerName <Server>` (the `Server` value is the uppercased host part of the DFS `TargetPath`);
   - creates `C:\ProgramData\ChargebackOne\drop` on the remote host;
   - copies the collector to `C:\ProgramData\ChargebackOne\Install-FsrmOwnerReport.ps1`;
   - runs it with `-Namespace <unique LocalPaths> -OutputPath <remote drop> -TimeoutSeconds -Engine -Server`;
   - copies **every** `*.csv` in the remote drop folder to `input\drop\<Server>-<name>.csv`.
3. A failure on one server is caught. The stage warns and moves on to the next server, and throws only if every server failed (L285-299).

## Get-DfsTargetMap.ps1 (Discover)

**Parameters (L11-17):** `-NamespaceRoot`, `-OutputPath`, `-LocalNamespacesPath`, `-NonWindowsNameHint` (default `synology`, `syno`, `nas-syno`), `-ThisComputerOnly`. The wizard passes only `-NamespaceRoot` and `-OutputPath`. The other parameters work only when you run the script directly.

**Dependencies:** the `DFSN` module (required, L53-61) and the `DFSR` module (optional, L62-65).

Flow:

1. **DFSR primaries (L114-132).** For each replication group it maps `FolderName` to the group's `PrimaryMember` computer names. Any exception here disables DFSR use.
2. **Folders (L141-158).** `Get-DfsnFolder -Path <root>\*`, then `Get-DfsnFolderTarget` for each folder. A failure warns and skips that root or folder. Namespace root targets are not queried.
3. **Per target (L165-189):**
   - The host comes from `\\host\` in `TargetPath`.
   - If the host name contains a non-Windows hint, the target is non-Windows.
   - Otherwise `Test-WindowsCim` (L104-112) runs `Get-CimInstance Win32_OperatingSystem -ComputerName <host>`. **Any exception** makes the target non-Windows.
   - For Windows targets, `Get-LocalPathFromUnc` (L91-102) runs `Get-SmbShare -CimSession <host> -Name <share>` and returns `.Path`, joined with any sub-path after the share. Any exception returns `$null`. An empty `Path` also ends up as no `LocalPath`.
4. **Authoritative pick per folder (L191-217).** With one Windows target, that target wins. With several, a DFSR primary whose name equals the target `Server` wins. Otherwise the targets are ranked by referral priority class, then rank, preferring `State = Online`, with a warning. Every other Windows target becomes `replica`.
5. **Non-Windows rows (L230-238)** get `Role = phase3-synology`, and `LocalPath` is set to the UNC `TargetPath`.
6. Writes the map as hand-built JSON (`ConvertTo-ChargebackJson`, L22-46) in ASCII. Optionally writes `-LocalNamespacesPath`, a JSON array of this host's authoritative local paths. It prints the role counts.

No other source of `LocalPath` exists in code: no registry read and no override file. The only alternative is editing the saved map by hand.

## Install-FsrmOwnerReport.ps1 (collector)

**Parameters (L10-21):** `-Namespace` (local paths), `-LocalNamespacesPath`, `-ReportName` (`Chargeback-FilesByOwner`), `-OutputPath` (`C:\ProgramData\ChargebackOne\drop`), `-Server`, `-Engine`, `-TimeoutSeconds`, `-MaxOwner` (10000), `-MaxFile` (1000000).

Flow:

1. **Path check (L154-168).** `Resolve-ExistingPath` (L55-82) tries, in order: the exact path; an SMB share whose `Path` equals it; a share named after the leaf whose `Path` exists; parent plus leaf; and the same path on `C:`, `D:` or `E:`. Any path still missing makes it print `Get-PSDrive` and `Get-SmbShare` output and throw. The walk uses the resolved path, but the output CSV keeps the map path in `Folder` so that Merge can match it.
2. **Engine (L170-180).** For `Auto`, a local `Win32_OperatingSystem.BuildNumber` between 1 and 14393 selects `Ntfs`. Anything else, **including 0 when the CIM query fails**, selects `Fsrm`.
3. **`Ntfs` (L186-190 then L84-147).** For each path it runs `Get-ChildItem -Recurse -Force -File -ErrorAction SilentlyContinue` and collects everything into one array. For each file it reads `GetAccessControl().Owner` and translates it to a SID. It accumulates `Size` (`Length`) and `Files` per owner and folder. It writes `ntfs-owner-<Server>.csv` with the columns `Server, Folder, Owner, SID, Size, Files`. With zero files it writes one placeholder `UNKNOWN` row.
4. **`Fsrm` (L192-359):**
   - If `Get-WindowsFeature FS-Resource-Manager` is not installed, it runs **`Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools`** (L192-199).
   - Starts `SrmSvc` and `SrmReports` if they are stopped.
   - Creates `C:\StorageReports\{,Interactive,Scheduled,Incident}`.
   - Runs `Set-FsrmSetting` for `ReportLimitMaxOwner`, `ReportLimitMaxFile` and every `ReportLocation*` parameter it finds, pointing them at `OutputPath`. These are server-wide FSRM settings.
   - Removes any existing report job named `ReportName`.
   - Creates a placeholder `New-FsrmScheduledTask` (weekly, Sunday 03:00), then calls `New-FsrmStorageReport` with that schedule and `Start-FsrmStorageReport`.
   - Polls every 5 s for new `.csv`, `.html` or `.xml` files under `OutputPath` and `C:\StorageReports`, and copies new CSVs into `OutputPath`.
   - Falls back to the NTFS walk if report creation throws, if no CSV appears within **45 s** (L340-346), or if the timeout ends empty. It throws if FSRM reports `NotRunning` with a `LastError` after 30 s.

## Invoke-ChargebackMerge.ps1 (Merge)

**Parameters (L7-16):** `-DropFolder`, `-TargetMapPath`, `-OutputPath` (all mandatory), `-BusinessUnitAttribute` (`Department`), `-ScanDate`.

**Dependency:** the `ActiveDirectory` module. It is imported at L19, before anything else runs.

1. Loads the map (`Get-MapObjects`, L46-68, which flattens nested arrays) and prints each row. It builds the allow-set key `Server|LocalPath` from authoritative rows, and throws if the set is empty (L70-88).
2. For every `*.csv` directly in `DropFolder` (not recursive), it does the following for each row:
   - `Server` = the `Server` column, otherwise the file base name; `path` = `Folder`, then `Path`, then `Namespace`. Rows whose key is not in the allow-set are dropped silently.
   - Owner = `Owner`, then `Owner Name`. SID = the local `NTAccount.Translate` result, otherwise the `SID` column.
   - Bytes = the first non-empty value of `Size`, `File Size`, `LogicalSize` or `Total File Size`, **with all non-digit characters removed**. Files = the `Files` column.
   - Owners ending in `SYSTEM` or `Administrators` get those values in `Unresolved` and are not looked up. Everyone else goes through `Get-ADUser -Filter "SID -eq '<sid>'"`, then `Get-ADUser -Identity <owner>`. No match gives `Unmapped`.
3. Writes one output row per input row (no aggregation), UTF-8, with these columns: `ScanDate, Source, Server, SharePath, OwnerSID, SamAccountName, DisplayName, Department, BusinessUnit, FileCount, LogicalBytes, AllocatedBytes, Unresolved`. `Source` is always `Windows-FSRM-Owner`. `AllocatedBytes` is a copy of `LogicalBytes`. `Department` is always the AD `Department` value; `BusinessUnit` is the chosen attribute.

## Data contracts

| Artefact | Writer | Reader | Fields that matter |
| --- | --- | --- | --- |
| `input\json\config.json` | Wizard | Wizard | `NamespaceRoot`, `BusinessUnitAttribute`. No secrets. |
| `input\json\dfs-targets.json` | Discover (via a temp file) | Wizard Collect, Merge | `Server` (uppercase), `LocalPath`, `Role`; also `NamespacePath`, `TargetPath`, `State`. |
| Remote `C:\ProgramData\ChargebackOne\drop\*.csv` | Collector, or FSRM | Wizard Collect | NTFS: `Server, Folder, Owner, SID, Size, Files`. FSRM: whatever FSRM writes. |
| `input\drop\<Server>-*.csv` | Wizard Collect | Merge | The `Server` and `Folder` values must equal the map's `Server` and `LocalPath`. |
| `output\chargeback*.csv` | Merge | Downstream | The canonical schema above. |

The FSRM column names Merge accepts (`Owner Name`, `File Size`, `Total File Size`, `Path`, `Namespace`) are guesses in code. No FSRM sample output or fixture in the repo confirms them (see [limitations](development.md#known-limitations)).

## Extension points

| Change | Where |
| --- | --- |
| Treat more hosts as non-Windows | `-NonWindowsNameHint` (not passed through by the wizard) or `Test-LikelyNonWindows`. |
| Classify CIM failures separately from name-hinted non-Windows targets | `Get-DfsTargetMap.ps1` L171-188 and L230-238. Also update `Show-Map` counts and the Role table in the operator README. |
| Add another `LocalPath` source (override file, other lookup) | After `Get-LocalPathFromUnc` at L175. Keep `LocalPath` equal to what the collector writes in `Folder`. |
| Authoritative selection rules | `Get-DfsTargetMap.ps1` L191-217. |
| Add an engine or an FSRM opt-out | The `-Engine` `ValidateSet` in both the wizard (L18) and the collector (L16), plus the branch at collector L172-190 and the install block at L192-199. |
| New collector CSV format | Merge column fallbacks at L97-115. The key must stay `Server|Folder` equal to `Server|LocalPath`. |
| AD attributes or caching | Merge L122-142. |
| Output columns | Merge L144-164. |
| New stage | Add it to the `-Stage` `ValidateSet`, the `$order` array (L376), `Invoke-NamedStage` and the menu. |
