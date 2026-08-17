param(
  [string]$Repo = 'kkostia/ezboost-offline',
  [string]$Version = 'latest',
  [string]$ReleaseZipName = 'ezboost-offline-v1.0.zip',
  [switch]$NoLaunch,
  [switch]$SkipLegacyCleanup,
  [switch]$KeepDownloadedPackage
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8 } catch {}

$ProductName = 'EZBoost Offline'
$HostMarker = '# EZB-OFFLINE'
$TelemetryHost = 'ezboost.fly.dev'
$RequiredDll = 'core_assembly_final.dll'
$TargetDll = 'core_assembly_stubbed.dll'
$RequiredLoader = 'ezboost_offline_loader.js'

function Write-Info { param([string]$Message) Write-Host "   $Message" -ForegroundColor DarkGray }
function Write-Ok { param([string]$Message) Write-Host "✅ $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "⚠️  $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "❌ $Message" -ForegroundColor Red }

function Invoke-Step {
  param(
    [string]$Name,
    [scriptblock]$Action,
    [switch]$NonFatal
  )
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

function Start-ElevatedSelf {
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Quote-Argument $PSCommandPath),
    '-Repo', (Quote-Argument $Repo),
    '-Version', (Quote-Argument $Version),
    '-ReleaseZipName', (Quote-Argument $ReleaseZipName)
  )
  if ($NoLaunch) { $args += '-NoLaunch' }
  if ($SkipLegacyCleanup) { $args += '-SkipLegacyCleanup' }
  if ($KeepDownloadedPackage) { $args += '-KeepDownloadedPackage' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList ($args -join ' ')
}

function Get-ScriptRoot {
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
  return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-ReleaseZipUrl {
  if ($env:EZB_REPO -and $Repo -eq 'kkostia/ezboost-offline') {
    $script:Repo = $env:EZB_REPO
  }
  if ($Repo -eq 'USERNAME/ezboost-offline') {
    throw 'Repo is still USERNAME/ezboost-offline. Edit install.ps1 or run with -Repo owner/ezboost-offline.'
  }
  if ($Version -eq 'latest') {
    return "https://github.com/$Repo/releases/latest/download/$ReleaseZipName"
  }
  return "https://github.com/$Repo/releases/download/$Version/$ReleaseZipName"
}

function Invoke-DownloadFile {
  param(
    [string]$Uri,
    [string]$OutFile
  )
  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $headers.Authorization = "Bearer $env:GITHUB_TOKEN"
    $headers.Accept = 'application/octet-stream'
  }
  if ($headers.Count -gt 0) {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $headers -OutFile $OutFile
  } else {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
  }
}

function Ensure-FullPackage {
  $root = Get-ScriptRoot
  $artifacts = Join-Path $root 'artifacts'
  $dll = Join-Path $artifacts $RequiredDll
  $loader = Join-Path $artifacts $RequiredLoader
  if ((Test-Path -LiteralPath $dll -PathType Leaf) -and
      (Test-Path -LiteralPath $loader -PathType Leaf)) {
    return $root
  }

  $url = Get-ReleaseZipUrl
  $downloadRoot = Join-Path $env:TEMP ('ezboost-offline-' + [guid]::NewGuid().ToString('N'))
  $zipPath = $downloadRoot + '.zip'
  New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
  Write-Info "Standalone install.ps1 detected; downloading full package:"
  Write-Info $url
  Invoke-DownloadFile -Uri $url -OutFile $zipPath
  Expand-Archive -LiteralPath $zipPath -DestinationPath $downloadRoot -Force
  if (-not $KeepDownloadedPackage) {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
  }

  $candidate = Get-ChildItem -LiteralPath $downloadRoot -Recurse -File -Filter 'install.ps1' |
    Where-Object {
      $candidateRoot = Split-Path -Parent $_.FullName
      (Test-Path -LiteralPath (Join-Path $candidateRoot "artifacts\$RequiredDll") -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $candidateRoot "artifacts\$RequiredLoader") -PathType Leaf)
    } |
    Select-Object -First 1
  if (-not $candidate) {
    throw "Release ZIP does not contain artifacts\$RequiredDll and artifacts\$RequiredLoader."
  }
  return (Split-Path -Parent $candidate.FullName)
}

function Stop-Discord {
  $processes = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) { return }
  $processes | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
}

function Stop-LegacyProcesses {
  $legacy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like '*ragebots*' -or $_.ProcessName -like '*ragebot*'
  })
  if ($legacy.Count -eq 0) {
    Write-Info 'No legacy Ragebots processes found.'
    return
  }
  foreach ($p in $legacy) {
    Write-Info "Stopping legacy process: $($p.ProcessName) [$($p.Id)]"
  }
  $legacy | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-PathInside {
  param([string]$Path, [string]$Root)
  $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-LoggedPath {
  param(
    [string]$Path,
    [string]$SafeRoot,
    [string]$Reason
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  if (-not (Test-PathInside -Path $Path -Root $SafeRoot)) {
    throw "Refusing to remove outside safe root: $Path"
  }
  Write-Info "Remove: $Path ($Reason)"
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
  return $true
}

function Test-DirectoryContainsOriginalAsar {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $hits = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -match '(?i)(_?original[_\.-]?asar|_original\.asar|original\.asar|original_asar)'
    } |
    Select-Object -First 1)
  return ($hits.Count -gt 0)
}

function Clear-LegacyDesktopFiles {
  $removed = 0
  $usersRoot = 'C:\Users'
  if (-not (Test-Path -LiteralPath $usersRoot -PathType Container)) { return }
  $profiles = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue)
  foreach ($profile in $profiles) {
    $desktop = Join-Path $profile.FullName 'Desktop'
    if (-not (Test-Path -LiteralPath $desktop -PathType Container)) { continue }

    $matches = @(Get-ChildItem -LiteralPath $desktop -Force -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -like '*ragebots*' -or
        $_.Name -like '*ragebot*' -or
        $_.Name -like '*frozen_ragebots*' -or
        $_.Name -like '*FINALFISHBOT*'
      })
    foreach ($item in $matches) {
      if (Remove-LoggedPath -Path $item.FullName -SafeRoot $desktop -Reason 'legacy desktop match') { $removed++ }
    }

    $desktopBot = Join-Path $desktop 'bot'
    if (Test-DirectoryContainsOriginalAsar -Path $desktopBot) {
      if (Remove-LoggedPath -Path $desktopBot -SafeRoot $desktop -Reason 'Desktop\bot contains original_asar') { $removed++ }
    }

    $ultimate = Join-Path $desktop 'ultimate'
    if (Test-Path -LiteralPath $ultimate -PathType Container) {
      $ultimateMatches = @(Get-ChildItem -LiteralPath $ultimate -Force -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -like 'frozen_ragebots*' -or
          $_.Name -like '*FINALFISHBOT*' -or
          $_.Name -like '*ragebots*' -or
          $_.Name -like '*ragebot*'
        })
      foreach ($item in $ultimateMatches) {
        if (Remove-LoggedPath -Path $item.FullName -SafeRoot $ultimate -Reason 'legacy ultimate working directory') { $removed++ }
      }
    }
  }
  Write-Info "Legacy desktop cleanup removed $removed item(s)."
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
  $fallback = Get-ChildItem -LiteralPath $modules -Directory -Filter 'discord_desktop_core-*' -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'discord_desktop_core' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
  return $fallback
}

function Get-LatestDiscordInstall {
  $apps = Get-DiscordApps
  foreach ($app in $apps) {
    $core = Get-DesktopCorePath -App $app
    if ($core) {
      return [pscustomobject]@{
        App = $app
        AppPath = $app.FullName
        CorePath = $core
        DiscordExe = Join-Path $app.FullName 'Discord.exe'
        UpdateExe = Join-Path (Split-Path -Parent $app.FullName) 'Update.exe'
        ResourcesPath = Join-Path $app.FullName 'resources'
        Version = $app.Name.Substring(4)
      }
    }
  }
  throw 'Discord is not installed or discord_desktop_core was not found.'
}

function Restore-IndexFromLatestBackup {
  param([string]$CorePath)
  $index = Join-Path $CorePath 'index.js'
  $backup = Get-ChildItem -LiteralPath $CorePath -File -Filter 'index.js.bak.*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($backup) {
    Copy-Item -LiteralPath $backup.FullName -Destination $index -Force
    Write-Info "Restored legacy-modified index.js from $($backup.Name)"
    return $true
  }
  return $false
}

function Clear-LegacyDiscordModifications {
  $apps = Get-DiscordApps
  foreach ($app in $apps) {
    $core = Get-DesktopCorePath -App $app
    if ($core) {
      $index = Join-Path $core 'index.js'
      if (Test-Path -LiteralPath $index -PathType Leaf) {
        $text = Get-Content -Raw -LiteralPath $index -ErrorAction SilentlyContinue
        if ($text -match '(?i)ragebots|ragebot|offline_fishbot|qa_cache|qa_harness') {
          if (-not (Restore-IndexFromLatestBackup -CorePath $core)) {
            Write-Warn "Legacy-looking index.js found but no backup exists: $index"
          }
        }
      }
      $legacyNames = @(Get-ChildItem -LiteralPath $core -Force -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -match '(?i)ragebots|ragebot|offline_fishbot|qa_cache|qa_harness'
        })
      foreach ($item in $legacyNames) {
        if ($item.Name -ieq 'index.js') { continue }
        Remove-LoggedPath -Path $item.FullName -SafeRoot $core -Reason 'legacy Discord module file/folder' | Out-Null
      }
    }

    $resources = Join-Path $app.FullName 'resources'
    if (Test-Path -LiteralPath $resources -PathType Container) {
      $appAsar = Join-Path $resources 'app.asar'
      $originalAsar = Join-Path $resources '_original.asar'
      if ((Test-Path -LiteralPath $originalAsar -PathType Leaf) -and
          -not (Test-Path -LiteralPath $appAsar -PathType Leaf)) {
        Move-Item -LiteralPath $originalAsar -Destination $appAsar -Force
        Write-Info "Restored app.asar from _original.asar in $resources"
      }
      $extraAsars = @(Get-ChildItem -LiteralPath $resources -File -Filter '*.asar' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine 'app.asar' })
      foreach ($asar in $extraAsars) {
        Remove-LoggedPath -Path $asar.FullName -SafeRoot $resources -Reason 'legacy non-app .asar' | Out-Null
      }
      $resourcesApp = Join-Path $resources 'app'
      if (Test-Path -LiteralPath $resourcesApp -PathType Container) {
        $looksLegacy = $false
        foreach ($probe in @('index.js', 'package.json')) {
          $probePath = Join-Path $resourcesApp $probe
          if (Test-Path -LiteralPath $probePath -PathType Leaf) {
            $probeText = Get-Content -Raw -LiteralPath $probePath -ErrorAction SilentlyContinue
            if ($probeText -match '(?i)ragebots|ragebot|offline_fishbot|qa_cache|qa_harness') {
              $looksLegacy = $true
            }
          }
        }
        if ($looksLegacy) {
          Remove-LoggedPath -Path $resourcesApp -SafeRoot $resources -Reason 'legacy resources\app loader' | Out-Null
        }
      }
    }
  }
}

function Copy-IfDifferent {
  param([string]$Source, [string]$Destination)
  $copy = $true
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
    $dstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
    $copy = ($srcHash -ne $dstHash)
  }
  if ($copy) {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
  }
}

function Install-Payload {
  param([string]$PackageRoot)
  $artifacts = Join-Path $PackageRoot 'artifacts'
  $sourceDll = Join-Path $artifacts $RequiredDll
  $sourceLoader = Join-Path $artifacts $RequiredLoader
  if (-not (Test-Path -LiteralPath $sourceDll -PathType Leaf)) { throw "Missing $sourceDll" }
  if (-not (Test-Path -LiteralPath $sourceLoader -PathType Leaf)) { throw "Missing $sourceLoader" }

  $discord = Get-LatestDiscordInstall
  $index = Join-Path $discord.CorePath 'index.js'
  $targetDllPath = Join-Path $discord.CorePath $TargetDll
  if (-not (Test-Path -LiteralPath $discord.CorePath -PathType Container)) {
    throw "Target directory missing: $($discord.CorePath)"
  }

  if (Test-Path -LiteralPath $index -PathType Leaf) {
    $loaderHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceLoader).Hash
    $indexHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $index).Hash
    if ($loaderHash -ne $indexHash) {
      $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
      $backup = Join-Path $discord.CorePath "index.js.bak.$stamp"
      Copy-Item -LiteralPath $index -Destination $backup -Force
      Write-Info "Backup: $backup"
    } else {
      Write-Info 'index.js is already patched; backup skipped.'
    }
  } else {
    Write-Warn "index.js did not exist in $($discord.CorePath); creating it."
  }

  Copy-Item -LiteralPath $sourceDll -Destination $targetDllPath -Force
  Copy-Item -LiteralPath $sourceLoader -Destination $index -Force
  Write-Info "Installed into Discord $($discord.Version): $($discord.CorePath)"

  $nodeCache = Join-Path $artifacts 'node_cache'
  if (Test-Path -LiteralPath $nodeCache -PathType Container) {
    $nodes = @(Get-ChildItem -LiteralPath $nodeCache -File -Filter '*.node' -ErrorAction SilentlyContinue)
    if ($nodes.Count -gt 0) {
      $targetCache = Join-Path $env:APPDATA 'discord\.ezb-cache'
      New-Item -ItemType Directory -Force -Path $targetCache | Out-Null
      foreach ($node in $nodes) {
        Copy-Item -LiteralPath $node.FullName -Destination (Join-Path $targetCache $node.Name) -Force
        Write-Info "Copied node cache: $($node.Name)"
      }
    } else {
      Write-Info 'No .node files provided; node cache step skipped.'
    }
  }

  return $discord
}

function Set-HostsBlock {
  $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (-not (Test-Path -LiteralPath $hosts -PathType Leaf)) {
    throw "hosts file not found: $hosts"
  }
  $lines = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue)
  $kept = @($lines | Where-Object {
    $_ -notmatch [regex]::Escape($HostMarker) -and
    $_ -notmatch "(?i)\b$([regex]::Escape($TelemetryHost))\b"
  })
  $kept += "0.0.0.0 $TelemetryHost $HostMarker"
  Set-Content -LiteralPath $hosts -Value $kept -Encoding ASCII -Force
}

function Start-DiscordElevated {
  param($Discord)
  if ($NoLaunch) {
    Write-Info 'Launch skipped by -NoLaunch.'
    return
  }
  if (Test-Path -LiteralPath $Discord.UpdateExe -PathType Leaf) {
    Start-Process -FilePath $Discord.UpdateExe -Verb RunAs -ArgumentList '--processStart Discord.exe'
    return
  }
  if (Test-Path -LiteralPath $Discord.DiscordExe -PathType Leaf) {
    Start-Process -FilePath $Discord.DiscordExe -Verb RunAs
    return
  }
  throw 'Discord executable was not found.'
}

try {
  $startedAt = Get-Date
  Write-Host ""
  Write-Host "$ProductName installer" -ForegroundColor Cyan
  Write-Host ""

  if (-not (Test-Administrator)) {
    Write-Info 'Administrator rights required; requesting UAC.'
    Start-ElevatedSelf
    exit 0
  }

  $packageRoot = Ensure-FullPackage
  Invoke-Step 'Artifacts ready' { 
    if (-not (Test-Path -LiteralPath (Join-Path $packageRoot "artifacts\$RequiredDll") -PathType Leaf)) { throw 'DLL missing' }
    if (-not (Test-Path -LiteralPath (Join-Path $packageRoot "artifacts\$RequiredLoader") -PathType Leaf)) { throw 'loader missing' }
  }
  if (-not $SkipLegacyCleanup) {
    Invoke-Step 'Legacy Ragebots processes stopped' { Stop-LegacyProcesses } -NonFatal
    Invoke-Step 'Legacy desktop files removed' { Clear-LegacyDesktopFiles } -NonFatal
    Invoke-Step 'Discord legacy loaders cleaned' { Clear-LegacyDiscordModifications } -NonFatal
  } else {
    Write-Warn 'Legacy cleanup skipped by -SkipLegacyCleanup.'
  }
  Invoke-Step 'Discord detected' { $script:DetectedDiscord = Get-LatestDiscordInstall }
  Invoke-Step 'Discord stopped' { Stop-Discord }
  Invoke-Step 'Payload installed' { $script:InstalledDiscord = Install-Payload -PackageRoot $packageRoot }
  Invoke-Step 'Telemetry host blocked' { Set-HostsBlock }
  Invoke-Step 'Discord started as admin' { Start-DiscordElevated -Discord $script:InstalledDiscord }

  $elapsed = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
  Write-Host ""
  Write-Ok "Done in ${elapsed}s."
  exit 0
} catch {
  Write-Host ""
  Write-Bad $_.Exception.Message
  exit 1
}
