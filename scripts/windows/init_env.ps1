Param(
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$VenvRelative = 'env/.venv-win'
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
        throw "Unable to map $Path to a drive letter via PSDrive."
    }
    return @{ Path = $Path; Drive = $null }
}

$workspaceInfo = Resolve-WorkspacePath -Path $Workspace
$Workspace = $workspaceInfo.Path
$MountedDrive = $workspaceInfo.Drive

try {

function Resolve-PythonCandidate {
    $candidates = @(
        @{ Path = 'py'; Args = @('-3') },
        @{ Path = 'py'; Args = @() },
        @{ Path = 'python3'; Args = @() },
        @{ Path = 'python'; Args = @() }
    )

    foreach ($candidate in $candidates) {
        try {
            $versionArgs = @()
            if ($candidate.Args) { $versionArgs += $candidate.Args }
            $versionArgs += '--version'
            & $candidate.Path @versionArgs *> $null
            return $candidate
        } catch {
            continue
        }
    }

    throw "Python 3 interpreter not found. Install Python 3.11+ or adjust PATH."
}

function Invoke-Python {
    param(
        [hashtable]$Candidate,
        [string[]]$Args,
        [string]$ErrorMessage,
        [string]$ExecutionRoot
    )

    $exe = $Candidate.Path
    $argString = ''
    if ($Candidate.Args) { $argString += ($Candidate.Args -join ' ') + ' ' }
    if ($Args) { $argString += ($Args -join ' ') }
    $command = "$exe $argString"
    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $command -WorkingDirectory $ExecutionRoot -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw $ErrorMessage
    }
}

$venvPath = Join-Path $Workspace $VenvRelative
$pythonCommand = Resolve-PythonCandidate

if (-not (Test-Path $venvPath)) {
    Write-Host "Creating virtual environment at $venvPath"
Invoke-Python -Candidate $pythonCommand -Args @('-m', 'venv', $venvPath) -ErrorMessage 'Virtual environment creation failed.' -ExecutionRoot $Workspace
} else {
    Write-Host "Virtual environment already present at $venvPath"
    $windowsPython = Join-Path $venvPath 'Scripts/python.exe'

    if (-not (Test-Path $windowsPython)) {
        Write-Host "Windows interpreter missing. Recreating virtual environment..."
        Remove-Item -Recurse -Force -LiteralPath $venvPath
        Invoke-Python -Candidate $pythonCommand -Args @('-m', 'venv', $venvPath) -ErrorMessage 'Virtual environment recreation failed.'
    }
}

$pythonBin = Join-Path $venvPath 'Scripts/python.exe'
if (-not (Test-Path $pythonBin)) {
    throw "Virtual environment seems corrupted. Expected interpreter at $pythonBin"
}

function Invoke-Checked {
    param(
        [string]$Exe,
        [string[]]$Args,
        [string]$ErrorMessage
    )

    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

Write-Host "Upgrading pip inside $venvPath"
Invoke-Checked -Exe $pythonBin -Args @('-m', 'pip', 'install', '--upgrade', 'pip') -ErrorMessage 'pip upgrade failed.'

$requirements = Join-Path $Workspace 'external/GPS-SDR-Receiver/requirements.txt'
Write-Host "Installing GPS-SDR-Receiver requirements"
Invoke-Checked -Exe $pythonBin -Args @('-m', 'pip', 'install', '-r', $requirements) -ErrorMessage 'Failed to install GPS-SDR-Receiver requirements.'

Write-Host "Installing workspace python dependencies"
Invoke-Checked -Exe $pythonBin -Args @('-m', 'pip', 'install', 'numpy', 'scipy', 'matplotlib', 'tqdm', 'pyyaml') -ErrorMessage 'Failed to install workspace dependencies.'

}
finally {
    if ($MountedDrive) {
        Remove-PSDrive -Name $MountedDrive -Force -ErrorAction SilentlyContinue
    }
}
