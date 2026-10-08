param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$FlutterRoot
)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $pythonExe = (Get-Command -Name 'python.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $resolver = Join-Path $ProjectRoot 'tools/toolchain.py'
    $FlutterRoot = & $pythonExe @('-X', 'utf8', $resolver)
    if ($LASTEXITCODE -ne 0) { throw '无法解析锁定 Flutter SDK。' }
}
$flutterExe = Join-Path $FlutterRoot 'bin/flutter.bat'
$nativeRuntime = Join-Path $ProjectRoot 'native/build/Release'
$previousPath = $env:PATH
$previousDirectory = Get-Location
try {
    $env:PATH = "$nativeRuntime;$previousPath"
    Set-Location -LiteralPath $ProjectRoot
    & $flutterExe @('test', '--concurrency=1', 'test/ocr')
    if ($LASTEXITCODE -ne 0) { throw "OCR tests failed: $LASTEXITCODE" }
} finally {
    $env:PATH = $previousPath
    Set-Location -LiteralPath $previousDirectory.Path
}
