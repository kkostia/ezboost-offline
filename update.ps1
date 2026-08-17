param(
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8 } catch {}

$RequiredDll = 'core_assembly_final.dll'
$TargetDll = 'core_assembly_stubbed.dll'
$RequiredLoader = 'ezboost_offline_loader.js'

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

function Install-Payload {
  param($Discord)
  $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
  $artifacts = Join-Path $root 'artifacts'
  $sourceDll = Join-Path $artifacts $RequiredDll
  $sourceLoader = Join-Path $artifacts $RequiredLoader
  if (-not (Test-Path -LiteralPath $sourceDll -PathType Leaf)) { throw "Missing $sourceDll" }
  if (-not (Test-Path -LiteralPath $sourceLoader -PathType Leaf)) { throw "Missing $sourceLoader" }

  $index = Join-Path $Discord.CorePath 'index.js'
  if (Test-Path -LiteralPath $index -PathType Leaf) {
    $loaderHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceLoader).Hash
    $indexHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $index).Hash
    if ($loaderHash -ne $indexHash) {
      $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
      Copy-Item -LiteralPath $index -Destination (Join-Path $Discord.CorePath "index.js.bak.$stamp") -Force
    }
  }
  Copy-Item -LiteralPath $sourceDll -Destination (Join-Path $Discord.CorePath $TargetDll) -Force
  Copy-Item -LiteralPath $sourceLoader -Destination $index -Force

  $nodeCache = Join-Path $artifacts 'node_cache'
  if (Test-Path -LiteralPath $nodeCache -PathType Container) {
    $nodes = @(Get-ChildItem -LiteralPath $nodeCache -File -Filter '*.node' -ErrorAction SilentlyContinue)
    if ($nodes.Count -gt 0) {
      $targetCache = Join-Path $env:APPDATA 'discord\.ezb-cache'
      New-Item -ItemType Directory -Force -Path $targetCache | Out-Null
      foreach ($node in $nodes) {
        Copy-Item -LiteralPath $node.FullName -Destination (Join-Path $targetCache $node.Name) -Force
      }
    }
  }
}

function Start-Discord {
  param($Discord)
  if ($NoLaunch) { return }
  if (Test-Path -LiteralPath $Discord.UpdateExe -PathType Leaf) {
    Start-Process -FilePath $Discord.UpdateExe -Verb RunAs -ArgumentList '--processStart Discord.exe'
  } elseif (Test-Path -LiteralPath $Discord.DiscordExe -PathType Leaf) {
    Start-Process -FilePath $Discord.DiscordExe -Verb RunAs
  }
}

try {
  Write-Host ""
  Write-Host "EZBoost Offline updater" -ForegroundColor Cyan
  Write-Host ""
  Invoke-Step 'New Discord version detected' {
    $script:Discord = Get-LatestDiscordInstall
    Write-Info "Version: $($script:Discord.Version)"
    Write-Info "Target: $($script:Discord.CorePath)"
  }
  Invoke-Step 'Discord stopped' { Stop-Discord }
  Invoke-Step 'Loader and DLL re-applied' { Install-Payload -Discord $script:Discord }
  Invoke-Step 'Discord started as admin' { Start-Discord -Discord $script:Discord }
  Write-Host ""
  Write-Ok 'Update complete.'
  exit 0
} catch {
  Write-Host ""
  Write-Bad $_.Exception.Message
  exit 1
}
