Param(
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
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
    $patterns = @(
        'data/interim/*',
        'data/processed/*.bin',
        'data/processed/*.json',
        'logs/*.log',
        'plots/*.png'
    )

    foreach ($pattern in $patterns) {
        $path = Join-Path $Workspace $pattern
        Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
finally {
    if ($MountedDrive) {
        Remove-PSDrive -Name $MountedDrive -Force -ErrorAction SilentlyContinue
    }
}
