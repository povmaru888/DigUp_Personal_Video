param(
    [string]$Source = "$env:LOCALAPPDATA\DigUp\index\index.sqlite",
    [string]$Destination = "$env:LOCALAPPDATA\DigUpPersonalVideo\index\index.sqlite"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Official DigUp index was not found: $Source"
}
if (Get-Process -Name "DigUp", "DigUpPersonalVideo", "digup" -ErrorAction SilentlyContinue) {
    throw "Close DigUp, DigUp Personal Video, and their helpers before importing."
}
$destinationFolder = Split-Path -Parent $Destination
New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null
if (Test-Path -LiteralPath $Destination) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $Destination -Destination "$Destination.before-import-$stamp.bak"
}
Copy-Item -LiteralPath $Source -Destination $Destination
Copy-Item -LiteralPath $Destination -Destination "$Destination.imported.bak" -Force
Write-Host "Imported a copy to $Destination"
Write-Host "The original database was not changed. Start DigUp Personal Video to migrate the copy."
