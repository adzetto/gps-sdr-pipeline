Param(
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Raw = 'data/raw/TGS_L1_E1.dat',
    [string]$Output = 'plots/raw_hist.png',
    [string]$VenvRelative = 'env/.venv-win',
    [string]$SampleDType = 'int8'
)

$ErrorActionPreference = 'Stop'

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
    $pythonBin = Join-Path (Join-Path $Workspace $VenvRelative) 'Scripts/python.exe'
    if (-not (Test-Path $pythonBin)) {
        throw "Python interpreter not found: $pythonBin. Run 'make init' first."
    }

    $rawPath = Join-Path $Workspace $Raw
    if (-not (Test-Path $rawPath)) {
        $fallbacks = @('data/raw/TGS_L1_E1-002.dat')
        foreach ($candidate in $fallbacks) {
            $candidatePath = Join-Path $Workspace $candidate
            if (Test-Path $candidatePath) {
                $rawPath = $candidatePath
                break
            }
        }
        if (-not (Test-Path $rawPath)) {
            throw "$rawPath missing. Run 'make fetch' or set FAIRDATA_DIRECT_URL."
        }
    }

    $outputPath = Join-Path $Workspace $Output
    $outputDir = Split-Path -Parent $outputPath
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    $script = Join-Path $Workspace 'scripts/quick_probe.py'
    & $pythonBin $script $rawPath --output $outputPath --dtype $SampleDType
    if ($LASTEXITCODE -ne 0) {
        throw "quick_probe.py failed (exit code $LASTEXITCODE)"
    }
}
finally {
    if ($MountedDrive) {
        Remove-PSDrive -Name $MountedDrive -Force -ErrorAction SilentlyContinue
    }
}
