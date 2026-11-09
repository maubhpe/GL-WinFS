# GL-WinFS-Reporting

PowerShell scripts that report per-user and per-Business-Unit file capacity on Windows file servers behind a DFS namespace. It reads NTFS file ownership on each server and does not query the storage platform underneath. The result is one CSV file. There is no web server, no installer and nothing to `npm install`.

## What it produces

Each Merge run writes `output\chargeback-<yyyy-MM-dd>.csv` in the workspace and copies it to `output\chargeback.csv`. The columns are:

```
ScanDate,Source,Server,SharePath,OwnerSID,SamAccountName,DisplayName,Department,BusinessUnit,FileCount,LogicalBytes,AllocatedBytes,Unresolved
```

- `LogicalBytes` is the size in bytes, as reported by the collector. `AllocatedBytes` is currently a copy of `LogicalBytes`.
- `Unresolved` is `SYSTEM`, `Administrators` or `Unmapped` (the owner was not found in AD) for rows that should not be allocated to a Business Unit.
- Only Windows shares are measured. Targets tagged `replica` or `phase3-synology` are skipped.

The scripts produce no other report formats.

## How it works

Run everything through `Invoke-ChargebackWizard.ps1` on a domain-joined Windows host (the orchestrator). It has three stages:

1. **Discover**
   - Reads the DFS namespace.
   - Picks one `authoritative` Windows target per folder.
   - Records each target's local disk path (`LocalPath`) from the live SMB share.
   - Writes `input\json\dfs-targets.json`.
   - It does not read file data.
2. **Collect**
   - Connects over WinRM to each authoritative file server.
   - Runs the collector there against the local share paths.
   - Copies the resulting CSVs back to `input\drop`.
3. **Merge**
   - Keeps only rows for authoritative paths.
   - Resolves owners in Active Directory, using `Department` by default for the Business Unit attribute.
   - Writes the output CSV.

The interactive menu runs one stage at a time. Unattended runs use `-Stage Discover`, `Collect`, `Merge` or `All`.

### Collect side effects

Collect `-Engine Auto` (the default) uses an NTFS owner walk on Server 2016 and FSRM Files-by-Owner on Server 2019/2022. When FSRM is used, Collect:

- installs the FSRM feature if it is missing and starts its services;
- changes server-wide FSRM report settings;
- leaves a `Chargeback-FilesByOwner` report job with a weekly Sunday 03:00 schedule on each server.

`-Engine Ntfs` avoids those FSRM changes. The NTFS walk reads with the session's own rights and silently skips anything it cannot read, so neither engine is guaranteed to cover every protected file. See [known limitations](docs/development.md#known-limitations).

## Prerequisites

- **Orchestrator:** a domain-joined Windows host with Windows PowerShell 5.1 (the version the pack was tested with), RSAT DFS (the DFSR module is recommended) and RSAT AD PowerShell. It needs WinRM access to each file server, and a workspace folder (local or UNC) it can write to.
- **Each authoritative file server:** PowerShell remoting enabled, with shares on volumes that exist.
- **Accounts:**
  - The documented baseline is an account that can read DFS configuration and AD users, and that is a local administrator on each file server.
  - Domain Admin is not required.
  - No smaller delegated set of rights has been validated.
  - [docs/permissions.md](docs/permissions.md) explains which account each stage uses and what it needs.

## Getting started

Follow the [operator guide](public/scripts/README.md) for installation, prompts, unattended use and troubleshooting.

A first run can be limited to Discover. Discover queries DFS and the file servers without changing them. It writes only to the workspace and to a temporary file:

```powershell
Set-Location .\public\scripts
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-ChargebackWizard.ps1
# At the menu, choose [1] Discover. Review the printed map before running Collect.
```

Check that every authoritative row shows a real `LocalPath` before you run Collect.

## Documentation

| Document | For |
| --- | --- |
| [public/scripts/README.md](public/scripts/README.md) | Operators: installation, interactive and unattended use, workspace layout, troubleshooting. |
| [docs/README.md](docs/README.md) | Maintainers: start here. How the stages connect and what the code produces. |
| [docs/codebase-map.md](docs/codebase-map.md) | Scripts, functions, data contracts and extension points. |
| [docs/development.md](docs/development.md) | Verification, a safe validation plan and known limitations. |
| [docs/permissions.md](docs/permissions.md) | Rights and identities per script and stage. |

## Repository layout

| Path | Contents |
| --- | --- |
| `public/scripts/` | The PowerShell pack. The only executable code in this repo. |
| `docs/` | Maintainer documentation. |
| `LICENSE` | MIT License. |

## Licence

These scripts are provided as-is under the [MIT License](LICENSE), without warranty or any commitment to support, maintenance or fixes. You are responsible for assessing, testing and approving their use and any resulting changes in your environment. To the fullest extent permitted by applicable law, maubhpe accepts no liability arising from their use.
