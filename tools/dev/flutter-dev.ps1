param(
    [ValidateSet('run', 'profile', 'preview', 'devtools', 'analyze', 'golden', 'update-goldens', 'doctor', 'setup-ide', 'mcp-check', 'check')]
    [string]$Action = 'run',
    [string]$DataDirectory,
    [string]$VmServiceUri,
    [ValidateSet('quick', 'home', 'map', 'reader', 'pdf', 'epub', 'data', 'controller', 'workspace', 'ocr', 'tools', 'full')]
    [string]$Scope = 'quick',
    [string[]]$TestPath,
    [string]$PlainName,
    [switch]$SkipAnalyze,
    [switch]$DryRun,
    [ValidateSet('1920x1080', '1280x720', '1920x1080-at150', 'all')]
    [string]$GoldenProfile = '1920x1080'
)

$ErrorActionPreference = 'Stop'
$previousConsoleEncoding = [Console]::OutputEncoding
$previousOutputEncoding = $OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $pythonCommand = Get-Command -Name 'python.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $pythonExe = $pythonCommand.Source
    if ([string]::IsNullOrWhiteSpace($pythonExe)) {
        throw '开发工具需要 PATH 中的 Python 3.11 或以上版本。'
    }
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        throw '开发工具需要本机 Python 3.11 或以上版本。'
    }
    $entryPath = Join-Path $PSScriptRoot 'flutter_dev.py'
    $nativeArguments = @('-X', 'utf8', $entryPath, $Action)
    if (-not [string]::IsNullOrWhiteSpace($DataDirectory)) {
        $nativeArguments += @('--data-dir', $DataDirectory)
    }
    if (-not [string]::IsNullOrWhiteSpace($VmServiceUri)) {
        $nativeArguments += @('--vm-service-uri', $VmServiceUri)
    }
    if ($Action -eq 'check') {
        $nativeArguments += @('--scope', $Scope)
        foreach ($path in $TestPath) {
            $nativeArguments += @('--test', $path)
        }
        if (-not [string]::IsNullOrWhiteSpace($PlainName)) {
            $nativeArguments += @('--plain-name', $PlainName)
        }
        if ($SkipAnalyze) { $nativeArguments += '--skip-analyze' }
        if ($DryRun) { $nativeArguments += '--dry-run' }
    }
    if ($Action -in @('golden', 'update-goldens')) {
        $nativeArguments += @('--golden-profile', $GoldenProfile)
    }
    & $pythonExe @nativeArguments
    $nativeExitCode = $LASTEXITCODE
} finally {
    [Console]::OutputEncoding = $previousConsoleEncoding
    $OutputEncoding = $previousOutputEncoding
}
exit $nativeExitCode
