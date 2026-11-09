# Invoke-ChargebackWizard.ps1
# Chargeback One - operator wrapper. This is the script users run.
#
# Interactive: PowerShell wizard. One stage per selection (Discover | Collect | Merge).
# Unattended:  pass -Stage to run one, several, or all stages (Task Scheduler / CI).
#
# This host is the orchestrator. Collect remotes into each authoritative NAS VM via WinRM.
# Sibling scripts stay in this folder; do not call them by hand unless you are debugging.

[CmdletBinding()]
param(
    [ValidateSet('Discover', 'Collect', 'Merge', 'All')]
    [string[]] $Stage,

    [string] $WorkspacePath,
    [string[]] $NamespaceRoot,
    [string] $BusinessUnitAttribute,
    [ValidateSet('Auto', 'Fsrm', 'Ntfs')]
    [string] $Engine = 'Auto',
    [System.Management.Automation.PSCredential] $Credential,
    [int] $TimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$interactive = -not $Stage -or $Stage.Count -eq 0

function Write-Banner {
    Write-Host ''
    Write-Host 'Chargeback One  -  Phase 1 wizard'
    Write-Host 'Windows file-server capacity -> canonical CSV'
    Write-Host ''
}

function Write-NeedToKnow {
    Write-Host 'You will need:'
    Write-Host '  1. WorkspacePath - local folder (D:\Chargeback) or UNC (\\server\share\Chargeback)'
    Write-Host '  2. NamespaceRoot - DFS namespace root, e.g. \\corp.example.internal\files'
    Write-Host '  3. Business Unit AD attribute - usually Department'
    Write-Host '  4. Stage Collect - WinRM to the NAS VMs (current user, or a credential you will be asked for)'
    Write-Host ''
    Write-Host 'This host discovers DFS, remotes Collect, and merges. It does not walk user files from here.'
    Write-Host 'Collect Auto: Server 2016 uses an NTFS owner walk; 2019/2022 use FSRM. Reports run on demand.'
    Write-Host 'Schedule THIS wrapper if you want a clock; do not schedule FSRM.'
    Write-Host ''
}

function Test-IsUnc {
    param([string] $Path)
    return $Path -match '^\\\\[^\\]+\\[^\\]+'
}

function ConvertFrom-MapFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Map file not found: $Path"
    }
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Map file is empty: $Path"
    }
    # PS 5.1: do NOT pipe into ConvertFrom-Json. A JSON array arrives as one
    # pipeline object; @(pipeline) then wraps that array and Show-Map sees 0 rows.
    $parsed = ConvertFrom-Json -InputObject $raw
    return @($parsed)
}

function Initialize-Workspace {
    param([Parameter(Mandatory)][string] $Path)

    $Path = $Path.Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'WorkspacePath is empty.' }

    $kind = if (Test-IsUnc $Path) { 'UNC' } else { 'Local' }
    if ($kind -eq 'Local' -and -not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        } catch {
            throw "Cannot create WorkspacePath ($kind): $Path`n$($_.Exception.Message)"
        }
    }

    $json = Join-Path $Path 'input\json'
    $drop = Join-Path $Path 'input\drop'
    $out  = Join-Path $Path 'output'
    foreach ($d in @($json, $drop, $out)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $probe = Join-Path $json '.write-test'
    try {
        'ok' | Set-Content -LiteralPath $probe -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force
    } catch {
        throw "WorkspacePath is not writable ($kind): $Path"
    }

    Write-Host "Workspace ($kind): $Path"
    [pscustomobject]@{
        Path = $Path
        Kind = $kind
        Json = $json
        Drop = $drop
        Output = $out
        ConfigPath = Join-Path $json 'config.json'
        MapPath = Join-Path $json 'dfs-targets.json'
    }
}

function Read-Config {
    param($Ws)
    if (-not (Test-Path -LiteralPath $Ws.ConfigPath)) { return $null }
    ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $Ws.ConfigPath)
}

function Save-Config {
    param($Ws, [string[]] $Roots, [string] $Bu)
    $obj = [pscustomobject]@{
        WorkspacePath          = $Ws.Path
        NamespaceRoot          = @($Roots)
        BusinessUnitAttribute  = $Bu
        UpdatedUtc             = [datetime]::UtcNow.ToString('o')
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Ws.ConfigPath -Encoding UTF8
}

function Read-Default {
    param([string] $Label, [string] $Current, [switch] $Required)
    $hint = if ($Current) { $Current } else { $(if ($Required) { 'required' } else { 'optional' }) }
    $value = Read-Host "$Label [$hint]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
    return $value.Trim()
}

function Get-MapRows {
    param($Ws)
    if (-not (Test-Path -LiteralPath $Ws.MapPath)) {
        throw "No target map at $($Ws.MapPath). Run Discover first."
    }
    return @(ConvertFrom-MapFile -Path $Ws.MapPath)
}

function Show-Map {
    param($Rows)
    $list = @($Rows)
    Write-Host ('Map rows : {0}' -f $list.Count)
    foreach ($r in $list) {
        $np = [string]$r.NamespacePath
        $sv = [string]$r.Server
        $lp = [string]$r.LocalPath
        $rl = [string]$r.Role
        $st = [string]$r.State
        Write-Host ('  {0}  |  {1}  |  {2}  |  {3}  |  {4}' -f $np, $sv, $lp, $rl, $st)
    }
    Write-Host ('Authoritative : {0}' -f @($list | Where-Object { [string]$_.Role -eq 'authoritative' }).Count)
    Write-Host ('Replica skip  : {0}' -f @($list | Where-Object { [string]$_.Role -eq 'replica' }).Count)
    Write-Host ('Phase 3 skip  : {0}' -f @($list | Where-Object { [string]$_.Role -eq 'phase3-synology' }).Count)
}

function Invoke-DiscoverStage {
    param($Ws, [string[]] $Roots, [bool] $PromptReview)

    if (-not $Roots -or $Roots.Count -eq 0) {
        throw 'NamespaceRoot is required for Discover.'
    }
    $discover = Join-Path $scriptDir 'Get-DfsTargetMap.ps1'
    $tmp = Join-Path $env:TEMP ("dfs-targets-{0}.json" -f $PID)

    Write-Host "Querying DFS-N / DFSR / SMB for: $($Roots -join ', ')"
    & $discover -NamespaceRoot $Roots -OutputPath $tmp

    $rows = @(ConvertFrom-MapFile -Path $tmp)
    if ($rows.Count -eq 0) { throw 'Discovery returned no DFS targets.' }
    Show-Map -Rows $rows

    $missing = @($rows | Where-Object { [string]$_.Role -eq 'authoritative' -and -not $_.LocalPath })
    if ($missing.Count) {
        Write-Warning 'Authoritative targets with no local path (SMB CIM failed). Collect will skip them:'
        foreach ($m in $missing) {
            Write-Host ('  {0}  {1}  {2}' -f $m.Server, $m.TargetPath, $m.NamespacePath)
        }
    }

    if ($PromptReview) {
        $ans = Read-Host 'Save this map to input\json\dfs-targets.json? [Y/n]'
        if ($ans -match '^[nN]') {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            throw 'Discover cancelled. Existing map (if any) was left unchanged.'
        }
    }

    Copy-Item -LiteralPath $tmp -Destination $Ws.MapPath -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "Saved $($Ws.MapPath)"
    Write-Host 'Edit that JSON between stages if a Role is wrong, then run Collect.'
}

function Get-CollectCredential {
    param([System.Management.Automation.PSCredential] $Existing, [bool] $Prompt)
    if ($Existing) { return $Existing }
    if (-not $Prompt) { return $null }
    $ans = Read-Host 'WinRM credential [Enter]=current user, [A]=ask'
    if ($ans -match '^[aA]') { return (Get-Credential) }
    return $null
}

function Invoke-CollectStage {
    param($Ws, [System.Management.Automation.PSCredential] $Cred, [int] $Timeout, [bool] $Prompt, [string] $CollectEngine)

    $rows = Get-MapRows -Ws $Ws
    $auth = @($rows | Where-Object { [string]$_.Role -eq 'authoritative' -and $_.LocalPath })
    if ($auth.Count -eq 0) {
        throw 'No authoritative Windows targets with LocalPath. Re-run Discover or edit dfs-targets.json.'
    }

    $groups = $auth | Group-Object Server
    Write-Host ('Will run Collect (Engine=' + $CollectEngine + ') on:')
    foreach ($g in $groups) {
        Write-Host ("  {0}  {1}" -f $g.Name, (($g.Group.LocalPath | Select-Object -Unique) -join ', '))
    }

    $credToUse = Get-CollectCredential -Existing $Cred -Prompt $Prompt
    $install = Join-Path $scriptDir 'Install-FsrmOwnerReport.ps1'
    $remoteScript = 'C:\ProgramData\ChargebackOne\Install-FsrmOwnerReport.ps1'
    $remoteDrop = 'C:\ProgramData\ChargebackOne\drop'
    $ok = 0
    $fail = New-Object System.Collections.Generic.List[string]

    foreach ($g in $groups) {
        $server = [string]$g.Name
        $namespaces = @($g.Group | Select-Object -ExpandProperty LocalPath -Unique)
        Write-Host ''
        Write-Host "Collect -> $server"
        Write-Host ('  LocalPath: ' + ($namespaces -join ', '))
        $session = $null
        try {
            Write-Host '  WinRM connecting...'
            $sp = @{ ComputerName = $server; ErrorAction = 'Stop' }
            if ($credToUse) { $sp.Credential = $credToUse }
            $session = New-PSSession @sp
            Write-Host '  WinRM session opened'

            Invoke-Command -Session $session -ScriptBlock {
                New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ChargebackOne\drop' | Out-Null
            }
            Write-Host '  copying collector'
            Copy-Item -ToSession $session -Path $install -Destination $remoteScript -Force
            Write-Host '  running collector (PS 5.1 may buffer remote output until it finishes)'

            Invoke-Command -Session $session -ScriptBlock {
                param($p)
                & $p.ScriptPath -Namespace $p.Ns -OutputPath $p.Out -TimeoutSeconds $p.TimeoutSec -Engine $p.Engine -Server $p.ServerName
            } -ArgumentList @(
                [pscustomobject]@{
                    ScriptPath = $remoteScript
                    Ns         = @($namespaces)
                    Out        = $remoteDrop
                    TimeoutSec = $Timeout
                    Engine     = $CollectEngine
                    ServerName = $server
                }
            )

            $remoteFiles = Invoke-Command -Session $session -ScriptBlock {
                param($Out)
                @(Get-ChildItem -Path $Out -Filter *.csv -ErrorAction SilentlyContinue | Select-Object FullName, Name)
            } -ArgumentList $remoteDrop

            if (-not $remoteFiles -or @($remoteFiles).Count -eq 0) {
                throw 'Remote Collect finished but no CSV was found to copy.'
            }
            foreach ($rf in @($remoteFiles)) {
                $destName = '{0}-{1}' -f $server, $rf.Name
                $dest = Join-Path $Ws.Drop $destName
                Copy-Item -FromSession $session -Path $rf.FullName -Destination $dest -Force
                Write-Host "  copied $destName"
            }
            $ok++
        } catch {
            Write-Warning ("{0}: {1}" -f $server, $_.Exception.Message)
            [void]$fail.Add("$server :: $($_.Exception.Message)")
        } finally {
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }

    Write-Host ''
    Write-Host "Collect finished. Servers ok=$ok failed=$($fail.Count). Drop: $($Ws.Drop)"
    if ($fail.Count) {
        Write-Host 'Failures:'
        $fail | ForEach-Object { Write-Host "  $_" }
        if ($ok -eq 0) { throw 'Collect failed on every NAS VM.' }
    }
}

function Invoke-MergeStage {
    param($Ws, [string] $Bu)

    if ([string]::IsNullOrWhiteSpace($Bu)) {
        throw 'BusinessUnitAttribute is required for Merge (e.g. Department).'
    }
    $csv = @(Get-ChildItem -LiteralPath $Ws.Drop -Filter *.csv -File -ErrorAction SilentlyContinue)
    if ($csv.Count -eq 0) { throw "No CSV in $($Ws.Drop). Run Collect first." }

    $merge = Join-Path $scriptDir 'Invoke-ChargebackMerge.ps1'
    $stamp = Get-Date -Format 'yyyy-MM-dd'
    $dated = Join-Path $Ws.Output ("chargeback-{0}.csv" -f $stamp)
    $latest = Join-Path $Ws.Output 'chargeback.csv'

    & $merge -DropFolder $Ws.Drop -TargetMapPath $Ws.MapPath -OutputPath $dated -BusinessUnitAttribute $Bu -ScanDate $stamp
    Copy-Item -LiteralPath $dated -Destination $latest -Force
    Write-Host "Latest copy: $latest"
}

function Resolve-SessionConfig {
    param($Ws)

    $cfg = Read-Config -Ws $Ws
    $roots = @()
    if ($NamespaceRoot) { $roots = @($NamespaceRoot) }
    elseif ($cfg -and $cfg.NamespaceRoot) { $roots = @($cfg.NamespaceRoot) }

    $bu = $BusinessUnitAttribute
    if ([string]::IsNullOrWhiteSpace($bu) -and $cfg) { $bu = [string]$cfg.BusinessUnitAttribute }
    if ([string]::IsNullOrWhiteSpace($bu)) { $bu = 'Department' }

    if ($interactive) {
        $rootHint = if ($roots) { $roots -join ', ' } else { $null }
        $rootText = Read-Default -Label 'NamespaceRoot' -Current $rootHint -Required
        if ($rootText) { $roots = @($rootText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $bu = Read-Default -Label 'Business Unit AD attribute' -Current $bu -Required
    }

    Save-Config -Ws $Ws -Roots $roots -Bu $bu
    return [pscustomobject]@{ Ws = $Ws; Roots = @($roots); Bu = $bu }
}

function Invoke-NamedStage {
    param([string] $Name, $Ctx)
    switch ($Name) {
        'Discover' { Invoke-DiscoverStage -Ws $Ctx.Ws -Roots $Ctx.Roots -PromptReview:$interactive }
        'Collect'  { Invoke-CollectStage -Ws $Ctx.Ws -Cred $Credential -Timeout $TimeoutSeconds -Prompt:$interactive -CollectEngine $Engine }
        'Merge'    { Invoke-MergeStage -Ws $Ctx.Ws -Bu $Ctx.Bu }
        default    { throw "Unknown stage $Name" }
    }
}

# --- entry ---
Write-Banner
if ($interactive) { Write-NeedToKnow }

if (-not $WorkspacePath -and -not $interactive) {
    throw 'Unattended run requires -WorkspacePath.'
}

if ($WorkspacePath) {
    $WsResolved = Initialize-Workspace -Path $WorkspacePath
} elseif ($interactive) {
    $wp = Read-Default -Label 'WorkspacePath (local or UNC)' -Current $null -Required
    if (-not $wp) { throw 'WorkspacePath is required.' }
    $WsResolved = Initialize-Workspace -Path $wp
    $WorkspacePath = $WsResolved.Path
}

$ctx = Resolve-SessionConfig -Ws $WsResolved

if (-not $interactive) {
    $run = @($Stage)
    if ($run -contains 'All') { $run = @('Discover', 'Collect', 'Merge') }
    $order = @('Discover', 'Collect', 'Merge')
    foreach ($s in $order) {
        if ($run -contains $s) {
            Write-Host ''
            Write-Host "=== Stage $s ==="
            Invoke-NamedStage -Name $s -Ctx $ctx
        }
    }
    Write-Host ''
    Write-Host 'Unattended run complete.'
    return
}

$keepGoing = $true
while ($keepGoing) {
    Write-Host ''
    Write-Host "Workspace : $($ctx.Ws.Path)  [$($ctx.Ws.Kind)]"
    Write-Host "Namespace : $($ctx.Roots -join ', ')"
    Write-Host "BU attr   : $($ctx.Bu)"
    Write-Host "Engine    : $Engine"
    Write-Host "Map       : $(if (Test-Path $ctx.Ws.MapPath) { 'present' } else { 'missing - run 1' })"
    $dropN = @(Get-ChildItem -LiteralPath $ctx.Ws.Drop -Filter *.csv -File -ErrorAction SilentlyContinue).Count
    Write-Host "Drop CSVs : $dropN"
    Write-Host ''
    Write-Host '  [1] Discover   - query DFS targets (does not walk files)'
    Write-Host '  [2] Collect    - owner report on authoritative NAS VMs (WinRM; Auto=NTFS on 2016)'
    Write-Host '  [3] Merge      - join AD and write output\chargeback.csv'
    Write-Host '  [Q] Quit'
    Write-Host ''
    $choice = Read-Host 'Select one stage'
    if ($null -eq $choice) { $choice = '' }
    $choice = $choice.Trim()
    switch -Regex ($choice) {
        '^1$'            { Invoke-NamedStage -Name 'Discover' -Ctx $ctx }
        '^2$'            { Invoke-NamedStage -Name 'Collect'  -Ctx $ctx }
        '^3$'            { Invoke-NamedStage -Name 'Merge'    -Ctx $ctx }
        '^(?i)q(uit)?$'  { $keepGoing = $false }
        '^(?i)exit$'     { $keepGoing = $false }
        default          { Write-Host 'Enter 1, 2, 3, or Q.' }
    }
}

Write-Host 'Done.'
