[CmdletBinding()]
param(
    [string]$InstallerArguments = "--accept-all-defaults"
)

$ErrorActionPreference = "Stop"
$InstallerUrl = "https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1"

function Write-Step {
    param([string]$Message)
    Write-Host "[oci-cli-windows] $Message"
}

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne "Win32NT") {
    throw "This script is intended for Windows. Detected platform: $($PSVersionTable.Platform)"
}

$ExistingOci = Get-Command oci -ErrorAction SilentlyContinue
if ($ExistingOci) {
    Write-Step "OCI CLI is already installed: $(oci --version)"
    exit 0
}

$TempInstaller = Join-Path ([System.IO.Path]::GetTempPath()) "install-oci-cli.ps1"

try {
    Write-Step "Downloading Oracle's official OCI CLI installer."
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $TempInstaller -UseBasicParsing

    Write-Step "Running installer with arguments: $InstallerArguments"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TempInstaller $InstallerArguments

    $UserBin = Join-Path $env:USERPROFILE "bin"
    $env:Path = "$UserBin;$env:Path"

    $InstalledOci = Get-Command oci -ErrorAction SilentlyContinue
    if ($InstalledOci) {
        Write-Step "OCI CLI installed successfully: $(oci --version)"
    }
    else {
        Write-Host @"
OCI CLI installation finished, but 'oci' was not found on PATH.

Add this folder to your user PATH, then open a new terminal:

  $UserBin
"@
    }

    Write-Host @"

Next step:

  oci setup config

This configures your tenancy OCID, user OCID, region, API key, and fingerprint.
"@
}
finally {
    if (Test-Path $TempInstaller) {
        Remove-Item $TempInstaller -Force
    }
}
