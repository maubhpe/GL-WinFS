# Maintainer guide

Start here if you are taking over maintenance of this repository. This guide describes what the scripts do as of commit `842de73` (the scripts have not changed since). It does not describe a supported deployment, a security baseline, or guaranteed behaviour in any particular environment.

- [Codebase map](codebase-map.md): every script, function, input, output and dependency, plus extension points.
- [Development guide](development.md): verification facilities, a safe validation plan, current access requirements and known limitations.
- [Permissions](permissions.md): the rights each script and stage needs, and which identity each one uses.
- [Operator README](../public/scripts/README.md): how the pack is run (prompts, unattended use, workspace layout, troubleshooting). This guide does not repeat it.

## What is in the repository

| Path | What it is | Status |
| --- | --- | --- |
| [`public/scripts/`](../public/scripts) | The PowerShell pack: four `.ps1` scripts, a sample map and the operator README. | The only executable code in the repo. |
| `docs/` | This guide, the [codebase map](codebase-map.md), the [development guide](development.md) and [permissions](permissions.md). | Documentation only. |
| [`LICENSE`](../LICENSE) | MIT License. | |
| `README.md`, `.gitignore` | Repo entry point; ignore rules. | `.gitignore` also excludes a local web lab console (`/src/`, `/server/`, `package.json` and others). None of that is in the repo. |

There are no tests, CI workflows, build steps or package manifests in the repository.

## What the code produces

One canonical CSV per Merge run (`output\chargeback-<yyyy-MM-dd>.csv`, copied to `output\chargeback.csv`), covering Windows file-server shares only. The scripts produce no other report formats. Targets with `Role = phase3-synology` (non-Windows by name hint, or not confirmed as Windows by CIM) are skipped by Collect and Merge. `phase3-synology` is only the literal role value in the code and map; no stage collects data from those targets.

## How the stages fit together

The wizard (`Invoke-ChargebackWizard.ps1`) is the only entry point. It runs one stage per menu choice, or the stages you pass with `-Stage` in the fixed order Discover, Collect, Merge.

```
Orchestrator (wizard host)                     Each authoritative file server        Active Directory
-------------------------                      ---------------------------------     ----------------
1 Discover  Get-DfsTargetMap.ps1
            DFSN/DFSR cmdlets (local)
            remote CIM: Win32_OperatingSystem,
            Get-SmbShare -CimSession  ------->  (queried, nothing written)
            -> WorkspacePath\input\json\dfs-targets.json

2 Collect   New-PSSession, copy script  ------> C:\ProgramData\ChargebackOne\
                                                Install-FsrmOwnerReport.ps1 runs here
                                                (FSRM or NTFS owner walk)
            copy *.csv back  <----------------  C:\ProgramData\ChargebackOne\drop\*.csv
            -> WorkspacePath\input\drop\SERVER-*.csv

3 Merge     Invoke-ChargebackMerge.ps1 (local)
            map filter + Get-ADUser  -------------------------------------------------->  SID -> user -> BU
            -> WorkspacePath\output\chargeback-YYYY-MM-DD.csv and chargeback.csv
```

The stages hand off only through files in the workspace:

1. **Discover** writes `input\json\dfs-targets.json`. Each row has a `Role` (`authoritative`, `replica` or `phase3-synology`) and, for Windows rows, a `LocalPath` taken from the live SMB share `Path`.
2. **Collect** reads that map and uses only rows where `Role = authoritative` and `LocalPath` is set. It groups them by `Server`, runs the collector on each server over WinRM, and copies every CSV from the remote drop folder back into `input\drop`.
3. **Merge** reads the same map and keeps drop rows whose `Server|Folder` pair matches an authoritative `Server|LocalPath`. It resolves owners in AD and writes the canonical CSV.

You can edit the map by hand between stages; the operator README documents this. Discover overwrites it on every run that is saved.

## Where to go next

- To change a stage, find its functions and contracts in the [codebase map](codebase-map.md).
- Before you change anything, read [known limitations](development.md#known-limitations) and the [validation plan](development.md#safe-validation-plan).
