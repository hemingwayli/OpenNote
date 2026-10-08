param([Parameter(Mandatory)][string]$DataDirectory)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$dataPath = (Resolve-Path -LiteralPath $DataDirectory).ProviderPath.TrimEnd('\')
if (-not $dataPath.StartsWith($temporaryRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    -not [System.IO.Path]::GetFileName($dataPath).StartsWith('opennote-mcp-runtime-', [System.StringComparison]::Ordinal)) {
    throw '只允许清理 MCP 检查创建的专用临时运行实例。'
}
$pythonExe = (Get-Command -Name 'python.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$resolver = Join-Path $projectRoot 'tools/toolchain.py'
$sdkPath = & $pythonExe @('-X', 'utf8', $resolver)
if ($LASTEXITCODE -ne 0) { throw '无法解析锁定 Flutter SDK。' }
$dartPath = [System.IO.Path]::GetFullPath((Join-Path $sdkPath 'bin\cache\dart-sdk\bin\dart.exe'))
$applicationPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'build\windows\x64\runner\Debug\opennote.exe'))
$commandPath = Join-Path $env:SystemRoot 'System32/cmd.exe'
$marker = '--data-dir=' + $dataPath
$filterText = "Name = 'dart.exe' OR Name = 'cmd.exe' OR Name = 'opennote.exe'"
$targets = foreach ($process in (Get-CimInstance -ClassName Win32_Process -Filter $filterText)) {
    if ([string]::IsNullOrWhiteSpace($process.CommandLine)) { continue }
    $markerIndex = $process.CommandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -lt 0) { continue }
    $endIndex = $markerIndex + $marker.Length
    if ($endIndex -lt $process.CommandLine.Length -and
        $process.CommandLine[$endIndex] -ne '"' -and
        -not [char]::IsWhiteSpace($process.CommandLine[$endIndex])) { continue }
    $knownExecutable = $process.ExecutablePath -ieq $dartPath -or $process.ExecutablePath -ieq $applicationPath
    $knownCommand = $process.ExecutablePath -ieq $commandPath -and
        ($process.CommandLine.Contains($sdkPath, [System.StringComparison]::OrdinalIgnoreCase) -or
         $process.CommandLine.Contains($applicationPath, [System.StringComparison]::OrdinalIgnoreCase))
    if ($knownExecutable -or $knownCommand) { $process }
}

# 先列出并核验专属资料库标记；不按进程名称全局结束，也不删除资料库。
$targets | Select-Object ProcessId, ParentProcessId, Name | ConvertTo-Json -Depth 3
$ordered = $targets | Sort-Object @{ Expression = { if ($_.Name -eq 'opennote.exe') { 0 } else { 1 } } }
foreach ($target in $ordered) {
    $idFilter = 'ProcessId = ' + $target.ProcessId
    $current = Get-CimInstance -ClassName Win32_Process -Filter $idFilter
    if ($null -eq $current) { continue }
    if ($current.CreationDate -ne $target.CreationDate -or $current.CommandLine -cne $target.CommandLine) {
        throw '进程身份已改变，拒绝结束复用的 PID。'
    }
    $liveProcess = Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $liveProcess) { $liveProcess | Stop-Process -Force -ErrorAction Stop }
}
Write-Output '本次 MCP 临时运行实例已结束；资料库保留供检查。'
