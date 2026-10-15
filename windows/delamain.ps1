# A transport boundary only: all commands and hooks execute inside WSL.
# No parameter binder: $args preserves command flags, Unicode and empty strings.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    . (Join-Path $PSScriptRoot 'process_transport.ps1')
    $distro = if ($env:DELAMAIN_WSL_DISTRO) { $env:DELAMAIN_WSL_DISTRO } else { 'Ubuntu' }
    $cwd = (Get-Location).ProviderPath
    if ((Get-Location).Provider.Name -ne 'FileSystem') {
        throw 'Run Delamain from a filesystem directory.'
    }
    $forward = @{}
    Get-ChildItem Env: | Where-Object {
        $_.Name -match '^(AGENT_HUB_|HUB_)' -or $_.Name -eq 'CODEX_THREAD_ID' -or
        $_.Name -in @('DELAMAIN_CODEX_PATH', 'DELAMAIN_PLUGIN_ROOT', 'DELAMAIN_CODEX_HOME',
                      'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    } | ForEach-Object { $forward[$_.Name] = $_.Value }
    $payload = @{ argv = @($args | ForEach-Object { [string]$_ }); cwd = $cwd; env = $forward }
    $json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $runner = Join-Path $PSScriptRoot 'launch.py'
    $mapped = Invoke-DelamainWsl -Arguments @('--distribution', $distro, '--exec', 'wslpath', '-a', '-u', $runner) -Capture
    if ($mapped.ExitCode -ne 0) { throw 'WSL could not resolve the launcher path.' }
    $linuxRunner = $mapped.Output.Trim()
    # Arguments and forwarded environment can exceed the Windows command-line
    # limit. Keep them in a per-call file, without taking the worker's stdin.
    $payloadFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($payloadFile, $encoded, [Text.UTF8Encoding]::new($false))
        $mapped = Invoke-DelamainWsl -Arguments @('--distribution', $distro, '--exec', 'wslpath', '-a', '-u', $payloadFile) -Capture
        if ($mapped.ExitCode -ne 0) { throw 'WSL could not resolve the launcher payload path.' }
        $command = @('--distribution', $distro, '--exec', 'python3', $linuxRunner, '--payload-file', $mapped.Output.Trim())
        if ($MyInvocation.ExpectingInput) {
            $text = (@($input | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) + [Environment]::NewLine
            Invoke-DelamainWsl -Arguments $command -RedirectInput -InputText $text
        } elseif (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
            # Keep real terminal handles for interactive Codex/TUI sessions.
            # The command line contains only runner and payload-file paths.
            & wsl.exe @command
        } else {
            Invoke-DelamainWsl -Arguments $command -RedirectInput:([Console]::IsInputRedirected) -InputText $null
        }
        $status = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $payloadFile -Force }
    exit $status
} catch {
    [Console]::Error.WriteLine("delamain: $($_.Exception.Message)")
    exit 1
}
