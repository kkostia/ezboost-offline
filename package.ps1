param(
  [string]$Version = 'v1.0',
  [string]$Repo = 'kkostia/ezboost-offline',
  [string]$OutDir,
  [string]$OutFile
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8 } catch {}

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $root 'release'
}
if ([string]::IsNullOrWhiteSpace($OutFile)) {
  $safeVersion = $Version.TrimStart('v')
  $OutFile = Join-Path $OutDir "ezboost-offline-v$safeVersion.zip"
}

$required = @(
  'install.ps1',
  'uninstall.ps1',
  'update.ps1',
  'package.ps1',
  'README.md',
  'artifacts\core_assembly_final.dll',
  'artifacts\ezboost_offline_loader.js'
)

foreach ($relative in $required) {
  $path = Join-Path $root $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required release file: $relative"
  }
}

$stage = Join-Path $env:TEMP ('ezboost-package-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  foreach ($relative in @('install.ps1', 'uninstall.ps1', 'update.ps1', 'package.ps1', 'README.md')) {
    $sourcePath = Join-Path $root $relative
    $targetPath = Join-Path $stage $relative
    if ($relative -eq 'install.ps1') {
      $text = Get-Content -Raw -LiteralPath $sourcePath
      $text = $text -replace "\[string\]\`$Repo = '[^']+'", "[string]`$Repo = '$Repo'"
      Set-Content -LiteralPath $targetPath -Value $text -Encoding UTF8 -Force
    } else {
      Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'artifacts') | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'artifacts\core_assembly_final.dll') -Destination (Join-Path $stage 'artifacts\core_assembly_final.dll') -Force
  Copy-Item -LiteralPath (Join-Path $root 'artifacts\ezboost_offline_loader.js') -Destination (Join-Path $stage 'artifacts\ezboost_offline_loader.js') -Force

  $nodeSource = Join-Path $root 'artifacts\node_cache'
  if (Test-Path -LiteralPath $nodeSource -PathType Container) {
    $nodeTarget = Join-Path $stage 'artifacts\node_cache'
    New-Item -ItemType Directory -Force -Path $nodeTarget | Out-Null
    Get-ChildItem -LiteralPath $nodeSource -File -Filter '*.node' -ErrorAction SilentlyContinue |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $nodeTarget $_.Name) -Force
      }
  }

  if (Test-Path -LiteralPath $OutFile) {
    Remove-Item -LiteralPath $OutFile -Force
  }
  $archiveItems = @(Get-ChildItem -LiteralPath $stage -Force)
  if ($archiveItems.Count -eq 0) {
    throw 'Package staging directory is empty.'
  }
  Compress-Archive -LiteralPath $archiveItems.FullName -DestinationPath $OutFile -Force
  Copy-Item -LiteralPath (Join-Path $stage 'install.ps1') -Destination (Join-Path $OutDir 'install.ps1') -Force
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash

  Write-Host ""
  Write-Host "Created: $OutFile" -ForegroundColor Green
  Write-Host "SHA-256: $hash" -ForegroundColor Green
  Write-Host "Release install.ps1: $(Join-Path $OutDir 'install.ps1')" -ForegroundColor Green
  Write-Host ""
  Write-Host "GitHub release instructions:" -ForegroundColor Cyan
  Write-Host "1. Create private repo: gh repo create $Repo --private"
  Write-Host '2. Push files: git add . && git commit -m "v1.0" && git push'
  Write-Host "3. Create release: gh release create $Version `"$OutFile`" `"$(Join-Path $OutDir 'install.ps1')`""
  Write-Host "   install.ps1 must be a separate release asset because the one-liner downloads it directly."
  Write-Host ""
  Write-Host "One-liner:"
  Write-Host "iwr -Uri `"https://github.com/$Repo/releases/latest/download/install.ps1`" -OutFile `"`$env:TEMP\ezb_install.ps1`"; Start-Process powershell -Verb RunAs -ArgumentList `"-ExecutionPolicy Bypass -File ```"`$env:TEMP\ezb_install.ps1```"`""
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
