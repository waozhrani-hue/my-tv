# Re-signs a release APK with all three signature schemes.
#
# Why this exists: with minSdk 24 the Android toolchain signs with v2/v3 and
# drops v1, because AOSP does not need it. Some vendor package installers do -
# Honor and Huawei reject a v1-less APK outright as "package appears to be
# invalid". Setting enableV1Signing in build.gradle.kts is ignored, and
# apksigner skips v1 too unless it is told the minimum is below 24, which
# --min-sdk-version does for signing only; the manifest is untouched.
#
# Usage:
#   flutter build apk --release
#   pwsh tool/sign-apk.ps1 -Out dist/MyTV.apk
#
# Note: verifying afterwards needs the same flag, or apksigner reports v1 as
# false simply because it did not look:
#   apksigner verify --verbose --min-sdk-version 21 <apk>

param(
  [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$In,
  [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $In)  { $In  = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk\app-release.apk' }
if (-not $Out) { $Out = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk\app-release-signed.apk' }

if (-not (Test-Path $In)) { throw "No APK at $In - run 'flutter build apk --release' first." }

# Newest build-tools available.
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\android-sdk' }
$buildTools = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $buildTools) { throw "No build-tools found under $sdk." }
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'

$propsFile = Join-Path $ProjectRoot 'android\key.properties'
if (-not (Test-Path $propsFile)) { throw "Missing $propsFile - see the README." }
$props = Get-Content $propsFile | ConvertFrom-StringData
$keystore = Join-Path $ProjectRoot "android\app\$($props.storeFile)"

& $apksigner sign `
  --ks $keystore `
  --ks-pass "pass:$($props.storePassword)" `
  --key-pass "pass:$($props.keyPassword)" `
  --ks-key-alias $props.keyAlias `
  --min-sdk-version 21 `
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true `
  --out $Out $In
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed.' }

$schemes = & $apksigner verify --verbose --min-sdk-version 21 $Out 2>&1 |
  Select-String 'Verified using v[123] scheme'
$schemes | ForEach-Object { "  " + $_.Line.Trim() }

if (($schemes | Where-Object { $_.Line -match 'v1 scheme \(JAR signing\): true' }).Count -eq 0) {
  throw 'v1 signing did not take - the APK would be rejected by some devices.'
}

"Signed: $Out ($([math]::Round((Get-Item $Out).Length / 1MB, 1)) MB)"
