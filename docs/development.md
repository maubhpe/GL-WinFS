# Development guide

Statements here are labelled by how far they have been checked:

- **Code**: read directly from the scripts at `842de73`.
- **Inferred**: follows from the code but has not been run or observed.
- **Observed**: seen when the pack was run in a deployment. It has not been reproduced in a controlled test.

Nothing here has been verified by an automated test in this repository.

## Verification facilities

The repository contains no tests, Pester suites, linters, CI workflows or fixtures. The only files that do any checking are the scripts' own runtime messages and throws.

These static checks need nothing beyond the repo and a shell:

| Check | How |
| --- | --- |
| Scripts stay ASCII-only (the operator README says PS 5.1 needs this) | `grep -nP '[^\x00-\x7F]' public/scripts/*.ps1` should print nothing. |
| Sample map is valid JSON | `python3 -m json.tool public/scripts/dfs-targets.json` |
| PowerShell syntax (needs PowerShell on the machine) | `[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs)` for each script, then check that `$errs` is empty. This parses only; it executes nothing. |

## Safe validation plan

Work through these steps in order and stop at the first that fails. Only step 1 can be performed without Windows or connected infrastructure. Steps 2-6 require an isolated Windows/domain lab with the relevant services.

1. **Static checks**, as above.
2. **Merge alone, offline from the file servers.** On a domain-joined test host with RSAT AD, hand-write a small map and a drop CSV in the NTFS format (`Server, Folder, Owner, SID, Size, Files`). Then run `Invoke-ChargebackMerge.ps1` directly. Check that the allow-set filtering, the `Unresolved` values and the output columns are right. This reads AD and writes only to the output path you give it.
3. **Discover on a lab namespace.** Run the wizard with `-Stage Discover` against a test DFS root. Discover writes only to the workspace. It performs read-only CIM and DFS queries against the targets. Check the roles and `LocalPath` values in the printed map.
4. **Collect with `-Engine Ntfs` on one lab server** that holds a small test share. Check that the CSV comes back and that its `Folder` matches the map.
5. **Collect with `-Engine Fsrm`** only on a lab server where the side effects listed below are acceptable.
6. **End-to-end with `-Stage All`** on the lab, starting from an empty `input\drop`.

Record which Windows Server and PowerShell versions each step ran on. The operator README states it was tested on Server 2016 with PowerShell 5.1. No test record for 2019 or 2022 exists in this repository.

## Access the code currently needs

The scripts do not configure or check permissions. The table lists the operations each stage performs. For the account behind them, the operator README currently states: read access to DFS configuration and AD users, and local administrator on each file server for Collect. No least-privilege configuration has been tested, and this guide does not recommend one. See [permissions](permissions.md) for the per-script details.

| Stage | Runs as | Operations (Code) |
| --- | --- | --- |
| Discover | The wizard's identity on the orchestrator | Local DFSN/DFSR cmdlets. Remote `Get-CimInstance Win32_OperatingSystem` and `Get-SmbShare -CimSession` to each target. Writes `$env:TEMP` and the workspace. |
| Collect | The current identity, or `-Credential` | `New-PSSession` to each authoritative server. On that server: create a directory, copy a file to `C:\ProgramData\ChargebackOne\`, run the collector, and read all files under each `LocalPath`. The FSRM engine adds a feature install, service starts and FSRM setting and job changes. Writes `input\drop`. |
| Merge | The wizard's identity on the orchestrator | Read the workspace. `Get-ADUser` by SID or name, with the BU attribute, `DisplayName`, `Department` and `SamAccountName`. Write `output`. |

Points that affect access:

- **`LocalPath` depends on `Get-SmbShare` returning `Path`.** (Observed) Some accounts can enumerate shares and query `Win32_OperatingSystem` but get a blank `Path`, so Discover writes no `LocalPath` and Collect skips the target. Which minimum rights return `Path` has not been established here.
- **CIM failure is not reported as a failure.** (Code) Any exception from the OS query, for example access denied or a timeout, tags the target `phase3-synology`. The resulting map looks the same as one for a real non-Windows target.
- **The NTFS walk does not enable backup privilege.** (Code) It runs with the session's token and uses `-ErrorAction SilentlyContinue`. It skips any file or folder the identity cannot read, and it does not count or report the skips. Being a local administrator does not by itself guarantee that every file can be read; that depends on the ACLs. (Inferred)
- **No double hop.** (Code) The collector reads local paths only, so it needs no CredSSP or delegation.

## Known limitations

| # | Limitation | Basis |
| --- | --- | --- |
| 1 | **The FSRM engine installs a Windows feature.** `Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools` runs whenever FSRM is selected and the feature is missing. No switch turns this off. | Code |
| 2 | **Other FSRM side effects:** it starts `SrmSvc` and `SrmReports`; changes server-wide `Set-FsrmSetting` report limits and report locations; deletes and recreates the `Chargeback-FilesByOwner` job; creates `C:\StorageReports\*`. It attaches a weekly Sunday 03:00 schedule to that job and does not remove the job afterwards. Whether FSRM then runs the job every week has not been checked. | Code, plus Inferred for the weekly runs |
| 3 | **`-Engine Ntfs` avoids the FSRM steps in items 1-2**, because the NTFS branch returns before them. It does not avoid the other effects: the PSSession, files under `C:\ProgramData\ChargebackOne\`, and full recursive read I/O across each share. `Auto` selects FSRM on 2019/2022, and also whenever the local build lookup fails. | Code |
| 4 | **FSRM rarely gets much time.** With no CSV after 45 s the collector falls back to the NTFS walk, so `-TimeoutSeconds` matters only if FSRM finishes inside that window. The started FSRM job is not stopped and may keep running alongside the walk. | Code; Inferred for the concurrent run |
| 5 | **Stale CSVs can be merged.** Collect copies every CSV in the remote drop folder, and Merge reads every CSV in `input\drop`. Neither folder is cleared, so files from earlier runs or late FSRM output can be counted again. | Code; Inferred for double counting |
| 6 | **The FSRM CSV path into Merge is unverified.** The column fallbacks are guesses. If an FSRM CSV has no `Server` column, Merge falls back to the file base name (`<Server>-<file>`), which never matches the map, and drops those rows silently. Size strings are reduced to their digits, so a value with units or decimals would be wrong. | Code; Inferred for the effect |
| 7 | **The NTFS walk loads every file under a share into memory** before aggregating. Large trees may be slow or memory-heavy. | Code; Inferred for the effect |
| 8 | **Discover queries each target separately.** It opens new CIM connections for every target, with no per-server cache. Unreachable hosts cost a CIM timeout each. | Code; Inferred for the effect |
| 9 | **DFSR primaries are matched by group and name.** Every primary in a replication group is applied to every replicated folder in it. The key is the DFS folder leaf, and the comparison is an exact name match against the map's `Server`. Short-name versus FQDN differences fall through to referral priority. | Code |
| 10 | **Only one folder level is queried.** Discover reads folder targets from `Get-DfsnFolder <root>\*`. Root targets are not queried, and behaviour with nested folders has not been checked. | Code; nested folders untested |
| 11 | **Merge output is not aggregated or fully attributed.** It writes one row per input row and calls `Get-ADUser` for each row without caching. `Source` is always `Windows-FSRM-Owner`, and `AllocatedBytes` equals `LogicalBytes`. | Code |
| 12 | **Unattended Discover saves a map with gaps.** It overwrites the saved map without a prompt, even when authoritative rows have no `LocalPath`. | Code |
| 13 | **Non-Windows hints only reach the script directly.** The wizard does not pass `-NonWindowsNameHint`, so the defaults always apply when you run through it. | Code |

## Making a change

1. Keep the scripts ASCII-only, and keep them compatible with Windows PowerShell 5.1. Load JSON arrays with `ConvertFrom-Json -InputObject`, and avoid `break` inside a menu `switch`.
2. Keep the join key intact. The collector's `Server` and `Folder` must equal the map's `Server` and `LocalPath`.
3. If you change a role, engine, parameter or output column, update the operator README and the [codebase map](codebase-map.md) in the same change.
4. Run the [static checks](#verification-facilities), plus whichever [validation](#safe-validation-plan) steps the change touches. Write down what you ran and where.
