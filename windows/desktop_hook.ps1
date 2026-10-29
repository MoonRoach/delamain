param(
    [Parameter(Mandatory = $true)][ValidateSet('questions', 'delegation', 'path_shadow', 'board_locks', 'polling_guard', 'kill_guard', 'scan_guard', 'handoff_size', 'context_budget', 'no_compaction')][string]$Hook,
    [string[]]$HookArgs = @()
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# PreCompact is selected by registration. Veto before reading input or invoking
# WSL: no transcript, settings, identity or transport dependency may allow it.
if ($Hook -eq 'no_compaction') {
    @{
        continue = $false
        stopReason = 'Delamain forbids automatic and manual compaction. Save a checkpoint and follow the existing handoff policy.'
        systemMessage = 'Delamain blocked compaction. If the automatic context limit has been reached, this session may stop before an answer; continue from its checkpoint with a fresh coordinator for the same stage under existing authority. Repeating prompts in an overfull session will not help. Below that limit, normal prompts and tools can continue.'
    } | ConvertTo-Json -Compress
    exit 0
}

function Get-LiteralValue($Element) {
    if ($Element -is [Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Element.Value }
    if ($Element -is [Management.Automation.Language.ConstantExpressionAst]) { return [string]$Element.Value }
    # Command parameters are literal switches, including --session-id/--cwd.
    if ($Element -is [Management.Automation.Language.CommandParameterAst] -and -not $Element.Argument) { return [string]$Element.Extent.Text }
    throw 'nonliteral argument'
}

function Test-TopLevelLocation($Call, $Root) {
    # Only a single command directly in the root end block is unconditional.
    # Assignments, pipelines, functions, branches and jobs cannot establish a cwd.
    $pipeline = $Call.Parent
    # PS5.1 has no Background property; inspect it only when it is present.
    $background = $pipeline.PSObject.Properties['Background']
    return ($pipeline -is [Management.Automation.Language.PipelineAst] -and
        $pipeline.PipelineElements.Count -eq 1 -and
        -not ($background -and $background.Value) -and
        $pipeline.Parent -eq $Root.EndBlock)
}

try {
    $raw = [Console]::In.ReadToEnd()
    $event = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $replacements = @()
    $projection = @()
    $unsafeBridge = $false
    if ($event.tool_name -eq 'Bash' -and $event.tool_input.command -is [string]) {
        $command = $event.tool_input.command
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$parseErrors)
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        $pipelineViews = @{}
        foreach ($call in $commands) {
            $pipeline = $call.Parent
            if ($Hook -eq 'kill_guard' -and $pipeline -is [Management.Automation.Language.PipelineAst] -and
                $pipeline.PipelineElements.Count -gt 1) {
                # Keep real native pipe dependencies in addition to individual
                # calls. An enclosing if/function is outside this exact extent.
                $key = [string]$pipeline.Extent.StartOffset + ':' + [string]$pipeline.Extent.EndOffset
                if (-not $pipelineViews.ContainsKey($key)) {
                    $pipelineViews[$key] = $true
                    $stages = @($pipeline.PipelineElements | ForEach-Object {
                        @{ script = $_.Extent.Text; start = $_.Extent.StartOffset; end = $_.Extent.EndOffset }
                    })
                    $projection += @{ kind = 'pipeline'; stages = $stages }
                }
            }
            $first = $call.CommandElements[0]
            # A literal script block is executed as a block, not as a bridge path.
            # FindAll inspects its nested calls independently below.
            $looksBridge = $first -isnot [Management.Automation.Language.ScriptBlockExpressionAst] -and
                $first.Extent.Text -match '(?i)desktop\.ps1\b'
            $locationName = $call.GetCommandName()
            if ($locationName) { $locationName = ($locationName -replace '\\', '/').Split('/')[-1] }
            $looksLocation = $locationName -in @('cd', 'chdir', 'sl', 'Set-Location', 'Push-Location', 'Pop-Location', 'pushd', 'popd')
            try {
                $values = @($call.CommandElements | ForEach-Object { Get-LiteralValue $_ })
            } catch {
                if ($looksBridge) { $unsafeBridge = $true }
                $projection += @{ kind = 'raw'; script = $call.Extent.Text; uncertain_cwd = $looksLocation }
                continue
            }
            $projected = @{ kind = 'argv'; argv = $values }
            $name = ($values[0] -replace '\\', '/').Split('/')[-1].ToLowerInvariant()
            if ($looksLocation) {
                $locationArgs = @($values | Select-Object -Skip 1)
                $literalPath = $false
                if ($locationArgs.Count -eq 2 -and $locationArgs[0] -in @('-Path', '-LiteralPath')) {
                    $literalPath = $locationArgs[0] -eq '-LiteralPath'
                    $locationArgs = @($locationArgs | Select-Object -Skip 1)
                }
                $certain = $locationName -in @('cd', 'chdir', 'sl', 'Set-Location') -and
                    (Test-TopLevelLocation $call $ast) -and $locationArgs.Count -eq 1 -and
                    ($literalPath -or $locationArgs[0] -notmatch '[*?\[\]]') -and
                    $locationArgs[0] -notmatch '^[A-Za-z]:[^\\/]|^~|^[^\\/]+::'
                $projected = @{ kind = 'location'; path = if ($certain) { $locationArgs[0] } else { '' }; uncertain_cwd = -not $certain }
            } elseif ($name -eq 'desktop.ps1') {
                $tail = @($values | Select-Object -Skip 1)
                if ($tail.Count -ge 2 -and $tail[0] -eq '--session-id') {
                    $sid = [Guid]::Empty
                    if (-not [Guid]::TryParse($tail[1], [ref]$sid)) { $unsafeBridge = $true; continue }
                    $tail = @($tail | Select-Object -Skip 2)
                }
                if ($tail.Count -ge 1 -and $tail[0] -eq 'shell') {
                    $source = @($tail | Select-Object -Skip 1)
                    if ($source.Count -eq 3 -and $source[0] -eq '--cwd') {
                        # A single literal invocation can select the tool cwd.
                        # With several calls use tool_input.workdir instead.
                        if ($commands.Count -ne 1) { $unsafeBridge = $true; continue }
                        $event.tool_input | Add-Member -NotePropertyName workdir -NotePropertyValue $source[1] -Force
                        $source = @($source | Select-Object -Skip 2)
                    }
                    if ($source.Count -ne 1 -or $parseErrors.Count) { $unsafeBridge = $true; continue }
                    $replacements += @{ start = $call.Extent.StartOffset; end = $call.Extent.EndOffset; kind = 'shell'; script = $source[0] }
                    $projected = @{ kind = 'shell'; script = $source[0] }
                } elseif ($tail.Count -gt 0) {
                    $replacements += @{ start = $call.Extent.StartOffset; end = $call.Extent.EndOffset; kind = 'argv'; argv = $tail }
                    $projected = @{ kind = 'argv'; argv = $tail }
                }
            } elseif ($name -in @('git', 'git.exe', 'glab', 'glab.exe', 'gh', 'gh.exe')) {
                $replacements += @{ start = $call.Extent.StartOffset; end = $call.Extent.EndOffset; kind = 'argv'; argv = $values }
            }
            # Project actual command ASTs independently of enclosing assignment,
            # control flow and function syntax. Quoted display strings are not
            # CommandAst nodes and stay quoted arguments of their printing call.
            $projection += $projected
        }
        # The original guards recognize explicit comment escape markers. Keep
        # actual parser comment tokens; quoted display text is not a comment.
        foreach ($token in $tokens) {
            if ($token.Kind -eq [Management.Automation.Language.TokenKind]::Comment) {
                $projection += @{ kind = 'comment'; script = $token.Text }
            }
        }
    }
    if ($unsafeBridge -and $event.hook_event_name -eq 'PreToolUse' -and $Hook -in @('board_locks', 'polling_guard', 'kill_guard', 'context_budget')) {
        $reason = 'Delamain cannot inspect this Desktop bridge call safely. Use one literal shell source, a literal desktop.ps1 path, and tool_input.workdir for multiple invocations; dynamic PowerShell expressions are unsupported for guarded operations.'
        [Console]::Error.WriteLine($reason)
        @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Depth 10 -Compress
        exit 0
    }
    $payload = @{ mode = 'hook'; hook = $Hook; hookargs = @($HookArgs); event = $event; command_replacements = @($replacements); command_projection = @($projection) }
    $json = ConvertTo-Json -InputObject $payload -Depth 100 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    & (Join-Path $PSScriptRoot 'desktop.ps1') --hook-payload $encoded
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("delamain desktop hook: $($_.Exception.Message)")
    exit 1
}
