<# =============================================================================
.DESCRIPTION
    One-shot bootstrapper for a fresh PS.SSL environment. Installs openssl
    using the appropriate package manager for the current OS, clones the
    module into the user-scope PowerShell modules folder, and copies the
    example scripts next to the user's home directory for quick exploration.
.NOTES
    Status: Stable

    - Requires PowerShell 7.0 or later (uses $IsWindows / $IsMacOS / $IsLinux).
    - Idempotent: skips openssl install when already on PATH; skips git clone
      when the destination already exists.
    - Windows openssl install uses winget. macOS uses Homebrew. Linux uses
      apt-get when present, otherwise dnf, otherwise prints a manual hint.
============================================================================= #>

#requires -Version 7.0

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# STEP 1: Install openssl (skip when already on PATH)
# -----------------------------------------------------------------------------
if (Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue) {
    Write-Verbose -Message 'openssl already on PATH; skipping install.'
}
elseif ($IsWindows) {
    if (-not (Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Error -Message 'winget not found. Install App Installer from the Microsoft Store or install openssl manually.' -ErrorAction Stop
    }
    $wingetArgs = @(
        'install', '--Id', 'ShiningLight.OpenSSL',
        '--silent', '--accept-source-agreements', '--accept-package-agreements'
    )
    & winget @wingetArgs
}
elseif ($IsMacOS) {
    if (-not (Get-Command -Name 'brew' -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Error -Message 'Homebrew not found. Install from https://brew.sh and re-run this script.' -ErrorAction Stop
    }
    & brew install 'openssl@3'
}
elseif ($IsLinux) {
    if (Get-Command -Name 'apt-get' -CommandType Application -ErrorAction SilentlyContinue) {
        & sudo apt-get update
        & sudo apt-get install -y openssl
    }
    elseif (Get-Command -Name 'dnf' -CommandType Application -ErrorAction SilentlyContinue) {
        & sudo dnf install -y openssl
    }
    else {
        Write-Error -Message 'No supported package manager (apt-get, dnf) detected. Install openssl manually and re-run.' -ErrorAction Stop
    }
}
else {
    Write-Error -Message 'Unsupported operating system.' -ErrorAction Stop
}

# -----------------------------------------------------------------------------
# STEP 2: Clone PS.SSL into the first entry of $env:PSModulePath
# -----------------------------------------------------------------------------
if (-not (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Error -Message 'git not found on PATH. Install git and re-run this script.' -ErrorAction Stop
}

$moduleParent = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
$modulePath = Join-Path -Path $moduleParent -ChildPath 'PS.SSL'

if (-not (Test-Path -Path $moduleParent)) {
    New-Item -Path $moduleParent -ItemType Directory -Force | Out-Null
}

if (Test-Path -Path $modulePath) {
    Write-Verbose -Message "PS.SSL already present at [$modulePath]; skipping clone."
}
else {
    & git clone 'https://github.com/jjohns-dev/PS.SSL.git' $modulePath
}

# -----------------------------------------------------------------------------
# STEP 3: Copy examples next to the user's home folder for easy access
# -----------------------------------------------------------------------------
$examplesSource = Join-Path -Path $modulePath -ChildPath 'examples'
$examplesDestination = Join-Path -Path $HOME -ChildPath 'ps.ssl-examples'

if (Test-Path -Path $examplesDestination) {
    Write-Verbose -Message "Examples folder already exists at [$examplesDestination]; skipping copy."
}
else {
    Copy-Item -Path $examplesSource -Destination $examplesDestination -Recurse
}

Write-Output ''
Write-Output "PS.SSL installed at:  $modulePath"
Write-Output "Example scripts at:   $examplesDestination"
Write-Output ''
Write-Output 'Next: Import-Module PS.SSL ; Get-Command -Module PS.SSL'
