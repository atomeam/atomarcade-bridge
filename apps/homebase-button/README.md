# Homebase Button

Minimal Homebase app: a window with a single button. The button does nothing.

## Install (one-liner)

Open PowerShell on Windows and paste:

```powershell
iex (irm https://raw.githubusercontent.com/atomeam/atomarcade-bridge/homebase-button/apps/homebase-button/install.ps1)
```

Installs to `%LOCALAPPDATA%\HomebaseButton` and adds Desktop + Start Menu shortcuts.

## Uninstall

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\HomebaseButton"
Remove-Item -Force "$([Environment]::GetFolderPath('Desktop'))\Homebase.lnk" -ErrorAction SilentlyContinue
Remove-Item -Force "$([Environment]::GetFolderPath('StartMenu'))\Programs\Homebase.lnk" -ErrorAction SilentlyContinue
```

## What it does

- Opens a 320x200 window titled "Homebase"
- Single blue button labeled "Homebase" in the center
- Click does nothing (by design)

## Files

- `HomebaseButton.ps1` - the app (WinForms, ~25 lines)
- `install.ps1` - the installer
- `README.md` - this file
