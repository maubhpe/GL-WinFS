# Get-DfsTargetMap.ps1
# Chargeback One - Phase 1 inventory.
# Queries DFS Namespace, DFSR membership, and SMB share local paths.
# Does not walk file data. Writes dfs-targets.json for Invoke-ChargebackMerge.ps1.
#
# Run from one domain-joined Windows host with RSAT-DFS-Mgmt-Con (DFSN).
# DFSR module is optional but required to mark PrimaryMember vs replica.
# CIM to each Windows target is used only to resolve \\server\share -> local path.

[CmdletBinding()]
param(
    [string[]] $NamespaceRoot,
    [string]   $OutputPath = '.\dfs-targets.json',
    [string]   $LocalNamespacesPath,
    [string[]] $NonWindowsNameHint = @('synology', 'syno', 'nas-syno'),
    [switch]   $ThisComputerOnly
)

$ErrorActionPreference = 'Stop'
Write-Host 'Get-DfsTargetMap build 2016-2'

function ConvertTo-ChargebackJson {
    param([object[]] $Rows)
    function Esc([string] $s) {
        if ($null -eq $s) { return '' }
        return (($s.Replace('\', '\\')).Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n'))
    }
    $chunks = New-Object System.Collections.ArrayList
    foreach ($r in @($Rows)) {
        $lpRaw = [string]$r.LocalPath
        if ([string]::IsNullOrEmpty($lpRaw)) {
            $lpJson = 'null'
        } else {
            $lpJson = '"' + (Esc $lpRaw) + '"'
        }
        $line = '  {"NamespacePath":"' + (Esc ([string]$r.NamespacePath)) +
            '","Server":"' + (Esc ([string]$r.Server)) +
            '","TargetPath":"' + (Esc ([string]$r.TargetPath)) +
            '","LocalPath":' + $lpJson +
            ',"Role":"' + (Esc ([string]$r.Role)) +
            '","State":"' + (Esc ([string]$r.State)) + '"}'
        [void]$chunks.Add($line)
    }
    if ($chunks.Count -eq 0) { return '[' + "`r`n" + ']' }
    return '[' + "`r`n" + ($chunks -join (',' + "`r`n")) + "`r`n" + ']'
}

function Test-ModuleAvailable {
    param([string] $Name)
    $null -ne (Get-Module -ListAvailable -Name $Name)
}

if (-not (Test-ModuleAvailable -Name DFSN)) {
    throw @'
DFSN module not found. Install RSAT DFS Management, then retry:
  Add-WindowsCapability -Online -Name Rsat.DFS.Tools~~~~0.0.1.0
  # Server: Install-WindowsFeature RSAT-DFS-Mgmt-Con
'@
}

Import-Module DFSN -ErrorAction Stop
$hasDfsr = Test-ModuleAvailable -Name DFSR
if ($hasDfsr) { Import-Module DFSR } else {
    Write-Warning 'DFSR module not present. Replicated folders will use DFS referral priority, not PrimaryMember.'
}

function Get-HostFromUnc {
    param([string] $Unc)
    if ($Unc -notmatch '^\\\\([^\\]+)\\') { return $null }
    return $Matches[1]
}

function Get-ShareAndRest {
    param([string] $Unc)
    # \\server\share[\rest]
    if ($Unc -notmatch '^\\\\[^\\]+\\([^\\]+)(.*)$') { return @{ Share = $null; Rest = '' } }
    $rest = $Matches[2]
    if ($rest.StartsWith('\')) { $rest = $rest.Substring(1) }
    return @{ Share = $Matches[1]; Rest = $rest }
}

function Test-LikelyNonWindows {
    param([string] $Server)
    $n = $Server.ToLowerInvariant()
    foreach ($hint in $NonWindowsNameHint) {
        if ($n -like "*$($hint.ToLowerInvariant())*") { return $true }
    }
    return $false
}

function Get-LocalPathFromUnc {
    param([string] $Server, [string] $Unc)
    $parts = Get-ShareAndRest -Unc $Unc
    if (-not $parts.Share) { return $null }
    try {
        $share = Get-SmbShare -CimSession $Server -Name $parts.Share -ErrorAction Stop
        if ($parts.Rest) { return (Join-Path $share.Path $parts.Rest) }
        return $share.Path
    } catch {
        return $null
    }
}

function Test-WindowsCim {
    param([string] $Server)
    try {
        $null = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $Server -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

$primaryByFolder = @{}
if ($hasDfsr) {
    try {
        foreach ($rg in Get-DfsReplicationGroup) {
            $folders = Get-DfsReplicatedFolder -GroupName $rg.GroupName -ErrorAction SilentlyContinue
            $members = Get-DfsrMembership -GroupName $rg.GroupName -ErrorAction SilentlyContinue
            $primary = @($members | Where-Object { $_.PrimaryMember -eq $true })
            foreach ($rf in @($folders)) {
                $name = [string]$rf.FolderName
                if ($primary.Count -ge 1) {
                    $primaryByFolder[$name] = @($primary | ForEach-Object { $_.ComputerName })
                }
            }
        }
    } catch {
        Write-Warning "DFSR query failed: $($_.Exception.Message). Falling back to referral priority."
        $hasDfsr = $false
    }
}

if (-not $NamespaceRoot -or $NamespaceRoot.Count -eq 0) {
    $NamespaceRoot = @(Get-DfsnRoot | ForEach-Object { $_.Path })
}
if (-not $NamespaceRoot) { throw 'No DFS namespace roots found. Pass -NamespaceRoot \\domain\root' }

$records = New-Object System.Collections.ArrayList

foreach ($root in $NamespaceRoot) {
    $folderGlob = $root.TrimEnd('\') + '\*'
    $folders = @()
    try {
        $folders = @(Get-DfsnFolder -Path $folderGlob -ErrorAction Stop)
    } catch {
        Write-Warning ('Get-DfsnFolder failed for ' + $folderGlob + ': ' + $_.Exception.Message)
        $folders = @()
    }

    foreach ($folder in $folders) {
        $targets = @()
        try {
            $targets = @(Get-DfsnFolderTarget -Path $folder.Path -ErrorAction Stop)
        } catch {
            Write-Warning ('Get-DfsnFolderTarget failed for ' + $folder.Path + ': ' + $_.Exception.Message)
            continue
        }
        if (-not $targets -or $targets.Count -eq 0) { continue }

        $leaf = Split-Path -Leaf $folder.Path
        $windows = New-Object System.Collections.ArrayList
        $other   = New-Object System.Collections.ArrayList

        foreach ($t in $targets) {
            $server = Get-HostFromUnc -Unc ([string]$t.TargetPath)
            if (-not $server) { continue }
            $server = [string]$server
            $isWin = $false
            $local = $null
            if (Test-LikelyNonWindows -Server $server) {
                $isWin = $false
            } else {
                $isWin = Test-WindowsCim -Server $server
                if ($isWin) { $local = Get-LocalPathFromUnc -Server $server -Unc ([string]$t.TargetPath) }
            }
            $row = [pscustomobject]@{
                NamespacePath         = [string]$folder.Path
                Server                = $server.ToUpperInvariant()
                TargetPath            = [string]$t.TargetPath
                LocalPath             = $local
                State                 = [string]$t.State
                ReferralPriorityClass = [string]$t.ReferralPriorityClass
                ReferralPriorityRank  = 0
                IsWindows             = $isWin
            }
            try { $row.ReferralPriorityRank = [int]$t.ReferralPriorityRank } catch { }
            if ($isWin) { [void]$windows.Add($row) } else { [void]$other.Add($row) }
        }

        $authServer = $null
        $primaries = @()
        if ($hasDfsr -and $primaryByFolder.ContainsKey($leaf)) {
            $primaries = @($primaryByFolder[$leaf] | ForEach-Object { [string]$_.ToUpperInvariant() })
        }
        if ($windows.Count -eq 1) {
            $authServer = $windows[0].Server
        } elseif ($windows.Count -gt 1 -and $primaries.Count -gt 0) {
            $hit = $windows | Where-Object { $primaries -contains $_.Server } | Select-Object -First 1
            if ($hit) { $authServer = $hit.Server }
        }
        if (-not $authServer -and $windows.Count -gt 1) {
            $ranked = $windows | Sort-Object {
                switch ([string]$_.ReferralPriorityClass) {
                    'GlobalHigh' { 0 }
                    'SiteCostHigh' { 1 }
                    'SiteCostNormal' { 2 }
                    'SiteCostLow' { 3 }
                    'GlobalLow' { 4 }
                    default { 5 }
                }
            }, { [int]$_.ReferralPriorityRank }
            $online = @($ranked | Where-Object { $_.State -eq 'Online' })
            $pick = if ($online.Count) { $online[0] } else { @($ranked)[0] }
            $authServer = $pick.Server
            Write-Warning ('No DFSR PrimaryMember for ' + $folder.Path + '. Using referral priority: ' + $authServer)
        }

        foreach ($w in $windows) {
            $role = if ($w.Server -eq $authServer) { 'authoritative' } else { 'replica' }
            [void]$records.Add([pscustomobject]@{
                NamespacePath = [string]$w.NamespacePath
                Server        = [string]$w.Server
                TargetPath    = [string]$w.TargetPath
                LocalPath     = $(if ($w.LocalPath) { [string]$w.LocalPath } else { $null })
                Role          = [string]$role
                State         = [string]$w.State
            })
        }
        foreach ($o in $other) {
            [void]$records.Add([pscustomobject]@{
                NamespacePath = [string]$o.NamespacePath
                Server        = [string]$o.Server
                TargetPath    = [string]$o.TargetPath
                LocalPath     = $(if ($o.LocalPath) { [string]$o.LocalPath } else { [string]$o.TargetPath })
                Role          = 'phase3-synology'
                State         = [string]$o.State
            })
        }
    }
}

$me = $env:COMPUTERNAME.ToUpperInvariant()
$export = @($records)
if ($ThisComputerOnly) {
    $export = @($records | Where-Object { $_.Server -eq $me })
}

Write-Host ('Serializing ' + @($export).Count + ' row(s)')
$json = ConvertTo-ChargebackJson -Rows $export
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
Set-Content -Path $OutputPath -Value $json -Encoding ASCII

$localNs = @(
    $records |
        Where-Object { $_.Server -eq $me -and $_.Role -eq 'authoritative' -and $_.LocalPath } |
        Select-Object -ExpandProperty LocalPath -Unique
)
if ($LocalNamespacesPath) {
    $localDir = Split-Path -Parent $LocalNamespacesPath
    if ($localDir) { New-Item -ItemType Directory -Force -Path $localDir | Out-Null }
    $nsLines = @($localNs | ForEach-Object { '"' + ($_ -replace '\\','\\') + '"' })
    $nsJson = '[' + ($nsLines -join ',') + ']'
    Set-Content -Path $LocalNamespacesPath -Value $nsJson -Encoding ASCII
}

$nAuth = @($records | Where-Object Role -eq 'authoritative').Count
$nRep  = @($records | Where-Object Role -eq 'replica').Count
$nP3   = @($records | Where-Object Role -eq 'phase3-synology').Count
Write-Host ('Wrote ' + @($export).Count + ' target row(s) to ' + $OutputPath)
Write-Host ('Authoritative : ' + $nAuth)
Write-Host ('Replica       : ' + $nRep)
Write-Host ('Phase 3 skip  : ' + $nP3)
if ($localNs.Count) {
    Write-Host ('This host FSRM Namespace should be: ' + ($localNs -join ', '))
} elseif (@($records | Where-Object { $_.Server -eq $me }).Count) {
    Write-Host 'This host is a replica or unresolved local path. Do not run FSRM against replica folders.'
} else {
    Write-Host ('This host (' + $me + ') is not a DFS target in the queried namespace(s).')
}
Write-Host 'Never set FSRM Namespace to a DFS namespace UNC. Use the LocalPath values above.'
