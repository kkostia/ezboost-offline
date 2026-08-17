# EZBoost Offline deployment

One-command PowerShell deployment package for an offline QA test environment.

## Repository layout

```text
ezboost-offline/
├── install.ps1
├── uninstall.ps1
├── update.ps1
├── README.md
├── artifacts/
│   ├── core_assembly_final.dll
│   ├── ezboost_offline_loader.js
│   └── node_cache/
└── package.ps1
```

## One-command install

```powershell
iwr -Uri "https://github.com/kkostia/ezboost-offline/releases/latest/download/install.ps1" -OutFile "$env:TEMP\ezb_install.ps1"; Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$env:TEMP\ezb_install.ps1`""
```

For a private GitHub release, set a token with release read access first:

```powershell
$env:GITHUB_TOKEN="ghp_xxx"; iwr -Headers @{Authorization="Bearer $env:GITHUB_TOKEN"} -Uri "https://github.com/kkostia/ezboost-offline/releases/latest/download/install.ps1" -OutFile "$env:TEMP\ezb_install.ps1"; Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$env:TEMP\ezb_install.ps1`""
```

If `install.ps1` is downloaded alone, it downloads `ezboost-offline-v1.0.zip`
from the same release and continues from the extracted full package.

If you do not want to edit `install.ps1`, run with:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo kkostia/ezboost-offline
```

or set:

```powershell
$env:EZB_REPO = 'kkostia/ezboost-offline'
```

## What install.ps1 does

1. Requests administrator rights if needed.
2. If run standalone, downloads the full release ZIP.
3. Stops legacy Ragebots processes.
4. Removes known legacy desktop folders/files:
   - `C:\Users\*\Desktop\*ragebots*`
   - `C:\Users\*\Desktop\*ragebot*`
   - `C:\Users\*\Desktop\*frozen_ragebots*`
   - `C:\Users\*\Desktop\*FINALFISHBOT*`
   - `C:\Users\*\Desktop\bot\` only when it contains an original ASAR marker.
   - `C:\Users\*\Desktop\ultimate\frozen_ragebots*`
   - `C:\Users\*\Desktop\ultimate\FINALFISHBOT`
5. Cleans legacy Discord loader leftovers and extra legacy `.asar` files.
6. Detects the latest Discord app folder:
   `%LOCALAPPDATA%\Discord\app-1.0.*\modules\discord_desktop_core-1\discord_desktop_core\`
7. Stops Discord and waits 3 seconds.
8. Backs up `index.js` to `index.js.bak.YYYYMMDD_HHmmss`.
9. Copies:
   - `artifacts\core_assembly_final.dll` → `core_assembly_stubbed.dll`
   - `artifacts\ezboost_offline_loader.js` → `index.js`
10. Copies optional `.node` files to `%APPDATA%\discord\.ezb-cache\`.
11. Adds a cleanly removable hosts entry:
   `0.0.0.0 ezboost.fly.dev # EZB-OFFLINE`
12. Starts Discord as admin.

Every step prints ✅/❌ status.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

This stops Discord, restores the latest `index.js.bak.*`, removes
`core_assembly_stubbed.dll`, removes `# EZB-OFFLINE` hosts entries, and restarts
Discord.

## Re-apply after Discord update

```powershell
powershell -ExecutionPolicy Bypass -File .\update.ps1
```

This detects the newest `app-*` folder, prints the detected version, and applies
the loader/DLL again.

## Build release ZIP

```powershell
powershell -ExecutionPolicy Bypass -File .\package.ps1 -Repo kkostia/ezboost-offline
```

Output:

```text
release\ezboost-offline-v1.0.zip
release\install.ps1
```

GitHub release instructions printed by `package.ps1`:

```text
1. Create private repo: gh repo create kkostia/ezboost-offline --private
2. Push files: git add . && git commit -m "v1.0" && git push
3. Create release: gh release create v1.0 release\ezboost-offline-v1.0.zip release\install.ps1
```

`install.ps1` must be uploaded as a separate release asset because the one-line
installer downloads it directly, then it downloads the full ZIP by itself. Use
`package.ps1 -Repo OWNER/ezboost-offline` so the release `install.ps1` knows
which repository to use when it downloads the ZIP.

## Notes

- PowerShell 5.1+ only.
- No dependencies beyond `Invoke-WebRequest` and `Expand-Archive`.
- `artifacts\node_cache\` is optional.
- The scripts handle missing Discord, already patched `index.js`, and missing
  backups gracefully.
