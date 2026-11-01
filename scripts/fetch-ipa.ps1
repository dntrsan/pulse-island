# Download the latest PulseIsland.ipa built by GitHub Actions into .\dist
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
gh run download --repo dntrsan/pulse-island --name PulseIsland-ipa --dir $dist
Get-ChildItem $dist | Select-Object Name, Length, LastWriteTime
