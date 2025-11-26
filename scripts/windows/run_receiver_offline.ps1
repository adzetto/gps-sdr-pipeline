Param(
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$VenvRelative = 'env/.venv-win',
    [string]$PythonBin = $null,
    [string]$Input = $(Join-Path $Workspace 'data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin'),
    [string]$LogFile = $(Join-Path $Workspace 'logs/run.log')
)

function Resolve-WorkspacePath {
    param([string]$Path)
    if ($Path -like '\\\\*') {
        $letters = @('Z','Y','X','W','V','U','T','S','R')
        foreach ($letter in $letters) {
            if (-not (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) {
                $drive = New-PSDrive -Name $letter -PSProvider FileSystem -Root $Path -Scope Script -ErrorAction SilentlyContinue
                if ($drive) {
                    return @{ Path = ("{0}:" -f $drive.Name); Drive = $drive.Name }
                }
            }
        }
        throw "Unable to map $Path to a drive letter."
    }
    return @{ Path = $Path; Drive = $null }
}

$workspaceInfo = Resolve-WorkspacePath -Path $Workspace
$Workspace = $workspaceInfo.Path
$MountedDrive = $workspaceInfo.Drive

try {

if (-not $PythonBin -or $PythonBin.Trim().Length -eq 0) {
    $PythonBin = Join-Path (Join-Path $Workspace $VenvRelative) 'Scripts/python.exe'
}

function Get-AbsolutePath {
    Param(
        [string]$Root,
        [string]$PathValue
    )
    if (-not $PathValue -or $PathValue.Trim().Length -eq 0) {
        return $Root
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

$Repo = Join-Path $Workspace 'external/GPS-SDR-Receiver'
$Config = Join-Path $Repo 'src/gpsglob.py'
$Validator = Join-Path $Workspace 'scripts/validate_run.py'
$MinPrn = if ($Env:RUN_MIN_PRN) { [int]$Env:RUN_MIN_PRN } else { 1 }
$RequireTaskFinish = if ($Env:RUN_REQUIRE_TASK_FINISH -eq '0') { $false } else { $true }
if (-not (Test-Path $PythonBin)) {
    throw "Python interpreter not found: $PythonBin`nRun 'make init' first."
}

$pythonDir = Split-Path -Parent $PythonBin
if ($env:PATH -notlike "$pythonDir*") {
    $env:PATH = "$pythonDir;$env:PATH"
}
if (-not $env:QT_QPA_PLATFORM -or $env:QT_QPA_PLATFORM.Trim().Length -eq 0) {
    $env:QT_QPA_PLATFORM = 'offscreen'
}

$IqPath = Get-AbsolutePath -Root $Workspace -PathValue $Input
$LogPath = Get-AbsolutePath -Root $Workspace -PathValue $LogFile
$LogDir = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if (-not (Test-Path $IqPath)) {
    throw "IQ file not found: $IqPath"
}

$BinName = Split-Path -Leaf $IqPath
$BinDir = Split-Path -Parent $IqPath
$RelPath = ($BinDir -replace '\\','/')

$backup = "$Config.bak"
Copy-Item $Config $backup -Force

try {
    $text = Get-Content $Config -Raw
    $text = $text -replace 'LIVE_MEAS = .*','LIVE_MEAS = False'
    $text = $text -replace 'BIN_DATA = .*',("BIN_DATA = '{0}'" -f $BinName)
    $text = $text -replace 'REL_PATH = .*',("REL_PATH = '{0}'" -f $RelPath)
    Set-Content -Path $Config -Value $text -Encoding UTF8

    Push-Location $Repo
    try {
        & $PythonBin gpssdr.py 2>&1 | Tee-Object -FilePath $LogPath
    }
    finally {
        Pop-Location
    }
    if (Test-Path $Validator) {
        $validatorArgs = @('--log', $LogPath, '--min-prn', $MinPrn)
        if ($RequireTaskFinish) {
            $validatorArgs += '--require-task-finish'
        }
        & $PythonBin $Validator @validatorArgs
    }
}
finally {
    Move-Item $backup $Config -Force
}

}
finally {
    if ($MountedDrive) {
        Remove-PSDrive -Name $MountedDrive -Force -ErrorAction SilentlyContinue
    }
}
