# Invoke-ChargebackMerge.ps1
# Chargeback One - Phase 1 orchestrator.
# Reads collector CSV, applies dfs-targets.json, joins AD, writes canonical CSV.
# No Excel / HTML / PDF. No Synology ingest (Phase 3).

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DropFolder,
    [Parameter(Mandatory)]
    [string] $TargetMapPath,
    [Parameter(Mandatory)]
    [string] $OutputPath,
    [string] $BusinessUnitAttribute = 'Department',
    [string] $ScanDate = (Get-Date -Format 'yyyy-MM-dd')
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

if (-not (Test-Path -Path $TargetMapPath)) {
    throw "Target map not found: $TargetMapPath. Run Get-DfsTargetMap.ps1 first."
}

function ConvertTo-Sid {
    param([string] $Name, [string] $Hint)
    try {
        if ($Name -match '^S-1-') { return $Name }
        $nt = New-Object System.Security.Principal.NTAccount($Name)
        return $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $Hint
    }
}

function Get-Prop {
    param($Obj, [string] $Name)
    if ($null -eq $Obj) { return $null }
    try {
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    } catch { }
    return $null
}

function Get-MapObjects {
    param([string] $Path)
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Map file is empty: $Path"
    }
    $parsed = ConvertFrom-Json -InputObject $raw
    $out = New-Object System.Collections.ArrayList
    function Add-Leaf {
        param($o)
        if ($null -eq $o) { return }
        $isList = $false
        if ($o -is [System.Array]) { $isList = $true }
        elseif ($o -is [System.Collections.IList] -and -not ($o.PSObject.Properties['Role'])) { $isList = $true }
        if ($isList) {
            foreach ($i in @($o)) { Add-Leaf $i }
            return
        }
        [void]$out.Add($o)
    }
    Add-Leaf $parsed
    return @($out.ToArray())
}

$allowed = @(Get-MapObjects -Path $TargetMapPath)
Write-Host ('Map file : ' + $TargetMapPath)
Write-Host ('Map rows : ' + $allowed.Count)
$allowSet = @{}
$n = 0
foreach ($t in $allowed) {
    $n++
    $role = [string](Get-Prop $t 'Role')
    $lp   = [string](Get-Prop $t 'LocalPath')
    $srv  = [string](Get-Prop $t 'Server')
    $props = @($t.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
    Write-Host ('  row ' + $n + ' Role=' + $role + ' Server=' + $srv + ' LocalPath=' + $lp + ' props=' + $props)
    if ($role -eq 'authoritative' -and -not [string]::IsNullOrWhiteSpace($lp) -and -not [string]::IsNullOrWhiteSpace($srv)) {
        $allowSet[('{0}|{1}' -f $srv, $lp)] = $true
    }
}
if ($allowSet.Count -eq 0) {
    throw ('No authoritative Windows LocalPath rows in ' + $TargetMapPath + '. Parsed ' + $allowed.Count + ' object(s). Open that file and confirm Role=authoritative and LocalPath is set.')
}

$rows = New-Object System.Collections.Generic.List[object]
$csvFiles = Get-ChildItem -Path $DropFolder -Filter *.csv -File
if (-not $csvFiles) { throw "No CSV files in $DropFolder" }

foreach ($file in $csvFiles) {
    $data = Import-Csv -Path $file.FullName
    foreach ($r in $data) {
        $server = if ($r.Server) { $r.Server } else { $file.BaseName }
        $path   = $r.Folder
        if (-not $path) { $path = $r.Path }
        if (-not $path) { $path = $r.Namespace }
        $key = '{0}|{1}' -f $server, $path
        if (-not $allowSet.ContainsKey($key)) { continue }

        $owner = $r.Owner
        if (-not $owner) { $owner = $r.'Owner Name' }
        $sid = ConvertTo-Sid -Name $owner -Hint $r.SID
        $bytes = 0L
        foreach ($col in @('Size','File Size','LogicalSize','Total File Size')) {
            if ($r.$col) {
                [void][long]::TryParse(($r.$col -replace '[^0-9]',''), [ref]$bytes)
                if ($bytes) { break }
            }
        }
        $files = 0
        [void][int]::TryParse($r.Files, [ref]$files)

        $unresolved = ''
        $sam = ''
        $display = $owner
        $dept = ''
        $bu = ''
        if ($owner -match 'SYSTEM$') { $unresolved = 'SYSTEM' }
        elseif ($owner -match 'Administrators$') { $unresolved = 'Administrators' }
        else {
            $ad = $null
            try {
                $ad = Get-ADUser -Filter "SID -eq '$sid'" -Properties $BusinessUnitAttribute, DisplayName, Department, SamAccountName
            } catch { $ad = $null }
            if (-not $ad) {
                try {
                    $ad = Get-ADUser -Identity $owner -Properties $BusinessUnitAttribute, DisplayName, Department, SamAccountName
                } catch { $ad = $null }
            }
            if ($ad) {
                $sam = $ad.SamAccountName
                $display = $ad.DisplayName
                $dept = $ad.Department
                $bu = [string]$ad.$BusinessUnitAttribute
            } else {
                $unresolved = 'Unmapped'
            }
        }

        $rows.Add([pscustomobject]@{
            ScanDate         = $ScanDate
            Source           = 'Windows-FSRM-Owner'
            Server           = $server
            SharePath        = $path
            OwnerSID         = $sid
            SamAccountName   = $sam
            DisplayName      = $display
            Department       = $dept
            BusinessUnit     = $bu
            FileCount        = $files
            LogicalBytes     = $bytes
            AllocatedBytes   = $bytes
            Unresolved       = $unresolved
        }) | Out-Null
    }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host ("Wrote {0} rows to {1}" -f $rows.Count, $OutputPath)
Write-Host 'Phase 1 artefact only. Do not emit Excel/HTML/PDF here (Phase 2). Do not merge Synology (Phase 3).'
