param(
  [string]$Version = "1.2.3"
)

$ErrorActionPreference = "Stop"
$firmwareRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $firmwareRoot
$buildRoot = Join-Path $firmwareRoot ".pio/build"
$dist = Join-Path $firmwareRoot "dist"
$bootApp0 = Join-Path $env:USERPROFILE ".platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"

New-Item -ItemType Directory -Force -Path $dist | Out-Null

foreach ($envName in @("esp8266", "esp32")) {
  $app = Join-Path $buildRoot "$envName/firmware.bin"
  if (-not (Test-Path $app)) { throw "Firmware image missing: $app" }

  Copy-Item $app (Join-Path $dist "$envName-firmware-v$Version-ota.bin") -Force
  if ($envName -eq "esp8266") {
    # PlatformIO's NodeMCU image is already an eboot-compatible factory image.
    Copy-Item $app (Join-Path $dist "$envName-firmware-v$Version-factory.bin") -Force
    continue
  }

  $bootloader = Join-Path $buildRoot "esp32/bootloader.bin"
  $partitions = Join-Path $buildRoot "esp32/partitions.bin"
  if (-not (Test-Path $bootApp0)) { throw "boot_app0.bin missing: $bootApp0" }
  $factory = Join-Path $dist "$envName-firmware-v$Version-factory.bin"
  Push-Location $repoRoot
  try {
    py -m esptool --chip esp32 merge-bin --flash-mode dio --flash-freq 40m --flash-size 4MB `
      --output $factory 0x1000 $bootloader 0x8000 $partitions 0xe000 $bootApp0 0x10000 $app
    if ($LASTEXITCODE -ne 0) { throw "esptool merge-bin failed ($LASTEXITCODE)" }
  }
  finally { Pop-Location }
}

Get-ChildItem $dist -Filter "*-firmware-v$Version-*.bin" | Select-Object Name,Length
