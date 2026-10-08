param([string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$nativeRoot = Join-Path $ProjectRoot 'native'
$modelRoot = Join-Path $ProjectRoot 'assets/ocr/models/PP-OCRv6_small'
$cliPath = Join-Path $nativeRoot 'build/Release/opennote_ocr_cli.exe'
$dictionaryPath = Join-Path $modelRoot 'characters.txt'
& $cliPath @('--dictionary', $modelRoot, $dictionaryPath)
if ($LASTEXITCODE -ne 0) { throw "Dictionary preparation failed: $LASTEXITCODE" }
$licensesRoot = Join-Path $ProjectRoot 'assets/ocr/licenses'
$installedLicenses = Join-Path $modelRoot 'licenses'
New-Item -ItemType Directory -Force -Path $installedLicenses | Out-Null
Get-ChildItem -LiteralPath $licensesRoot | Copy-Item -Destination $installedLicenses -Recurse -Force
$manifestFiles = foreach ($relative in @('det/inference.onnx', 'det/inference.yml', 'rec/inference.onnx', 'rec/inference.yml', 'characters.txt')) {
    $absolute = Join-Path $modelRoot $relative
    [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant(); size = (Get-Item -LiteralPath $absolute).Length }
}
$manifest = [ordered]@{
    formatVersion = 1
    model = 'PP-OCRv6_small'
    processingVersion = 'opennote-ppocrv6-small-cpu-v2'
    backend = 'onnxruntime-cpu'
    onnxruntime = '1.21.0'
    opencv = '4.11.0'
    dictionarySource = 'rec/inference.yml:PostProcess.character_dict; CTC blank=0, appended space'
    characterGeometry = 'approximateCtcAlignment'
    readingOrder = 'dominantElongatedBoxes: basicRows or basicVerticalColumns'
    settings = [ordered]@{ detectionMaxSide = 1536; recognitionHeight = 48; recognitionMaxWidth = 3200; cpuThreadsDefault = 2; recognitionColor = 'BGR'; detectionThreshold = 0.2; boxThreshold = 0.45; unclipRatio = 1.4 }
    files = @($manifestFiles)
    artifacts = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependency-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).artifacts
}
$manifestText = $manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText((Join-Path $modelRoot 'manifest.json'), $manifestText, $utf8)
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot 'assets/ocr/manifest.json'), $manifestText, $utf8)
$runtimeRoot = Join-Path $nativeRoot 'runtime-ppocrv6-small'
$runtimeModels = Join-Path $runtimeRoot 'data/ocr'
New-Item -ItemType Directory -Force -Path $runtimeRoot, $runtimeModels | Out-Null
Copy-Item -LiteralPath (Join-Path $nativeRoot 'build/Release/opennote_ocr.dll'), (Join-Path $nativeRoot 'third_party/onnxruntime/lib/opennote_onnxruntime.dll'), (Join-Path $nativeRoot 'third_party/opencv/build/x64/vc16/bin/opencv_world4110.dll') -Destination $runtimeRoot -Force
Get-ChildItem -LiteralPath $modelRoot | Copy-Item -Destination $runtimeModels -Recurse -Force
$runtimeFiles = foreach ($file in (Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File)) {
    [ordered]@{ path = [System.IO.Path]::GetRelativePath($runtimeRoot, $file.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); size = $file.Length }
}
$runtimeManifest = [ordered]@{ formatVersion = 1; description = 'Standalone validation runtime; application build has its own artifact hashes'; files = @($runtimeFiles) }
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'runtime-manifest.json'), ($runtimeManifest | ConvertTo-Json -Depth 8), $utf8)
Write-Host "Offline runtime prepared: $runtimeRoot"
