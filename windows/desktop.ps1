# Native Desktop transport only. No parameter binder consumes original CLI flags.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    . (Join-Path $PSScriptRoot 'process_transport.ps1')
    $configPath = Join-Path $PSScriptRoot 'desktop-config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $forward = @{}
    Get-ChildItem Env: | Where-Object {
        $_.Name -match '^(AGENT_HUB_|HUB_)' -or $_.Name -in @(
            'CODEX_THREAD_ID', 'AGENT_SESSION_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE', 'CODEX_APP_TOOLS_PIPE_PATH',
            'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    } | ForEach-Object { $forward[$_.Name] = $_.Value }
    $argv = @($args | ForEach-Object { [string]$_ })
    if ($argv.Count -eq 2 -and $argv[0] -eq '--hook-payload') {
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($argv[1])) | ConvertFrom-Json
        $payload | Add-Member -NotePropertyName env -NotePropertyValue $forward -Force
    } else {
        if ($argv.Count -gt 0 -and $argv[0] -eq '--session-id') {
            $sid = [Guid]::Empty
            if ($argv.Count -lt 3 -or -not [Guid]::TryParse($argv[1], [ref]$sid)) {
                throw '--session-id requires a real current chat UUID and a command.'
            }
            $forward['CODEX_THREAD_ID'] = $argv[1]
            $forward['AGENT_SESSION_ID'] = $argv[1]
            $argv = @($argv | Select-Object -Skip 2)
        } elseif ($forward.ContainsKey('CODEX_THREAD_ID')) {
            $forward['AGENT_SESSION_ID'] = $forward['CODEX_THREAD_ID']
        }
        $payload = [pscustomobject]@{ mode = 'tool'; argv = $argv; env = $forward }
    }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { throw 'Run Delamain from a filesystem directory.' }
    $payload | Add-Member -NotePropertyName cwd -NotePropertyValue $location.ProviderPath -Force
    $payload | Add-Member -NotePropertyName config -NotePropertyValue $config -Force
    $payload | Add-Member -NotePropertyName pluginroot -NotePropertyValue (Split-Path -Parent $PSScriptRoot) -Force
    $json = ConvertTo-Json -InputObject $payload -Depth 100 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $runner = Join-Path $PSScriptRoot 'desktop_runtime.py'
    $mapped = Invoke-DelamainWsl -Arguments @('--distribution', $config.Distro, '--exec', 'wslpath', '-a', '-u', $runner) -Capture
    if ($mapped.ExitCode -ne 0) { throw 'WSL could not resolve the Desktop transport path.' }
    $linuxRunner = $mapped.Output.Trim()
    # Keep large tool/hook events out of the Windows command-line limit. The file
    # contains this call's arguments, environment and tool_input, which may
    # include credentials. Do not log it; finally deletes it after completion
    # or failure. Base64 is transport encoding, not encryption or access control.
    $payloadFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($payloadFile, $encoded, [Text.UTF8Encoding]::new($false))
        $mapped = Invoke-DelamainWsl -Arguments @('--distribution', $config.Distro, '--exec', 'wslpath', '-a', '-u', $payloadFile) -Capture
        if ($mapped.ExitCode -ne 0) { throw 'WSL could not resolve the Desktop payload path.' }
        $linuxPayload = $mapped.Output.Trim()
        $command = @('--distribution', $config.Distro, '--exec', 'python3', $linuxRunner, '--payload-file', $linuxPayload)
        if ($MyInvocation.ExpectingInput) {
            $text = (@($input | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) + [Environment]::NewLine
            Invoke-DelamainWsl -Arguments $command -RedirectInput -InputText $text
        } else {
            Invoke-DelamainWsl -Arguments $command -RedirectInput:([Console]::IsInputRedirected) -InputText $null
        }
        $status = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $payloadFile -Force }
    exit $status
} catch {
    [Console]::Error.WriteLine("delamain desktop: $($_.Exception.Message)")
    exit 1
}
