# Permissions

This page lists the rights each script needs, based on what the code does. The scripts do not grant, configure or check any permissions.

- **Baseline** is the operating model the pack documents: an account that is a local administrator on each Windows file server it collects from, and that can read DFS configuration and AD users.
- **Not validated** means that no smaller, delegated set of rights has been tested. No least-privilege baseline has been validated for any stage. See also [known limitations](development.md#known-limitations).

## Which identity is used

| Stage | Identity |
| --- | --- |
| Discover | The account running the wizard. `-Credential` is **not** used. |
| Collect, on each file server | `-Credential` if you pass it (or choose `A` at the prompt); otherwise the account running the wizard. It applies only to `New-PSSession` and to the file copies over that session. |
| Collect, on the report host | The account running the wizard. The returned CSVs are written to `input\drop` under this identity. |
| Merge | The account running the wizard. `-Credential` is **not** used. |

If you pass a separate `-Credential`, Discover and Merge still need the rights below under the account that runs the wizard.

## Quick table

| | Wizard (`Invoke-ChargebackWizard.ps1`) | Discover (`Get-DfsTargetMap.ps1`) | Collector (`Install-FsrmOwnerReport.ps1`) | Merge (`Invoke-ChargebackMerge.ps1`) |
| --- | --- | --- | --- | --- |
| Runs on | Report host | Report host | Each authoritative file server (over WinRM) | Report host |
| Local admin on the report host | No (exceptions below) | No | n/a | No |
| Local admin on file servers | Baseline, for Collect | Expected for share `Path` (see below) | Baseline; required for the FSRM engine | No contact |
| Domain Admin | No | No | No | No |
| AD changes / AD admin | No | No | No | No (read only) |
| DFS administrator (change rights) | No | No: read-only `Get-*` cmdlets only | No | No |
| NTFS reads of user files | No | No | Yes: traverse, list, read attributes, read permissions | No |
| Workspace writes | Yes | Writes to `$env:TEMP` (the wizard then copies the map) | No (writes on the file server only) | Yes: `output` |

## Wizard (`Invoke-ChargebackWizard.ps1`)

- **Workspace:** creates `input\json`, `input\drop` and `output`, then write-tests them. It writes `config.json` and the map, receives the Collect CSVs and receives the Merge output. A local folder needs only normal NTFS Modify. A UNC workspace needs both share and NTFS rights for the wizard's identity.
- **Report host:** local admin is not needed for normal runs once RSAT DFS and RSAT AD PowerShell are installed. The exceptions are installing those features, and choosing a workspace in a protected location.
- **Task Scheduler:** the scheduled account needs the right to log on as a batch job and every right listed for the stages it runs. Access to a UNC workspace from a scheduled task depends on how the task stores credentials. A gMSA has not been validated with this pack.

## Discover (`Get-DfsTargetMap.ps1`)

- **DFS:** calls only `Get-DfsnRoot` (when no root is given), `Get-DfsnFolder` and `Get-DfsnFolderTarget`. When the DFSR module is present it also calls `Get-DfsReplicationGroup`, `Get-DfsReplicatedFolder` and `Get-DfsrMembership`. It makes no DFS changes, so no DFS management rights are needed. The minimum read rights have not been validated.
- **File servers, OS check:** remote CIM `Win32_OperatingSystem` (`root/cimv2`). A failure makes the target `phase3-synology` instead of reporting an error.
- **File servers, share path:** `Get-SmbShare -CimSession` (`root/Microsoft/Windows/SMB`), reading `Path`.
  - Being able to open WinRM/CIM sessions and list shares is not enough. Accounts without administrative rights on the target have been observed to get a blank `Path`, and a blank `Path` means Collect skips that target.
  - The operator README states the local-admin requirement for Collect only. Running Discover as an account that is also a local administrator on the file servers is the configuration expected to return `Path`. This is inferred, not separately validated.
  - Membership of Remote Management Users, or remote-enable rights on the WMI namespaces alone, has not been shown to return `Path`.
- **Report host:** writes only the temp map file.

## Collector (`Install-FsrmOwnerReport.ps1`)

The wizard copies it to `C:\ProgramData\ChargebackOne\` on each file server and runs it in the Collect WinRM session. If you run it directly, use an elevated session when the FSRM engine is used.

| Operation | Needs |
| --- | --- |
| WinRM session, create `C:\ProgramData\ChargebackOne\drop`, copy the script and CSVs | Rights to open a PowerShell remoting session on the file server (baseline: local admin). |
| Local `Win32_OperatingSystem` and `Get-SmbShare` (path checks) | Local CIM read. The behaviour of `Path` for a non-admin account is as described under Discover. |
| **NTFS engine:** `Get-ChildItem -Recurse -Force` and `GetAccessControl()` on each `LocalPath` | Traverse, list folder, read attributes and read permissions on every folder and file. It does not need write access, ownership or Take Ownership. |
| **FSRM engine:** `Install-WindowsFeature FS-Resource-Manager` (if missing), start `SrmSvc` / `SrmReports`, `Set-FsrmSetting`, create or remove a storage report job, create `C:\StorageReports\*` | Local administrator on the file server. |

Notes:

- **The NTFS walk does not enable backup privilege.** Items the identity cannot read are skipped silently. Local administrator membership does not guarantee that every protected file is read.
- **FSRM generates the report in its own service, not as the WinRM identity.** Whether that scan covers protected folders has not been validated.
- **FSRM side effects:** it changes server-wide FSRM report limits and report locations, and it leaves a `Chargeback-FilesByOwner` job with a weekly Sunday 03:00 schedule (see [known limitations](development.md#known-limitations)). `-Engine Ntfs` skips all FSRM operations.

## Merge (`Invoke-ChargebackMerge.ps1`)

- **AD:** `Get-ADUser`, by SID and then by name, reading `DisplayName`, `Department`, `SamAccountName` and the chosen BU attribute. `NTAccount.Translate` resolves owner names to SIDs. Both run as the wizard's identity.
- **AD rights:** read access to user objects and those attributes is enough. No AD administrative role is needed. If your directory restricts read access to `Department` or another BU attribute, grant read on it, or the values come back empty.
- **Workspace:** reads the map and `input\drop`, and writes `output`. It makes no contact with the file servers.

## Not validated

- The minimum DFS read rights for the `Get-Dfsn*` / `Get-Dfsr*` cmdlets used.
- Any non-administrator configuration that returns `Get-SmbShare.Path` remotely, including JEA.
- Whether the FSRM cmdlets work under any delegated, non-admin rights.
- FSRM coverage of protected folders.
- Running scheduled tasks with a gMSA or a UNC workspace.
