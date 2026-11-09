# Install-FsrmOwnerReport.ps1
# Chargeback One - Phase 1 collector (Windows only).
# Engine Auto: Server 2016 (build <= 14393) uses an NTFS owner walk.
#             2019/2022 use on-demand FSRM Files-by-Owner CSV.
# Engine Ntfs / Fsrm force one path.
# Namespace must be local share roots from Get-DfsTargetMap.ps1, never the DFS UNC.
# Called by Invoke-ChargebackWizard.ps1 (locally or via WinRM).

[CmdletBinding()]
param(
    [string[]] $Namespace,
    [string]   $LocalNamespacesPath,
    [string]   $ReportName = 'Chargeback-FilesByOwner',
    [string]   $OutputPath = 'C:\ProgramData\ChargebackOne\drop',
    [string]   $Server,
    [ValidateSet('Auto', 'Fsrm', 'Ntfs')]
    [string]   $Engine = 'Auto',
    [int]      $TimeoutSeconds = 3600,
    [int]      $MaxOwner = 10000,
    [int]      $MaxFile  = 1000000
)

$ErrorActionPreference = 'Stop'
function Say([string] $m) { Write-Output ('[' + $env:COMPUTERNAME + '] ' + $m) }

if ($LocalNamespacesPath) {
    $discovered = Get-Content -Raw -Path $LocalNamespacesPath | ConvertFrom-Json
    $Namespace = @($discovered)
}

if (-not $Namespace -or $Namespace.Count -eq 0) {
    throw 'No Namespace given. Pass local paths from Get-DfsTargetMap.ps1 (Role=authoritative). Never a DFS UNC.'
}

if (-not $Server) { $Server = $env:COMPUTERNAME }

function Get-OsBuild {
    try {
        return [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    } catch {
        return 0
    }
}

function Write-PathDiagnostics {
    Say '--- path diagnostics ---'
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        Say ('  drive ' + $_.Name + ': ' + $_.Root)
    }
    Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object {
        Say ('  share ' + $_.Name + ' -> ' + $_.Path)
    }
}

function Resolve-ExistingPath {
    param([string] $Wanted)
    if (Test-Path -LiteralPath $Wanted) { return $Wanted }
    $leaf = Split-Path -Leaf $Wanted
    $shares = @(Get-SmbShare -ErrorAction SilentlyContinue)
    $byPath = @($shares | Where-Object { [string]$_.Path -eq $Wanted })
    if ($byPath.Count -gt 0 -and (Test-Path -LiteralPath $byPath[0].Path)) {
        return [string]$byPath[0].Path
    }
    $byName = @($shares | Where-Object { [string]$_.Name -eq $leaf })
    if ($byName.Count -gt 0 -and $byName[0].Path -and (Test-Path -LiteralPath $byName[0].Path)) {
        Say ('  map path missing, using SMB Path for share ' + $leaf + ': ' + $byName[0].Path)
        return [string]$byName[0].Path
    }
    $parent = Split-Path -Parent $Wanted
    if ($parent -and (Test-Path -LiteralPath $parent)) {
        $guess = Join-Path $parent $leaf
        if (Test-Path -LiteralPath $guess) { return $guess }
    }
    foreach ($drv in @('C', 'D', 'E')) {
        $alt = $Wanted -replace '^[A-Za-z]:', ($drv + ':')
        if ($alt -ne $Wanted -and (Test-Path -LiteralPath $alt)) {
            Say ('  map path missing, found same folder on ' + $drv + ': ' + $alt)
            return $alt
        }
    }
    return $null
}

function Invoke-NtfsOwnerWalk {
    param(
        [string[]] $MapPaths,
        [string[]] $WalkPaths,
        [string]   $OutDir,
        [string]   $ServerName
    )
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }
    $acc = @{}
    for ($i = 0; $i -lt $MapPaths.Count; $i++) {
        $mapPath = $MapPaths[$i]
        $walkPath = $WalkPaths[$i]
        Say ('NTFS walk ' + $walkPath + ' (emit Folder=' + $mapPath + ')')
        $files = @(Get-ChildItem -LiteralPath $walkPath -Recurse -Force -File -ErrorAction SilentlyContinue)
        Say ('  files ' + $files.Count)
        foreach ($f in $files) {
            $owner = 'UNKNOWN'
            $sid = ''
            try {
                $sec = $f.GetAccessControl()
                $owner = [string]$sec.Owner
                try {
                    $sid = (New-Object System.Security.Principal.NTAccount($owner)).Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    ).Value
                } catch { }
            } catch { }
            $key = $owner + '|' + $mapPath
            if (-not $acc.ContainsKey($key)) {
                $acc[$key] = [pscustomobject]@{
                    Server = $ServerName
                    Folder = $mapPath
                    Owner  = $owner
                    SID    = $sid
                    Size   = [int64]0
                    Files  = 0
                }
            }
            $acc[$key].Size += [int64]$f.Length
            $acc[$key].Files++
        }
    }
    $csvName = 'ntfs-owner-' + ($ServerName -replace '[^A-Za-z0-9.-]', '_') + '.csv'
    $csvPath = Join-Path $OutDir $csvName
    $rows = @($acc.Values)
    if ($rows.Count -eq 0) {
        $rows = @(
            [pscustomobject]@{
                Server = $ServerName
                Folder = $MapPaths[0]
                Owner  = 'UNKNOWN'
                SID    = ''
                Size   = [int64]0
                Files  = 0
            }
        )
        Say 'NTFS walk found 0 files. CSV will have a placeholder row.'
    }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding ASCII
    Say ('CSV ' + $csvPath)
    return @(Get-Item -LiteralPath $csvPath)
}

Say ('Namespace = ' + ($Namespace -join ', '))
Say ('Output    = ' + $OutputPath)
Say ('Engine    = ' + $Engine)
Say ('Server    = ' + $Server)

$resolved = New-Object System.Collections.ArrayList
$missing = New-Object System.Collections.ArrayList
foreach ($n in @($Namespace)) {
    $hit = Resolve-ExistingPath -Wanted $n
    if ($hit) {
        Say ('  path ok  map=' + $n + ' walk=' + $hit)
        [void]$resolved.Add($hit)
    } else {
        [void]$missing.Add($n)
    }
}
if ($missing.Count -gt 0) {
    Write-PathDiagnostics
    throw ('Namespace path does not exist on this host: ' + ($missing -join ', ') + '. Create the folder (or fix the SMB share Path), then re-run Discover so LocalPath matches a real disk path. This is not an FSRM API error.')
}

$build = Get-OsBuild
Say ('OS build  = ' + $build)
if ($Engine -eq 'Auto') {
    if ($build -gt 0 -and $build -le 14393) {
        $Engine = 'Ntfs'
        Say 'Auto: Server 2016 or older -> NTFS owner walk (skip FSRM)'
    } else {
        $Engine = 'Fsrm'
        Say 'Auto: Server 2019/2022 -> FSRM FilesByOwner'
    }
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
}

if ($Engine -eq 'Ntfs') {
    $null = Invoke-NtfsOwnerWalk -MapPaths @($Namespace) -WalkPaths @($resolved) -OutDir $OutputPath -ServerName $Server
    Say 'NTFS FilesByOwner complete'
    return
}

$feature = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue
if ($feature -and $feature.InstallState -ne 'Installed') {
    Say 'Installing FS-Resource-Manager (first time can take several minutes)...'
    Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools | Out-Null
    Say 'FS-Resource-Manager installed.'
} else {
    Say 'FS-Resource-Manager already installed.'
}

foreach ($svcName in @('SrmSvc', 'SrmReports')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Say ('Starting service ' + $svcName)
        Start-Service -Name $svcName
    }
}

Import-Module FileServerResourceManager

$legacyRoot = Join-Path $env:SystemDrive 'StorageReports'
foreach ($d in @(
        $OutputPath,
        $legacyRoot,
        (Join-Path $legacyRoot 'Interactive'),
        (Join-Path $legacyRoot 'Scheduled'),
        (Join-Path $legacyRoot 'Incident')
    )) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Say ('created ' + $d)
    }
}

$set = Get-Command Set-FsrmSetting -ErrorAction Stop
if ($set.Parameters.ContainsKey('ReportLimitMaxOwner')) {
    Set-FsrmSetting -ReportLimitMaxOwner $MaxOwner
}
if ($set.Parameters.ContainsKey('ReportLimitMaxFile')) {
    Set-FsrmSetting -ReportLimitMaxFile $MaxFile
}
foreach ($loc in @('ReportLocationOnDemand', 'ReportLocationScheduled', 'ReportLocationIncident', 'ReportLocationCsv')) {
    if ($set.Parameters.ContainsKey($loc)) {
        $p = @{ $loc = $OutputPath }
        Set-FsrmSetting @p
        Say ('Set-FsrmSetting -' + $loc + ' ' + $OutputPath)
    }
}

$existing = Get-FsrmStorageReport -Name $ReportName -ErrorAction SilentlyContinue
if ($existing) {
    Say 'Removing leftover Chargeback-FilesByOwner job'
    Remove-FsrmStorageReport -Name $ReportName -Confirm:$false
}

Say 'Creating report job and starting it (non-blocking)...'
$sked = $null
$nst = Get-Command New-FsrmScheduledTask -ErrorAction SilentlyContinue
if ($nst) {
    try {
        if ($nst.Parameters.ContainsKey('Weekly')) {
            $sked = New-FsrmScheduledTask -Weekly Sunday -Time (Get-Date '03:00')
        } elseif ($nst.Parameters.ContainsKey('Days')) {
            $sked = New-FsrmScheduledTask -Days Sunday -Time (Get-Date '03:00')
        } else {
            $sked = New-FsrmScheduledTask -Time (Get-Date '03:00')
        }
        Say 'Dummy schedule created'
    } catch {
        Say ('New-FsrmScheduledTask failed: ' + $_.Exception.Message)
    }
}
$newParams = @{
    Name         = $ReportName
    Namespace    = @($resolved)
    ReportType   = @('FilesByOwner')
    ReportFormat = @('Csv')
}
if ($sked) { $newParams.Schedule = $sked }
try {
    New-FsrmStorageReport @newParams | Out-Null
    Start-FsrmStorageReport -Name $ReportName
    Say 'Start-FsrmStorageReport returned'
} catch {
    Say ('FSRM failed: ' + $_.Exception.Message)
    Say 'Falling back to NTFS owner walk'
    $null = Invoke-NtfsOwnerWalk -MapPaths @($Namespace) -WalkPaths @($resolved) -OutDir $OutputPath -ServerName $Server
    Say 'NTFS FilesByOwner complete (FSRM fallback)'
    return
}
Get-FsrmStorageReport -ErrorAction SilentlyContinue | ForEach-Object {
    Say ('  job ' + $_.Name + ' status=' + $_.Status)
}

$stamp = Get-Date
$deadline = $stamp.AddSeconds($TimeoutSeconds)
$produced = @()
$tick = 0
$searchRoots = @(
    $OutputPath,
    (Join-Path $env:SystemDrive 'StorageReports')
)
do {
    Start-Sleep -Seconds 5
    $tick++
    $elapsed = [int]((Get-Date) - $stamp).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $pct = [int][Math]::Min(99, ($elapsed * 100) / [Math]::Max(1, $TimeoutSeconds))

    $fsrmStatus = 'unknown'
    $fsrmErr = ''
    try {
        $rpt = Get-FsrmStorageReport -Name $ReportName -ErrorAction Stop
        $st = $rpt.Status
        if ($null -eq $st) { $fsrmStatus = 'noprop' }
        elseif ($st -is [int] -or $st -is [uint32] -or $st -is [int64]) {
            switch ([int]$st) {
                1 { $fsrmStatus = 'NotRunning' }
                2 { $fsrmStatus = 'Queued' }
                3 { $fsrmStatus = 'Running' }
                default { $fsrmStatus = 'code' + [string]$st }
            }
        } else { $fsrmStatus = [string]$st }
        if ($rpt.LastError) { $fsrmErr = [string]$rpt.LastError }
    } catch {
        $fsrmStatus = 'notfound'
    }

    $statusLine = 'elapsed ' + $elapsed + 's / ' + $TimeoutSeconds + 's  FSRM=' + $fsrmStatus
    Write-Progress -Activity ('FSRM FilesByOwner ' + $env:COMPUTERNAME) -Status $statusLine -PercentComplete $pct
    if (($tick % 3) -eq 0) { Say ('still running  ' + $statusLine) }

    $found = @()
    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        $found += @(
            Get-ChildItem -Path $root -Recurse -Include *.csv,*.html,*.xml -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $stamp.AddSeconds(-5) -and -not $_.PSIsContainer }
        )
    }
    $csvHits = @($found | Where-Object { $_.Extension -eq '.csv' })
    if ($csvHits.Count -gt 0) {
        foreach ($f in $csvHits) {
            Copy-Item -Path $f.FullName -Destination (Join-Path $OutputPath $f.Name) -Force
        }
        $produced = @(Get-ChildItem -Path $OutputPath -Filter *.csv | Where-Object { $_.LastWriteTime -ge $stamp.AddSeconds(-5) })
        if ($produced.Count -gt 0) { break }
    }

    if ($elapsed -gt 45 -and $csvHits.Count -eq 0) {
        Say 'FSRM produced no CSV in 45s. Falling back to NTFS owner walk.'
        Write-Progress -Activity ('FSRM FilesByOwner ' + $env:COMPUTERNAME) -Completed
        $null = Invoke-NtfsOwnerWalk -MapPaths @($Namespace) -WalkPaths @($resolved) -OutDir $OutputPath -ServerName $Server
        Say 'NTFS FilesByOwner complete (FSRM timeout fallback)'
        return
    }
    if ($fsrmStatus -eq 'NotRunning' -and $elapsed -gt 30 -and $csvHits.Count -eq 0 -and $fsrmErr) {
        throw ('FSRM stopped with error: ' + $fsrmErr)
    }
} while ((Get-Date) -lt $deadline)

Write-Progress -Activity ('FSRM FilesByOwner ' + $env:COMPUTERNAME) -Completed

if ($produced.Count -eq 0) {
    Say 'FSRM produced no CSV. Falling back to NTFS owner walk.'
    $null = Invoke-NtfsOwnerWalk -MapPaths @($Namespace) -WalkPaths @($resolved) -OutDir $OutputPath -ServerName $Server
    Say 'NTFS FilesByOwner complete (FSRM empty fallback)'
    return
}

Say 'FSRM FilesByOwner complete'
foreach ($f in $produced) { Say ('CSV ' + $f.FullName) }
