# Run the unchanged Linux console with inherited terminal handles (curses needs a TTY).
# No parameter binder consumes the original agent-top flags.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    $configPath = Join-Path $PSScriptRoot 'desktop-config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { throw 'Run agent-top from a filesystem directory.' }
    $forward = @{}
    Get-ChildItem Env: | Where-Object {
        $_.Name -match '^(AGENT_HUB_|HUB_)' -or $_.Name -in @(
            'CODEX_THREAD_ID', 'AGENT_SESSION_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE', 'CODEX_APP_TOOLS_PIPE_PATH',
            'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    } | ForEach-Object { $forward[$_.Name] = $_.Value }
    if ($forward.ContainsKey('CODEX_THREAD_ID')) {
        $forward['AGENT_SESSION_ID'] = $forward['CODEX_THREAD_ID']
    }
    $payload = [pscustomobject]@{
        mode = 'tool'
        argv = @('agent-top') + @($args | ForEach-Object { [string]$_ })
        env = $forward
        cwd = $location.ProviderPath
        config = $config
        pluginroot = Split-Path -Parent $PSScriptRoot
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 100 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $runner = Join-Path $PSScriptRoot 'desktop_runtime.py'
    $mapped = & wsl.exe --distribution $config.Distro --exec wslpath -a -u $runner
    if ($LASTEXITCODE -ne 0) { throw 'WSL could not resolve the Desktop transport path.' }
    $linuxRunner = ([string]$mapped).Trim()
    # Keep arguments and forwarded environment off the command line and out of logs.
    $payloadFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($payloadFile, $encoded, [Text.UTF8Encoding]::new($false))
        $mapped = & wsl.exe --distribution $config.Distro --exec wslpath -a -u $payloadFile
        if ($LASTEXITCODE -ne 0) { throw 'WSL could not resolve the Desktop payload path.' }
        $linuxPayload = ([string]$mapped).Trim()
        # Do not capture, pipe, hide or redirect this process: it owns the caller's terminal.
        & wsl.exe --distribution $config.Distro --exec python3 $linuxRunner --payload-file $linuxPayload
        $status = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $payloadFile -Force }
    exit $status
} catch {
    [Console]::Error.WriteLine("agent-top: $($_.Exception.Message)")
    exit 1
}
