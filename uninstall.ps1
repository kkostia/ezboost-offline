param(
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8 } catch {}

$HostMarker = '# EZB-OFFLINE'
$TelemetryHost = 'ezboost.fly.dev'
$TargetDll = 'core_assembly_stubbed.dll'

function Write-Info { param([string]$Message) Write-Host "   $Message" -ForegroundColor DarkGray }
function Write-Ok { param([string]$Message) Write-Host "✅ $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "⚠️  $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "❌ $Message" -ForegroundColor Red }

function Invoke-Step {
  param([string]$Name, [scriptblock]$Action, [switch]$NonFatal)
  try {
    & $Action
    Write-Ok $Name
  } catch {
    if ($NonFatal) {
      Write-Warn "$Name — $($_.Exception.Message)"
    } else {
      Write-Bad "$Name — $($_.Exception.Message)"
      throw
    }
  }
}

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument {
  param([string]$Value)
  return '"' + ($Value -replace '"', '\"') + '"'
}

if (-not (Test-Administrator)) {
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $PSCommandPath))
  if ($NoLaunch) { $args += '-NoLaunch' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList ($args -join ' ')
  exit 0
}

function Stop-Discord {
  $processes = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) { return }
  $processes | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
}

function Get-DiscordApps {
  $discordRoot = Join-Path $env:LOCALAPPDATA 'Discord'
  if (-not (Test-Path -LiteralPath $discordRoot -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $discordRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
    Sort-Object @{ Expression = {
      try { [version]($_.Name.Substring(4)) } catch { [version]'0.0' }
    }; Descending = $true })
}

function Get-DesktopCorePath {
  param([IO.DirectoryInfo]$App)
  $modules = Join-Path $App.FullName 'modules'
  $preferred = Join-Path $modules 'discord_desktop_core-1\discord_desktop_core'
  if (Test-Path -LiteralPath $preferred -PathType Container) { return $preferred }
  return (Get-ChildItem -LiteralPath $modules -Directory -Filter 'discord_desktop_core-*' -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'discord_desktop_core' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1)
}

function Get-LatestDiscordInstall {
  foreach ($app in (Get-DiscordApps)) {
    $core = Get-DesktopCorePath -App $app
    if ($core) {
      return [pscustomobject]@{
        AppPath = $app.FullName
        CorePath = $core
        Version = $app.Name.Substring(4)
        DiscordExe = Join-Path $app.FullName 'Discord.exe'
        UpdateExe = Join-Path (Split-Path -Parent $app.FullName) 'Update.exe'
      }
    }
  }
  throw 'Discord is not installed or discord_desktop_core was not found.'
}

function Restore-Index {
  param($Discord)
  $backup = Get-ChildItem -LiteralPath $Discord.CorePath -File -Filter 'index.js.bak.*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $backup) {
    Write-Warn "No index.js backup found in $($Discord.CorePath)."
    return
  }
  Copy-Item -LiteralPath $backup.FullName -Destination (Join-Path $Discord.CorePath 'index.js') -Force
  Write-Info "Restored index.js from $($backup.Name)"
}

function Remove-Payload {
  param($Discord)
  $dll = Join-Path $Discord.CorePath $TargetDll
  Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue
}

function Remove-HostsBlock {
  $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (-not (Test-Path -LiteralPath $hosts -PathType Leaf)) { return }
  $lines = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue)
  $kept = @($lines | Where-Object {
    $_ -notmatch [regex]::Escape($HostMarker) -and
    $_ -notmatch "(?i)\b$([regex]::Escape($TelemetryHost))\b"
  })
  Set-Content -LiteralPath $hosts -Value $kept -Encoding ASCII -Force
}

function Start-Discord {
  param($Discord)
  if ($NoLaunch) { return }
  if (Test-Path -LiteralPath $Discord.UpdateExe -PathType Leaf) {
    Start-Process -FilePath $Discord.UpdateExe -ArgumentList '--processStart Discord.exe'
  } elseif (Test-Path -LiteralPath $Discord.DiscordExe -PathType Leaf) {
    Start-Process -FilePath $Discord.DiscordExe
  }
}

try {
  Write-Host ""
  Write-Host "EZBoost Offline uninstaller" -ForegroundColor Cyan
  Write-Host ""
  Invoke-Step 'Discord detected' { $script:Discord = Get-LatestDiscordInstall }
  Invoke-Step 'Discord stopped' { Stop-Discord }
  Invoke-Step 'index.js restored' { Restore-Index -Discord $script:Discord } -NonFatal
  Invoke-Step 'DLL removed' { Remove-Payload -Discord $script:Discord } -NonFatal
  Invoke-Step 'hosts entries removed' { Remove-HostsBlock } -NonFatal
  Invoke-Step 'Discord restarted' { Start-Discord -Discord $script:Discord } -NonFatal
  Write-Host ""
  Write-Ok 'Uninstall complete.'
  exit 0
} catch {
  Write-Host ""
  Write-Bad $_.Exception.Message
  exit 1
}
