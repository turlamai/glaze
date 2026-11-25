# Windows installer lifecycle: a package takes over a product from another
# installer family (`raco glaze build --replace-upgrade-code <guid>`).
#
# Scenario (glaze#173): an app was first shipped by a previous packaging
# stack whose MSI UpgradeCode was derived from a different identifier.
# A new-family MSI does not see that product: both stay in Programs and
# Features, share one install directory, and the legacy files remain next to
# the new ones. With the UpgradeCode configured, installing the new package
# must uninstall the legacy product first.
#
# The legacy product here is a real glaze MSI built with another identifier
# and a HIGHER version (the new stack may have restarted numbering below the
# old one), carrying one file the new package does not ship.
#
# Installs and removes per-machine MSIs: for CI runners only.
param(
  [Parameter(Mandatory = $true)][string]$ProjectDir,
  [string]$Name = 'sampleapp',
  [string]$Publisher = 'Turing Lambda',
  [string]$Identifier = 'TuringLambda.Glaze.CISample',
  [string]$LegacyIdentifier = 'TuringLambda.Glaze.CISampleLegacy',
  [string]$LegacyVersion = '0.9.0',
  [string]$Version = '0.0.2'
)
$ErrorActionPreference = 'Stop'
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$installDir = Join-Path $env:ProgramFiles $Name
$markerRelative = 'public\legacy-marker.txt'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "$Name\$Name.lnk"
$installer = New-Object -ComObject WindowsInstaller.Installer

function Invoke-Msi([string]$arguments) {
  $proc = Start-Process msiexec.exe -ArgumentList @($arguments, '/qn', '/norestart') -Wait -PassThru
  if ($proc.ExitCode -notin @(0, 3010)) { throw "msiexec $arguments failed ($($proc.ExitCode))" }
}
function Find-Product {
  @(Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
    Where-Object { $_.GetValue('DisplayName') -eq $Name })
}
function Product-IsRegistered([string]$productCode) {
  $state = $installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($productCode))
  $state -ne -1
}
function Remove-AllProducts {
  foreach ($entry in (Find-Product)) {
    Start-Process msiexec.exe -ArgumentList @('/x', $entry.PSChildName, '/qn', '/norestart') -Wait | Out-Null
  }
}

$legacyUpgradeCode = (& racket -e `
  "(begin (require glaze/private/windows-installer-metadata) (displayln (stable-upgrade-code `"$LegacyIdentifier`")))"
).Trim()
if ($legacyUpgradeCode -notmatch '^\{[0-9A-F-]{36}\}$') { throw "could not derive the legacy UpgradeCode: '$legacyUpgradeCode'" }
"legacy UpgradeCode: $legacyUpgradeCode"

$marker = Join-Path $ProjectDir $markerRelative
Push-Location $ProjectDir
try {
  Remove-AllProducts
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
  Set-Content -LiteralPath $marker -Value 'shipped only by the legacy package'
  & raco glaze build --name $Name --version $LegacyVersion --publisher $Publisher `
    --identifier $LegacyIdentifier --out dist-legacy --installer
  if ($LASTEXITCODE -ne 0) { throw 'legacy MSI build failed' }
  Remove-Item -LiteralPath $marker
  & raco glaze build --name $Name --version $Version --publisher $Publisher `
    --identifier $Identifier --out dist-replace --installer `
    --replace-upgrade-code $legacyUpgradeCode
  if ($LASTEXITCODE -ne 0) { throw 'MSI build with --replace-upgrade-code failed' }
} finally {
  Pop-Location
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
}
$legacyMsi = (Resolve-Path (Join-Path $ProjectDir 'dist-legacy\*.msi')).Path
$newMsi = (Resolve-Path (Join-Path $ProjectDir 'dist-replace\*.msi')).Path

try {
  Invoke-Msi "/i `"$legacyMsi`""
  $entries = Find-Product
  if ($entries.Count -ne 1) { throw "legacy install: expected one uninstall entry, got $($entries.Count)" }
  $legacyProductCode = $entries[0].PSChildName
  $markerOnDisk = Join-Path $installDir $markerRelative
  if (-not (Test-Path $markerOnDisk)) { throw 'legacy install did not place its marker file' }
  "legacy product $legacyProductCode installed with its marker"

  Invoke-Msi "/i `"$newMsi`""
  $entries = Find-Product
  if ($entries.Count -ne 1) { throw "take-over left $($entries.Count) uninstall entries" }
  if ($entries[0].PSChildName -eq $legacyProductCode) { throw 'the new package registered as the legacy product' }
  if ($entries[0].GetValue('DisplayVersion') -ne $Version) {
    throw "unexpected installed version: $($entries[0].GetValue('DisplayVersion'))"
  }
  if (Product-IsRegistered $legacyProductCode) { throw 'the legacy product is still registered with Windows Installer' }
  if (Test-Path $markerOnDisk) { throw 'a file only the legacy package shipped is still in the install directory' }
  if (-not (Test-Path (Join-Path $installDir "$Name.exe"))) { throw 'the new package did not install its executable' }
  if (-not (Test-Path $startMenuShortcut)) { throw 'the legacy uninstall took the shared Start Menu shortcut with it' }

  Invoke-Msi "/x $($entries[0].PSChildName)"
  if (Test-Path $installDir) { throw 'uninstall left the install directory' }
  if ((Find-Product).Count -ne 0) { throw 'uninstall left an uninstall entry' }
  if (Test-Path $startMenuShortcut) { throw 'uninstall left the Start Menu shortcut' }
  "OK: the $Version package took over legacy product $legacyProductCode and uninstalled cleanly"
} finally {
  Remove-AllProducts
}
