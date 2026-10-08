param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$SevenZipExe = 'C:\Program Files\7-Zip\7z.exe'
)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$archiveToolExe = $SevenZipExe
if (-not (Test-Path -LiteralPath "$archiveToolExe" -PathType Leaf)) {
    throw "找不到必需的 7-Zip 工具：$archiveToolExe。请先安装 7-Zip，或传入 -SevenZipExe 'D:\工具\7-Zip\7z.exe' 指定现有工具；尚未下载文件或创建依赖目录。"
}
$cacheRoot = Join-Path $PSScriptRoot 'cache'
$depsRoot = Join-Path $ProjectRoot 'native/third_party'
$modelRoot = Join-Path $ProjectRoot 'assets/ocr/models/PP-OCRv6_small'
$errorLog = Join-Path $PSScriptRoot 'download-errors.jsonl'
$manifestPath = Join-Path $PSScriptRoot 'dependency-manifest.json'
$pinnedHashes = @{}
if (Test-Path -LiteralPath $manifestPath) {
    $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $existingManifest.artifacts) { $pinnedHashes[$entry.name] = $entry.sha256 }
}
$tarExe = 'C:\Windows\System32\tar.exe'
New-Item -ItemType Directory -Force -Path $cacheRoot, $depsRoot, $modelRoot | Out-Null

function Get-OfficialArtifact([string]$Url, [string]$Name) {
    $destination = Join-Path $cacheRoot $Name
    if (Test-Path -LiteralPath $destination) { return $destination }
    $delays = @(2, 5, 10)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            Write-Host "Download $Name, attempt $($attempt + 1)"
            Invoke-WebRequest -Uri $Url -OutFile ($destination + '.partial') -TimeoutSec 600
            Move-Item -LiteralPath ($destination + '.partial') -Destination $destination
            return $destination
        } catch {
            $status = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $record = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); url = $Url; attempt = $attempt + 1; status = $status; error = $_.Exception.Message }
            [System.IO.File]::AppendAllText($errorLog, (($record | ConvertTo-Json -Compress) + "`n"), $utf8)
            Write-Warning "$Name failed: $($_.Exception.Message)"
            if (($status -ge 400 -and $status -lt 500 -and $status -notin @(408, 429)) -or $attempt -eq 3) { throw }
            Start-Sleep -Seconds $delays[$attempt]
        }
    }
}
function Invoke-CheckedNative([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable exited $LASTEXITCODE" }
}

$base = 'https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0'
$downloads = @(
    @{ name = 'PP-OCRv6_small_det_onnx_infer.tar'; url = "$base/PP-OCRv6_small_det_onnx_infer.tar"; license = 'Apache-2.0' },
    @{ name = 'PP-OCRv6_small_rec_onnx_infer.tar'; url = "$base/PP-OCRv6_small_rec_onnx_infer.tar"; license = 'Apache-2.0' },
    @{ name = 'onnxruntime-win-x64-1.21.0.zip'; url = 'https://github.com/microsoft/onnxruntime/releases/download/v1.21.0/onnxruntime-win-x64-1.21.0.zip'; license = 'MIT' },
    @{ name = 'opencv-4.11.0-windows.exe'; url = 'https://github.com/opencv/opencv/releases/download/4.11.0/opencv-4.11.0-windows.exe'; license = 'Apache-2.0' },
    @{ name = 'yaml-cpp-0.8.0.tar.gz'; url = 'https://codeload.github.com/jbeder/yaml-cpp/tar.gz/refs/tags/0.8.0'; license = 'MIT' },
    @{ name = 'PaddleOCR-LICENSE.txt'; url = 'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/LICENSE'; license = 'Apache-2.0' }
)
$archiveManifest = foreach ($artifact in $downloads) {
    $archive = Get-OfficialArtifact $artifact.url $artifact.name
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pinnedHashes.ContainsKey($artifact.name) -and $pinnedHashes[$artifact.name] -ne $digest) {
        $reason = "Artifact hash differs from pinned manifest: $($artifact.name)"
        $record = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); url = $artifact.url; error = $reason; expectedSha256 = $pinnedHashes[$artifact.name]; actualSha256 = $digest }
        [System.IO.File]::AppendAllText($errorLog, (($record | ConvertTo-Json -Compress) + "`n"), $utf8)
        throw $reason
    }
    [ordered]@{ name = $artifact.name; url = $artifact.url; sha256 = $digest; size = (Get-Item -LiteralPath $archive).Length; license = $artifact.license }
}

foreach ($kind in @('det', 'rec')) {
    $archive = Join-Path $cacheRoot "PP-OCRv6_small_${kind}_onnx_infer.tar"
    $target = Join-Path $modelRoot $kind
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Invoke-CheckedNative $tarExe @('-xf', $archive, '-C', $target, '--strip-components=1')
}
$ortArchive = Join-Path $cacheRoot 'onnxruntime-win-x64-1.21.0.zip'
Expand-Archive -LiteralPath $ortArchive -DestinationPath $depsRoot -Force
$ortRoot = Join-Path $depsRoot 'onnxruntime'
New-Item -ItemType Directory -Force -Path $ortRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $depsRoot 'onnxruntime-win-x64-1.21.0/include'), (Join-Path $depsRoot 'onnxruntime-win-x64-1.21.0/lib'), (Join-Path $depsRoot 'onnxruntime-win-x64-1.21.0/LICENSE'), (Join-Path $depsRoot 'onnxruntime-win-x64-1.21.0/ThirdPartyNotices.txt') -Destination $ortRoot -Recurse -Force
Invoke-CheckedNative $archiveToolExe @('x', (Join-Path $cacheRoot 'opencv-4.11.0-windows.exe'), "-o$depsRoot", '-y', '-bso0')
Invoke-CheckedNative $tarExe @('-xf', (Join-Path $cacheRoot 'yaml-cpp-0.8.0.tar.gz'), '-C', $depsRoot)
$manifest = [ordered]@{ formatVersion = 1; model = 'PP-OCRv6_small'; backend = 'onnxruntime-cpu'; onnxruntime = '1.21.0'; opencv = '4.11.0'; yamlCpp = '0.8.0'; artifacts = @($archiveManifest) }
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'dependency-manifest.json'), ($manifest | ConvertTo-Json -Depth 8), $utf8)
$licenseRoot = Join-Path $ProjectRoot 'assets/ocr/licenses'
New-Item -ItemType Directory -Force -Path $licenseRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $cacheRoot 'PaddleOCR-LICENSE.txt') -Destination (Join-Path $licenseRoot 'PaddleOCR.txt') -Force
Copy-Item -LiteralPath (Join-Path $ortRoot 'LICENSE') -Destination (Join-Path $licenseRoot 'ONNXRuntime.txt') -Force
Copy-Item -LiteralPath (Join-Path $ortRoot 'ThirdPartyNotices.txt') -Destination (Join-Path $licenseRoot 'ONNXRuntime-ThirdPartyNotices.txt') -Force
Copy-Item -LiteralPath (Join-Path $depsRoot 'opencv/LICENSE.txt') -Destination (Join-Path $licenseRoot 'OpenCV.txt') -Force
$opencvNotices = Join-Path $licenseRoot 'OpenCV-ThirdParty'
New-Item -ItemType Directory -Force -Path $opencvNotices | Out-Null
Get-ChildItem -LiteralPath (Join-Path $depsRoot 'opencv/build/etc/licenses') -File | Copy-Item -Destination $opencvNotices -Force
Copy-Item -LiteralPath (Join-Path $depsRoot 'yaml-cpp-0.8.0/LICENSE') -Destination (Join-Path $licenseRoot 'yaml-cpp.txt') -Force
Write-Host "Models: $modelRoot"
Write-Host "Dependencies: $depsRoot"
