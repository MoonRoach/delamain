# Start the dedicated Linux coordinator with the original plugin hooks enabled.
# This opts into unattended full access and trusts every hook in this launch.
$coordinatorArgs = @('codex', '--enable', 'hooks', '--dangerously-bypass-hook-trust',
    '--dangerously-bypass-approvals-and-sandbox') + @($args)
if ($MyInvocation.ExpectingInput) {
    $input | & (Join-Path $PSScriptRoot 'delamain.ps1') @coordinatorArgs
} else {
    & (Join-Path $PSScriptRoot 'delamain.ps1') @coordinatorArgs
}
exit $LASTEXITCODE
