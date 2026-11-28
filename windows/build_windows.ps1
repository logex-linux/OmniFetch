# Builds standalone OmniFetch-1.0.0-windows-x64.exe on Windows using PySide6 + PyInstaller.
param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

if (-not (Test-Path ".venv")) {
    python -m venv .venv
}

& .\.venv\Scripts\python.exe -m pip install --upgrade pip
& .\.venv\Scripts\python.exe -m pip install -r requirements.txt

Remove-Item -Recurse -Force build, dist -ErrorAction SilentlyContinue
& .\.venv\Scripts\pyinstaller.exe --clean --noconfirm OmniFetch.spec

$OutExe = Join-Path $Root "dist\OmniFetch-$Version-windows-x64.exe"
Copy-Item (Join-Path $Root "dist\OmniFetch.exe") $OutExe -Force

$Hash = (Get-FileHash $OutExe -Algorithm SHA256).Hash.ToLower()
"$Hash  OmniFetch-$Version-windows-x64.exe" | Out-File -Encoding ascii (Join-Path $Root "dist\SHA256SUMS-windows.txt")

Write-Host "Built: $OutExe"
Write-Host "SHA256: $Hash"
