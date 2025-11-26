Param(
    [string]$FairUrl = $Env:FAIRDATA_DIRECT_URL,
    [string]$FairSha = $Env:FAIRDATA_SHA256,
    [string]$HiDriveUrl = $Env:HIDRIVE_FILE_URL,
    [string]$HiDriveName = $(if ($Env:HIDRIVE_FILENAME) { $Env:HIDRIVE_FILENAME } else { 'hidrive_sample.bin' }),
    [string]$ChecksumManifest = $(if ($Env:CHECKSUM_MANIFEST) { $Env:CHECKSUM_MANIFEST } else { $null })
)

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Resolve-WorkspacePath {
    param([string]$Path)
    if ($Path -like '\\\\*') {
        $letters = @('Z','Y','X','W','V','U','T','S','R')
        foreach ($letter in $letters) {
            if (-not (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) {
                $cmd = "net use $($letter): `"$Path`" /persistent:no"
                & cmd.exe /c $cmd 2>$null
                if ($LASTEXITCODE -eq 0) {
                    return @{ Path = ("{0}:" -f $letter); Drive = $letter }
                }
            }
        }
        throw "Unable to map $Path to a drive letter."
    }
    return @{ Path = $Path; Drive = $null }
}

$workspaceInfo = Resolve-WorkspacePath -Path $Root
$Root = $workspaceInfo.Path
$MountedDrive = $workspaceInfo.Drive

try {

$LogDir = Join-Path $Root 'logs'
$RawDir = Join-Path $Root 'data/raw'
$LogFile = Join-Path $LogDir 'fetch.log'
New-Item -ItemType Directory -Force -Path $LogDir, $RawDir | Out-Null
if (-not $ChecksumManifest -or $ChecksumManifest.Trim().Length -eq 0) {
    $ChecksumManifest = Join-Path $Root 'configs/checksums.txt'
}

function Write-Log($Message) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$stamp] [fetch] $Message"
    $line | Tee-Object -FilePath $LogFile -Append
}

function Download-Resume($Url, $Destination) {
    if (-not $Url) { return }
    Write-Log "Downloading $Url -> $Destination"
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $cmd = "curl"
    & $cmd -L --retry 5 -C - -o $Destination $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
}

function Verify-Sha($File, $Expected) {
    if (-not $Expected) { return }
    $actual = (Get-FileHash -Algorithm SHA256 $File).Hash.ToLower()
    if ($actual -ne $Expected.ToLower()) {
        throw "SHA mismatch for $File. Expected $Expected got $actual"
    }
    Write-Log "SHA256 OK for $File"
}

function Get-ManifestChecksum {
    Param([string]$FileName)
    if (-not (Test-Path $ChecksumManifest)) {
        return $null
    }
    foreach ($line in Get-Content $ChecksumManifest) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#')) { continue }
        $parts = $trim -split '\s+',2
        if ($parts.Length -ge 2 -and $parts[0] -eq $FileName) {
            return $parts[1].ToLower()
        }
    }
    return $null
}

Write-Log "Starting fetch pipeline"
if ($FairUrl) {
    $fairDest = Join-Path $RawDir 'TGS_L1_E1.dat'
    Download-Resume $FairUrl $fairDest
    $checksum = if ($FairSha) { $FairSha } else { Get-ManifestChecksum -FileName 'TGS_L1_E1.dat' }
    if ($checksum) {
        Write-Log "Using checksum for $(Split-Path -Leaf $fairDest)"
    }
    Verify-Sha $fairDest $checksum
} else {
    Write-Log 'FAIRDATA_DIRECT_URL not set. Provide direct link.'
}

if ($HiDriveUrl) {
    $hidriveDest = Join-Path $RawDir $HiDriveName
    Download-Resume $HiDriveUrl $hidriveDest
    $hidriveChecksum = Get-ManifestChecksum -FileName $HiDriveName
    if ($hidriveChecksum) {
        Write-Log "Using checksum for $HiDriveName"
        Verify-Sha $hidriveDest $hidriveChecksum
    }
} else {
    Write-Log 'HIDRIVE_FILE_URL not set. Provide HiDrive link.'
}

Write-Log "Fetch pipeline finished"

}
finally {
    if ($MountedDrive) {
        & cmd.exe /c "net use $($MountedDrive): /delete /y" 2>&1 | Out-Null
    }
}
