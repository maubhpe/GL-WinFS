# Chargeback One — Windows scripts

This folder is the **whole production tool**. Copy it onto a domain-joined Windows orchestrator and run the wizard. There is no website, no Node, no installer, and no server.

Keep these files **in the same directory**. The wizard calls the others by `$PSScriptRoot`.

| File | You run it? | Role |
| --- | --- | --- |
| `Invoke-ChargebackWizard.ps1` | **Yes — this is the only entry point** | Interactive menu or unattended `-Stage` |
| `Get-DfsTargetMap.ps1` | No (wizard stage Discover) | Query DFS-N, DFSR, SMB `Path`. Does not walk files. |
| `Install-FsrmOwnerReport.ps1` | No (wizard stage Collect, via WinRM) | Owner report on each file server. **Auto:** NTFS walk on Server 2016; FSRM on 2019/2022 |
| `Invoke-ChargebackMerge.ps1` | No (wizard stage Merge) | DFS de-dupe + AD join → canonical CSV |
| `dfs-targets.json` | No | **Sample only.** Production map is `WorkspacePath\input\json\dfs-targets.json` |
| `README.md` | — | This file |

Tested on Windows Server **2016** (PowerShell 5.1) with a path to **2022**. Scripts are ASCII-only so 5.1 does not mangle punctuation.

---

## What it produces

Per-user and per-Business-Unit **file capacity** from Windows file servers behind a DFS namespace. It reads NTFS file ownership on each server and does not query the storage platform underneath.

The output is **a CSV**, for Windows targets only.

```
ScanDate,Source,Server,SharePath,OwnerSID,SamAccountName,DisplayName,Department,BusinessUnit,FileCount,LogicalBytes,AllocatedBytes,Unresolved
```

Chargeback number = `LogicalBytes`. Do not allocate rows where `Unresolved` is `SYSTEM`, `Administrators`, or `Unmapped`.

---

## Where it runs

```
Orchestrator (this folder)              Windows file servers            Active Directory
──────────────────────────  ───────────────                 ────────────────
1 Discover  DFS-N / DFSR / SMB  ──►     CIM: share name → local Path
2 Collect   WinRM  ─────────────────────────────────────────────►       Auto: NTFS walk (2016)
            copy SERVER-*.csv  ◄───────────────────────────────        or FSRM FilesByOwner (2019+)
3 Merge     drop + map  ──────────────────────────────────────────────► SID → user → BU
            output\chargeback.csv
```

- Interactive: **one stage per selection**. The menu does not chain 1→2→3.
- Unattended: `-Stage Discover`, `Collect`, `Merge`, or `All`.
- Collect starts the owner report when you run it. For recurring runs, schedule **the wizard**. Note: the FSRM engine also leaves a `Chargeback-FilesByOwner` FSRM report job with a weekly Sunday 03:00 schedule on each server it runs on (see [known limitations](../../docs/development.md#known-limitations)).
- **Q / Quit / Exit** leaves the menu. In PowerShell 5.1, `break` inside `switch` does **not** quit a loop — the current wizard sets a flag instead.

**Never** scan the DFS namespace UNC. **Never** measure DFSR replicas. Targets that match a non-Windows name hint (default `synology`, `syno`, `nas-syno`), or that fail the Windows CIM check, are tagged `phase3-synology` and skipped.

You do **not** type file server names or drive letters. Discover writes `LocalPath` from live `Get-SmbShare.Path`. If you move a share from `D:\` to `E:\`, fix the SMB Path (or recreate the share), then run Discover again.

---

## Prerequisites

**Orchestrator** (the host that holds this folder)

- Domain-joined Windows, PowerShell **5.1** (2016) or 7
- RSAT DFS: `Install-WindowsFeature RSAT-DFS-Mgmt-Con` (Server) or `Add-WindowsCapability -Online -Name Rsat.DFS.Tools~~~~0.0.1.0`
- DFSR module recommended (PrimaryMember vs referral guess)
- RSAT AD PowerShell (Merge): `Install-WindowsFeature RSAT-AD-PowerShell`
- WinRM to each Windows file server
- Rights: read DFS config, read AD users, **local admin on each file server** for Collect

**Each authoritative file server**

- WinRM: `Enable-PSRemoting -Force`
- Share folders that actually exist on a mounted volume (`Get-SmbShare | Format-Table Name, Path`)
- FSRM (`FS-Resource-Manager`) is optional on 2016. Collect Auto skips FSRM there and walks NTFS owners. On 2019/2022 Collect installs FSRM if missing.

**You type (wizard prompts)**

| Input | Example |
| --- | --- |
| WorkspacePath | `C:\Chargeback` or `\\fs\share\Chargeback` |
| NamespaceRoot | `\\corp.example.internal\files` |
| Business Unit AD attribute | `Department` |
| Collect credential | Enter = current user, `A` = prompt |

Passwords are **never** stored. Collect needs an account that is a **local admin on every file server**, not a test file-owner account. See [permissions](../../docs/permissions.md).

Optional wizard parameter: `-Engine Auto|Ntfs|Fsrm` (default `Auto`).

---

## Install (drop-in)

1. Copy this entire folder (USB, share, or `git clone` then use `public\scripts`).
2. Unblock if Windows tagged the files:

```powershell
Get-ChildItem -Path . -Filter *.ps1 | Unblock-File
```

3. Run the wizard from **inside** the folder.

---

## Interactive

```powershell
Set-Location <this-folder>
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-ChargebackWizard.ps1
```

You will be asked for WorkspacePath, NamespaceRoot, and the BU attribute. Then:

```
  [1] Discover   - query DFS targets (does not walk files)
  [2] Collect    - owner report on authoritative NAS VMs (WinRM; Auto=NTFS on 2016)
  [3] Merge      - join AD and write output\chargeback.csv
  [Q] Quit
```

**Order: 1 → confirm LocalPath is the real disk (E:\ not a stale D:\) → 2 → 3.**

After Discover the wizard prints one line per target (`NamespacePath | Server | LocalPath | Role | State`). If a Role is wrong, edit `WorkspacePath\input\json\dfs-targets.json` then run Collect.

| Role | Meaning | Collect? |
| --- | --- | --- |
| `authoritative` | The one Windows copy to measure | Yes |
| `replica` | DFSR secondary / extra referral | No |
| `phase3-synology` | Not identified as Windows (name hint, or the CIM check failed) | No |

`Get-DfsnFolder` on a domain root must use a wildcard (`\\domain\root\*`). The discover script does that; do not call `Get-DfsnFolder -Path \\domain\root` by hand.

A message like `This host (SHORTNAME) is not a DFS target` is usually short name vs FQDN. Ignore it if the printed rows list this server as an FQDN.

Collect: Enter = current credentials, `A` = `Get-Credential`.

On Server 2016, Collect logs `Auto: Server 2016 or older -> NTFS owner walk` and finishes in seconds for a lab. FSRM stays available with `-Engine Fsrm` (2019/2022 is the intended path).

If Collect cannot `Test-Path` the mapped `LocalPath`, it tries in order: exact path, SMB Path for that share name, parent folder, then the same path on `C:` / `D:` / `E:`. If nothing exists it dumps `Get-PSDrive` and `Get-SmbShare` and stops — create the folder or point the share at the real volume, then Discover again.

---

## Unattended (Task Scheduler)

```powershell
.\Invoke-ChargebackWizard.ps1 `
  -WorkspacePath '\\fs\Chargeback' `
  -NamespaceRoot '\\corp.example.internal\files' `
  -BusinessUnitAttribute Department `
  -Engine Auto `
  -Stage All

.\Invoke-ChargebackWizard.ps1 -WorkspacePath '\\fs\Chargeback' -Stage Discover,Collect
.\Invoke-ChargebackWizard.ps1 -WorkspacePath '\\fs\Chargeback' -Stage Merge
```

After the first run, `input\json\config.json` holds WorkspacePath, NamespaceRoot, and the AD attribute (no secrets). Later you can omit `-NamespaceRoot` / `-BusinessUnitAttribute`.

Optional: `-Credential (Get-Credential)`, `-TimeoutSeconds 3600`.

Task Scheduler action: `powershell.exe`

Arguments:

```
-ExecutionPolicy Bypass -File C:\Tools\ChargebackOne\Invoke-ChargebackWizard.ps1 -WorkspacePath \\fs\Chargeback -Stage All
```

Run as an account that is admin on the file servers and can read AD.

---

## Workspace (created by the wizard)

`WorkspacePath` is local **or** UNC. The wizard creates and write-tests it.

```
WorkspacePath\
  input\json\    config.json, dfs-targets.json
  input\drop\    SERVER-*.csv copied back from each file server
  output\        chargeback-YYYY-MM-DD.csv  and  chargeback.csv
```

Scripts live in their own folder (for example `C:\ChargebackOne`). The workspace is separate (for example `C:\Chargeback`). Merge reads **`WorkspacePath\input\json\dfs-targets.json`**, not the sample next to the scripts.

Local workspace: Collect still works — CSVs return over WinRM (no admin share). UNC workspace: same files land in `input\drop`.

---

## Operating rules

1. Discover; do not type share lists or drive letters.
2. Scan **local paths** only — never the namespace UNC.
3. One member per replicated folder (`authoritative`).
4. If you change where a share lives on disk, update `New-SmbShare -Path` and re-run Discover.
5. Owner cap is raised inside the FSRM collector (Windows default **10** silently truncates). Not prompted.
6. Treat `output\` as chargeback data (restrict NTFS/share ACLs).

---

## Windows Server 2016 notes

FSRM on 2016 is a poor fit for this wizard:

- No `ReportLocationCsv` (use `ReportLocationOnDemand`)
- `New-FsrmScheduledTask` uses `-Weekly`, not `-Days`
- `C:\StorageReports\*` does not exist until first MMC use (`0x80045304`)
- `-Interactive` blocks WinRM with no output
- PowerShell 5.1 buffers `Invoke-Command` until the remote script finishes
- `ConvertFrom-Json` of a JSON **array** must use `-InputObject` (not a pipeline) or Merge/Show-Map see zero rows
- `break` inside `switch` does not exit a `while` / `do` menu

Collect **Auto** therefore walks NTFS owners on build <= 14393. Same drop CSV columns (`Server`, `Folder`, `Owner`, `SID`, `Size`, `Files`) so Merge does not change.

---

## Troubleshooting

| Symptom | Action |
| --- | --- |
| `DFSN module not found` | Install RSAT DFS on the **orchestrator** |
| `Get-ADUser` not recognized | `Install-WindowsFeature RSAT-AD-PowerShell` |
| `Get-DfsnFolder` invalid argument | Path must be `\\domain\root\*` (Discover already does this) |
| Empty map / empty table after Discover wrote N rows | Old wizard: 5.1 JSON pipeline bug. Replace wizard + merge from current `main` |
| `Q` reprints the menu | Old wizard: `switch`/`break`. Replace wizard; Q/Quit/Exit now leave |
| `This host is not a DFS target` | Short name vs FQDN. Check the printed Server column |
| Authoritative row, no `LocalPath` | CIM/`Get-SmbShare` failed to that host |
| `Namespace path does not exist` | Share Path is stale (D:\ vs E:\). `Get-SmbShare | ft Name, Path`, fix Path, Discover |
| WinRM / Access denied | `Enable-PSRemoting -Force` on the file server; use an account that is local admin on the file server, not `cb.*` |
| Ctrl+C does nothing during Collect | WinRM wait. Kill that `powershell.exe` from a second window; `wsmprovhost` on the file server if needed |
| FSRM `0x80045304` / `ReportLocationCsv` / hung Collect | Expected on 2016. Use Auto (NTFS). Do not wait on FSRM |
| Merge: no authoritative rows | Wrong file (sample vs workspace map), or 5.1 JSON wrap. Current Merge prints each row first |
| Merge: no CSV | Collect did not copy; check `input\drop` |
| Totals doubled | Namespace UNC scanned, or two `authoritative` rows for one folder |
| Totals truncated | Old FSRM with owner cap 10 — re-run Collect |
| `Unresolved=Unmapped` | SID not in AD — leave out of BU totals |

---

## Security

- The scripts add no service of their own. The FSRM engine installs the FSRM feature if it is missing and starts its services. Runs as you, or as the scheduled-task account.
- Credential is used for that Collect run only.
- `config.json` has paths and the AD attribute **name**, never a password.
- The orchestrator does not traverse user files. The file server walks (or FSRM-scans) local share roots only.

## Licence

MIT. See [LICENSE](../../LICENSE) and the notice in the [repository README](../../README.md#licence).
