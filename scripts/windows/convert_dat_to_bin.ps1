Param(
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Config = 'configs/pipeline.yaml',
    [string]$VenvRelative = 'env/.venv-win'
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
    $ConfigPath = Join-Path $Workspace $Config
    $PythonBin = Join-Path (Join-Path $Workspace $VenvRelative) 'Scripts/python.exe'
    if (-not (Test-Path $PythonBin)) { throw "Python interpreter not found: $PythonBin" }
    & $PythonBin (Join-Path $Workspace 'scripts/convert_dat_to_bin.py') --config $ConfigPath --root $Workspace
}
finally {
    if ($MountedDrive) {
        Remove-PSDrive -Name $MountedDrive -Force -ErrorAction SilentlyContinue
    }
}
